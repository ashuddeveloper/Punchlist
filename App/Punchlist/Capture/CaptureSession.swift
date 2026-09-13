import AVFoundation
import Foundation
import GRDB
import Observation
import PunchlistCore
import UIKit

// ============================================================================
// Camera capture.
//
// The shape of this file follows one budget from §"Performance budgets":
// shutter tap to ready-for-next-shot < 350ms, with batch capture as the
// *default* mode. An inspector in a crawlspace shoots eight frames of the same
// sill plate in six seconds and files them afterwards. Every design decision
// below exists to keep the shutter free:
//
//   * The tap does three things on the main actor — mint an id, tell the
//     readiness coordinator a capture is coming, start the tray animation —
//     and then hands off. It never touches the filesystem or the database.
//   * AVFoundation's capture callback hands the `AVCapturePhoto` straight to
//     `PhotoPipeline` and returns. No encode, no resize, no write.
//   * Session configuration and every `AVCaptureSession` mutation happen on a
//     private serial queue. `startRunning()` alone blocks for ~300ms; on the
//     main thread that is a dropped frame budget three times over.
//
// The only main-actor object here is `CameraModel`, which exists so SwiftUI has
// something observable to render and so that "what the user sees" and "what the
// session is doing" cannot drift.
// ============================================================================

// MARK: - Hand-off box

/// A one-way hand-off of a reference type between queues.
///
/// `AVCapturePhotoSettings` and `AVCapturePhoto` are classes and are not
/// `Sendable`, but both are genuinely transferred rather than shared: the main
/// actor builds a settings object and never looks at it again, and AVFoundation
/// does not touch an `AVCapturePhoto` after the delegate callback returns. This
/// box states that intent instead of silencing it at the call site.
struct Handoff<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

// MARK: - Public state types

enum CameraAuthorization: Sendable, Equatable {
    case undetermined
    case authorized
    case denied
    case restricted

    /// Empty and error states carry direction (§9). "Camera access denied" is
    /// not direction; this is.
    var guidance: (title: String, detail: String)? {
        switch self {
        case .authorized, .undetermined:
            return nil
        case .denied:
            return (
                "Punchlist can't reach the camera",
                "Photos are how a finding becomes evidence. Open Settings › Punchlist › Camera and turn Camera on, then come back to this screen."
            )
        case .restricted:
            return (
                "Camera is blocked on this device",
                "A profile or Screen Time restriction is switching the camera off. Ask whoever manages this device to allow the camera, or import photos from the library instead."
            )
        }
    }
}

/// Why the camera stopped on its own. Each case is a sentence the inspector can
/// act on, because a black rectangle with no explanation reads as a crash.
enum CaptureInterruption: Sendable, Equatable {
    case backgrounded
    case inUseByAnotherApp
    case multipleForegroundApps
    case systemPressure
    case unknown

    var message: String {
        switch self {
        case .backgrounded:
            return "Camera paused while Punchlist was in the background. It resumes when you come back."
        case .inUseByAnotherApp:
            return "Another app is using the camera. Close it and the preview comes back on its own."
        case .multipleForegroundApps:
            return "The camera can't run in Split View. Make Punchlist full screen to keep shooting."
        case .systemPressure:
            return "The camera is cooling down. Get the phone out of direct sun; shooting resumes automatically."
        case .unknown:
            return "The camera stopped unexpectedly. Leave and re-enter this screen to restart it."
        }
    }
}

/// A photo on its way from the shutter to the tray.
///
/// §9 allows exactly one piece of motion in this product: "a photo animating
/// into the tray it was filed under." This is that photo. The flight starts on
/// the tap with no image, because waiting for the thumbnail would couple the
/// only load-bearing animation in the app to disk latency; the real thumbnail
/// cross-fades in if it lands before the flight ends.
struct PhotoFlight: Identifiable, Sendable {
    let id: String
    var image: UIImage?
}

/// What the shutter button is allowed to do right now.
enum ShutterState: Sendable, Equatable {
    case ready
    case catchingUp        // AVFoundation or our pipeline is saturated
    case sessionNotRunning
    case storageFull

    var allowsCapture: Bool { self == .ready }
}

/// Capabilities read off the photo output *once*, on the session queue, so the
/// main actor can build `AVCapturePhotoSettings` at shutter time without
/// reaching into AVFoundation objects it does not own.
struct CaptureCapabilities: Sendable, Equatable {
    var supportsHEVC = false
    var flashModes: [AVCaptureDevice.FlashMode] = [.off]
    var maxPhotoWidth: Int32 = 0
    var maxPhotoHeight: Int32 = 0
    var hasTorch = false
}

enum CameraSetupError: LocalizedError {
    case noCamera
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .noCamera: return "No rear camera is available on this device."
        case .cannotAddInput: return "The camera could not be attached to the capture session."
        case .cannotAddOutput: return "The photo output could not be attached to the capture session."
        }
    }
}

// MARK: - Capture request

/// Everything needed to file a photo, decided at the instant of the tap rather
/// than when the pixels arrive.
///
/// The id is minted here, on the tap. It names the files, so the pipeline never
/// has to agree with anyone about a filename; and UUIDv7 is time-sortable, so
/// ten rapid shots sort in the order they were *taken* even though they finish
/// processing out of order and land in the database in that scrambled order.
struct CaptureRequest: Sendable, Identifiable {
    let id: String
    let inspectionId: String
    let orgId: String
    /// Epoch milliseconds, UTC — the schema's only time representation.
    let capturedAt: Int64
    let latitude: Double?
    let longitude: Double?
    let archiveOriginal: Bool
}

// MARK: - Session

/// Owns the `AVCaptureSession`. Not an actor: AVFoundation wants a serial
/// *dispatch queue* it can be reconfigured on, and an actor gives no such
/// guarantee. All mutable state below is confined to `sessionQueue`, which is
/// what makes the `@unchecked Sendable` honest — the two exceptions are marked.
final class CaptureSession: NSObject, @unchecked Sendable {

    /// Read on the main thread by the preview layer. `AVCaptureSession` is
    /// documented as safe to hand to a preview layer from any thread; every
    /// *mutation* still goes through `sessionQueue`.
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(
        label: "com.punchlist.capture.session", qos: .userInitiated)

    private let photoOutput = AVCapturePhotoOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var isConfigured = false
    private var wantsRunning = false

    /// Per-capture delegates, retained until AVFoundation says the capture is
    /// finished. Batch capture means several can be in flight at once; a single
    /// shared delegate would interleave their callbacks and file photo 3's
    /// pixels under photo 5's id. Session-queue only.
    private var inFlight: [Int64: SinglePhotoCaptureDelegate] = [:]

    /// Guarded by `deviceLock` because the rotation coordinator is built on the
    /// main actor (it needs the preview layer) but the device is discovered on
    /// the session queue.
    private let deviceLock = NSLock()
    private var _videoDevice: AVCaptureDevice?
    var videoDevice: AVCaptureDevice? {
        deviceLock.lock(); defer { deviceLock.unlock() }
        return _videoDevice
    }

    // Callbacks. Assigned once at construction, before the session starts.
    var onPhoto: (@Sendable (Handoff<AVCapturePhoto>, CaptureRequest) -> Void)?
    var onCaptureFailed: (@Sendable (CaptureRequest, String) -> Void)?
    var onCapabilities: (@MainActor @Sendable (CaptureCapabilities) -> Void)?
    var onReadinessCoordinator: (@MainActor @Sendable (AVCapturePhotoOutputReadinessCoordinator) -> Void)?
    var onRunningChanged: (@MainActor @Sendable (Bool) -> Void)?
    var onInterruption: (@MainActor @Sendable (CaptureInterruption?) -> Void)?
    var onSetupError: (@MainActor @Sendable (String) -> Void)?

    // MARK: Lifecycle

    /// Configure once and start. Safe to call repeatedly — re-entering the
    /// camera screen must not rebuild the session, because a rebuild costs the
    /// ~300ms `startRunning()` stall a second time.
    ///
    /// `archiveOriginals` reaches this far down for one reason: it decides
    /// whether we ask the sensor for its maximum dimensions. See `configure`.
    func start(archiveOriginals: Bool) {
        sessionQueue.async { [self] in
            wantsRunning = true
            if !isConfigured {
                do {
                    try configure(archiveOriginals: archiveOriginals)
                    isConfigured = true
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    Task { @MainActor in self.onSetupError?(message) }
                    return
                }
            }
            guard !session.isRunning else { return }
            session.startRunning()
            let running = session.isRunning
            Task { @MainActor in self.onRunningChanged?(running) }
        }
    }

    /// Stop the session but keep the configuration.
    ///
    /// We stop on background and on leaving the screen, and *not* when the tray
    /// sheet covers the preview: filing a batch and going back to shooting is
    /// the core loop, and paying `startRunning()` on every return trip would put
    /// a half-second stall in the middle of it.
    func stop() {
        sessionQueue.async { [self] in
            wantsRunning = false
            guard session.isRunning else { return }
            session.stopRunning()
            Task { @MainActor in self.onRunningChanged?(false) }
        }
    }

    // MARK: Configuration

    private func configure(archiveOriginals: Bool) throws {
        // A single fixed wide-angle lens, not a virtual multi-camera device.
        // A virtual device switches lenses when the subject gets close, which
        // in a crawlspace happens constantly — and every switch is a visible
        // hitch plus a focal-length change between two frames of the same
        // defect. Predictability beats reach here.
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back)
        else { throw CameraSetupError.noCamera }

        deviceLock.lock(); _videoDevice = device; deviceLock.unlock()

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraSetupError.cannotAddInput }
        session.addInput(input)
        videoInput = input

        guard session.canAddOutput(photoOutput) else { throw CameraSetupError.cannotAddOutput }
        session.addOutput(photoOutput)

        // Full sensor resolution only when the org actually keeps originals.
        //
        // On a Pro device the maximum is 24 or 48MP. The report embeds 2048px
        // either way, so those extra pixels have exactly one consumer: the
        // archive. Asking for them unconditionally costs roughly 3x the encode
        // time (straight out of the 350ms budget) and 4x the bytes on a device
        // we already have to keep under a storage ceiling. So: archive on,
        // shoot the sensor; archive off, take the 12MP default.
        if archiveOriginals, let maxDimensions = device.activeFormat.supportedMaxPhotoDimensions.last {
            photoOutput.maxPhotoDimensions = maxDimensions
        }

        // `.balanced` and not `.quality`: quality prioritisation enables the
        // longest multi-frame fusions, which can take over a second on an older
        // phone. `.speed` goes the other way and drops Deep Fusion, which is
        // precisely the processing that makes a dark crawlspace legible.
        photoOutput.maxPhotoQualityPrioritization = .balanced

        // The three settings that buy the 350ms budget. Order matters:
        // responsive capture is only available once zero-shutter-lag is on.
        photoOutput.isZeroShutterLagEnabled = photoOutput.isZeroShutterLagSupported
        if photoOutput.isResponsiveCaptureSupported {
            photoOutput.isResponsiveCaptureEnabled = true
        }
        if photoOutput.isFastCapturePrioritizationSupported {
            // Lets the system degrade quality prioritisation by itself while
            // the shutter is being hammered, instead of queueing full-quality
            // captures behind each other.
            photoOutput.isFastCapturePrioritizationEnabled = true
        }

        var capabilities = CaptureCapabilities()
        capabilities.supportsHEVC = photoOutput.availablePhotoCodecTypes.contains(.hevc)
        capabilities.flashModes = photoOutput.supportedFlashModes
        capabilities.maxPhotoWidth = photoOutput.maxPhotoDimensions.width
        capabilities.maxPhotoHeight = photoOutput.maxPhotoDimensions.height
        capabilities.hasTorch = device.hasTorch

        // Continuous autofocus with a near-subject bias. An inspector shoots a
        // hairline crack from 20cm more often than a roofline from 20m.
        if let locked = try? lockDevice(device) {
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.isSubjectAreaChangeMonitoringEnabled = true
            locked()
        }

        let coordinator = AVCapturePhotoOutputReadinessCoordinator(photoOutput: photoOutput)
        let handoff = Handoff(coordinator)
        Task { @MainActor in
            self.onCapabilities?(capabilities)
            self.onReadinessCoordinator?(handoff.value)
        }

        registerObservers()
    }

    /// `lockForConfiguration` is easy to leak. Returning the unlock as a closure
    /// makes the pairing structural instead of a thing you remember.
    private func lockDevice(_ device: AVCaptureDevice) throws -> () -> Void {
        try device.lockForConfiguration()
        return { device.unlockForConfiguration() }
    }

    // MARK: Capture

    /// Build the settings for one shot.
    ///
    /// Deliberately does not read `photoOutput`: this runs on the main actor at
    /// shutter time, and AVFoundation objects belong to the session queue. It
    /// works off the capability snapshot taken during configuration instead.
    @MainActor
    static func makeSettings(
        capabilities: CaptureCapabilities,
        flashMode: AVCaptureDevice.FlashMode
    ) -> AVCapturePhotoSettings {
        let settings: AVCapturePhotoSettings
        if capabilities.supportsHEVC {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings()
        }
        settings.flashMode = capabilities.flashModes.contains(flashMode) ? flashMode : .off
        settings.photoQualityPrioritization = .balanced
        if capabilities.maxPhotoWidth > 0 {
            settings.maxPhotoDimensions = CMVideoDimensions(
                width: capabilities.maxPhotoWidth, height: capabilities.maxPhotoHeight)
        }
        // We generate our own 256px thumbnail from the 2048px display variant,
        // so an embedded preview would be bytes we write and never read.
        settings.embeddedThumbnailPhotoFormat = nil
        return settings
    }

    /// Fire the shutter. Call from the main actor, with settings already
    /// tracked by the readiness coordinator.
    func capture(request: CaptureRequest, settings: Handoff<AVCapturePhotoSettings>) {
        sessionQueue.async { [self] in
            let uniqueID = settings.value.uniqueID
            let delegate = SinglePhotoCaptureDelegate(
                request: request,
                onPhoto: { [weak self] photo, request in
                    // Hot path. Anything added here is added to the time before
                    // the next shot: this callback arrives on an AVFoundation
                    // queue that also drives the capture pipeline. Hand off and
                    // get out. In particular `fileDataRepresentation()` — which
                    // performs the container encode — is deliberately called
                    // later, on the pipeline queue.
                    self?.onPhoto?(photo, request)
                },
                onFailure: { [weak self] request, message in
                    self?.onCaptureFailed?(request, message)
                },
                onFinished: { [weak self] uniqueID in
                    // Release the delegate on the queue that created it.
                    self?.sessionQueue.async { self?.inFlight[uniqueID] = nil }
                })
            inFlight[uniqueID] = delegate
            photoOutput.capturePhoto(with: settings.value, delegate: delegate)
        }
    }

    // MARK: Device controls

    /// The torch, not the flash. In a crawlspace the inspector needs to *see*
    /// the defect to frame it, and a flash that fires after the framing is done
    /// is no help at all.
    func setTorch(_ on: Bool) {
        sessionQueue.async { [self] in
            guard let device = videoDevice, device.hasTorch, device.isTorchAvailable else { return }
            guard let unlock = try? lockDevice(device) else { return }
            defer { unlock() }
            // A fixed level rather than `.on`: full power in a confined space
            // blows out anything closer than a metre, and it heats the phone
            // into the thermal interruption we handle above.
            if on {
                try? device.setTorchModeOn(level: 0.6)
            } else {
                device.torchMode = .off
            }
        }
    }

    /// Tap to focus, in device coordinates from the preview layer.
    func focus(at point: CGPoint) {
        sessionQueue.async { [self] in
            guard let device = videoDevice, let unlock = try? lockDevice(device) else { return }
            defer { unlock() }
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = point
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported,
               device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposurePointOfInterest = point
                device.exposureMode = .continuousAutoExposure
            }
        }
    }

    /// Applied from the rotation coordinator so a landscape shot is written
    /// with landscape pixels instead of a sideways image plus a metadata flag
    /// that PDFKit will ignore three weeks from now.
    func setCaptureRotationAngle(_ angle: CGFloat) {
        sessionQueue.async { [self] in
            guard let connection = photoOutput.connection(with: .video) else { return }
            guard connection.isVideoRotationAngleSupported(angle) else { return }
            connection.videoRotationAngle = angle
        }
    }

    // MARK: Notifications

    private func registerObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(sessionWasInterrupted(_:)),
            name: AVCaptureSession.wasInterruptedNotification, object: session)
        center.addObserver(
            self, selector: #selector(sessionInterruptionEnded(_:)),
            name: AVCaptureSession.interruptionEndedNotification, object: session)
        center.addObserver(
            self, selector: #selector(sessionRuntimeError(_:)),
            name: AVCaptureSession.runtimeErrorNotification, object: session)
    }

    @objc private func sessionWasInterrupted(_ note: Notification) {
        let raw = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
        let reason = AVCaptureSession.InterruptionReason(rawValue: raw ?? -1)
        let mapped: CaptureInterruption
        switch reason {
        case .videoDeviceNotAvailableInBackground: mapped = .backgrounded
        case .videoDeviceInUseByAnotherClient: mapped = .inUseByAnotherApp
        case .videoDeviceNotAvailableWithMultipleForegroundApps: mapped = .multipleForegroundApps
        case .videoDeviceNotAvailableDueToSystemPressure: mapped = .systemPressure
        default: mapped = .unknown
        }
        Task { @MainActor in self.onInterruption?(mapped) }
    }

    @objc private func sessionInterruptionEnded(_ note: Notification) {
        Task { @MainActor in self.onInterruption?(nil) }
        sessionQueue.async { [self] in
            guard wantsRunning, !session.isRunning else { return }
            session.startRunning()
            let running = session.isRunning
            Task { @MainActor in self.onRunningChanged?(running) }
        }
    }

    @objc private func sessionRuntimeError(_ note: Notification) {
        guard let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError else { return }
        // `mediaServicesWereReset` is recoverable and is the common one: the
        // media server restarts and every session in the system dies. The
        // inspector should see a preview come back by itself, not a dead screen
        // that needs them to know to navigate away and return.
        guard error.code == .mediaServicesWereReset else {
            Task { @MainActor in self.onInterruption?(.unknown) }
            return
        }
        sessionQueue.async { [self] in
            guard wantsRunning, !session.isRunning else { return }
            session.startRunning()
            let running = session.isRunning
            Task { @MainActor in
                self.onRunningChanged?(running)
                self.onInterruption?(running ? nil : .unknown)
            }
        }
    }
}

// MARK: - Per-capture delegate

/// One of these per shot, retained by `CaptureSession.inFlight` for exactly as
/// long as AVFoundation needs it. Holding the request here is what lets the
/// pixels find their way back to the id that was minted at the tap.
private final class SinglePhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let request: CaptureRequest
    private let onPhoto: @Sendable (Handoff<AVCapturePhoto>, CaptureRequest) -> Void
    private let onFailure: @Sendable (CaptureRequest, String) -> Void
    private let onFinished: @Sendable (Int64) -> Void

    init(
        request: CaptureRequest,
        onPhoto: @escaping @Sendable (Handoff<AVCapturePhoto>, CaptureRequest) -> Void,
        onFailure: @escaping @Sendable (CaptureRequest, String) -> Void,
        onFinished: @escaping @Sendable (Int64) -> Void
    ) {
        self.request = request
        self.onPhoto = onPhoto
        self.onFailure = onFailure
        self.onFinished = onFinished
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: (any Error)?
    ) {
        if let error {
            onFailure(request, error.localizedDescription)
            return
        }
        onPhoto(Handoff(photo), request)
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: (any Error)?
    ) {
        if let error {
            onFailure(request, error.localizedDescription)
        }
        onFinished(resolvedSettings.uniqueID)
    }
}

// MARK: - Readiness forwarding

/// `AVCapturePhotoOutputReadinessCoordinator` delivers its callbacks on the
/// main queue, which is why this shim can assume main-actor isolation rather
/// than hopping and losing a frame of shutter feedback.
private final class ReadinessForwarder: NSObject, AVCapturePhotoOutputReadinessCoordinatorDelegate {
    private let onChange: @MainActor (AVCapturePhotoOutput.CaptureReadiness) -> Void

    init(onChange: @escaping @MainActor (AVCapturePhotoOutput.CaptureReadiness) -> Void) {
        self.onChange = onChange
    }

    func readinessCoordinator(
        _ coordinator: AVCapturePhotoOutputReadinessCoordinator,
        captureReadinessDidChange captureReadiness: AVCapturePhotoOutput.CaptureReadiness
    ) {
        MainActor.assumeIsolated { onChange(captureReadiness) }
    }
}

// MARK: - Main-actor model

/// The camera screen's state. Everything SwiftUI renders comes from here, and
/// nothing durable is cached here — the tray count is a `ValueObservation` on
/// the `media` table, not a number this object increments and hopes stays true.
@MainActor
@Observable
final class CameraModel {

    // Dependencies
    private let database: AppDatabase
    private let store: MediaStore
    private let pipeline: PhotoPipeline
    private let digestWorker: MediaDigestWorker
    private let captureSession: CaptureSession
    private let locationProvider: @Sendable () -> (latitude: Double, longitude: Double)?

    let inspectionId: String
    let orgId: String
    private let archiveOriginals: Bool

    // Observable state
    private(set) var authorization: CameraAuthorization = .undetermined
    private(set) var isRunning = false
    private(set) var interruption: CaptureInterruption?
    private(set) var trayCount = 0
    private(set) var pendingCount = 0
    private(set) var latestThumbnail: UIImage?
    private(set) var flights: [PhotoFlight] = []
    private(set) var storage: StorageStatus = .ok
    private(set) var failureMessage: String?
    private(set) var capabilities = CaptureCapabilities()
    var isTorchOn = false {
        didSet { captureSession.setTorch(isTorchOn) }
    }
    var flashMode: AVCaptureDevice.FlashMode = .off

    /// The pipeline queue holds one `AVCapturePhoto` per unprocessed shot, and
    /// each of those is several megabytes of encoded sensor data. This ceiling
    /// is a *memory* backstop, not a processing dependency: at a realistic
    /// three taps per second the queue drains faster than it fills, and the
    /// user only ever meets this number by holding the shutter down. When they
    /// do, the button says "catching up" rather than silently dropping frames.
    private let maxInFlight = 8

    private var readinessCoordinator: AVCapturePhotoOutputReadinessCoordinator?
    private var readinessForwarder: ReadinessForwarder?
    private var readiness: AVCapturePhotoOutput.CaptureReadiness = .sessionNotRunning
    private var tasks: [Task<Void, Never>] = []

    var session: AVCaptureSession { captureSession.session }
    var videoDevice: AVCaptureDevice? { captureSession.videoDevice }

    init(
        database: AppDatabase,
        store: MediaStore,
        inspectionId: String,
        orgId: String,
        archiveOriginals: Bool,
        locationProvider: @escaping @Sendable () -> (latitude: Double, longitude: Double)? = { nil }
    ) {
        self.database = database
        self.store = store
        self.inspectionId = inspectionId
        self.orgId = orgId
        self.archiveOriginals = archiveOriginals
        self.locationProvider = locationProvider
        self.pipeline = PhotoPipeline(database: database, store: store)
        self.digestWorker = MediaDigestWorker(
            database: database, store: store, isBusy: { [pipeline] in pipeline.isBusy })
        self.captureSession = CaptureSession()

        captureSession.onPhoto = { [pipeline] photo, request in
            pipeline.enqueue(photo, request: request)
        }
        captureSession.onCaptureFailed = { [pipeline] request, message in
            pipeline.recordCaptureFailure(request: request, message: message)
        }
        captureSession.onCapabilities = { [weak self] capabilities in
            self?.capabilities = capabilities
        }
        captureSession.onReadinessCoordinator = { [weak self] coordinator in
            self?.attach(coordinator)
        }
        captureSession.onRunningChanged = { [weak self] running in
            self?.isRunning = running
        }
        captureSession.onInterruption = { [weak self] interruption in
            self?.interruption = interruption
        }
        captureSession.onSetupError = { [weak self] message in
            self?.failureMessage = message
        }
    }

    var shutterState: ShutterState {
        if storage.isBlocking { return .storageFull }
        if !isRunning { return .sessionNotRunning }
        if pendingCount >= maxInFlight { return .catchingUp }
        switch readiness {
        case .ready, .notReadyMomentarily:
            // `notReadyMomentarily` means AVFoundation will accept the request
            // and service it in a moment. Disabling the button for it would
            // make rapid fire feel like a broken shutter.
            return .ready
        default:
            return .catchingUp
        }
    }

    // MARK: Screen lifecycle

    func appear() async {
        authorization = await Self.resolveAuthorization()
        guard authorization == .authorized else { return }

        observeTray()
        consumePipelineEvents()
        pipeline.refreshStorage()
        digestWorker.start()
        captureSession.start(archiveOriginals: archiveOriginals)
    }

    func disappear() {
        captureSession.stop()
        isTorchOn = false
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        // Leaving the camera is the most reliable "the user has stopped
        // shooting" signal there is, so it is when the digest work gets its
        // window.
        digestWorker.scheduleSweep()
    }

    func scenePhaseChanged(to phase: ScenePhaseLike) {
        switch phase {
        case .active:
            guard authorization == .authorized else { return }
            captureSession.start(archiveOriginals: archiveOriginals)
            pipeline.refreshStorage()
        case .inactive, .background:
            // iOS suspends the session on background anyway; stopping it
            // explicitly is what makes the return trip come back clean instead
            // of stuck in `videoDeviceNotAvailableInBackground`.
            captureSession.stop()
            isTorchOn = false
            digestWorker.scheduleSweep()
        }
    }

    /// A tiny mirror of SwiftUI's `ScenePhase` so this file does not import
    /// SwiftUI and the model stays testable without a view.
    enum ScenePhaseLike: Sendable { case active, inactive, background }

    func requestAccess() async {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        authorization = await Self.resolveAuthorization()
        if authorization == .authorized {
            await appear()
        }
    }

    // MARK: Shutter

    /// The whole of the main-actor shutter path. Nothing here touches the
    /// filesystem, the database, or an image.
    func shutterTapped() {
        guard shutterState.allowsCapture else {
            // A tap that cannot produce a photo must still say why, or the
            // inspector will keep tapping a dead button in a crawlspace.
            if case .storageFull = shutterState, let message = storage.blockingMessage {
                failureMessage = message
            }
            return
        }

        let location = locationProvider()
        let request = CaptureRequest(
            id: UUIDv7.generate(),
            inspectionId: inspectionId,
            orgId: orgId,
            capturedAt: Clock.nowMillis(),
            latitude: location?.latitude,
            longitude: location?.longitude,
            archiveOriginal: archiveOriginals)

        let settings = Self.makeSettings(capabilities: capabilities, flashMode: flashMode)
        // Tracking before the hop to the session queue is the point of the
        // readiness coordinator: the button goes un-ready on this run loop
        // iteration rather than whenever the session queue gets round to us.
        readinessCoordinator?.startTrackingCaptureRequest(using: settings)

        pendingCount += 1
        flights.append(PhotoFlight(id: request.id, image: nil))
        captureSession.capture(request: request, settings: Handoff(settings))
        digestWorker.noteCaptureActivity()
    }

    private static func makeSettings(
        capabilities: CaptureCapabilities,
        flashMode: AVCaptureDevice.FlashMode
    ) -> AVCapturePhotoSettings {
        CaptureSession.makeSettings(capabilities: capabilities, flashMode: flashMode)
    }

    func flightDidLand(_ id: String) {
        flights.removeAll { $0.id == id }
    }

    func dismissFailure() { failureMessage = nil }

    func focus(atPreviewPoint point: CGPoint) {
        captureSession.focus(at: point)
    }

    func applyCaptureRotation(_ angle: CGFloat) {
        captureSession.setCaptureRotationAngle(angle)
    }

    // MARK: Wiring

    private func attach(_ coordinator: AVCapturePhotoOutputReadinessCoordinator) {
        let forwarder = ReadinessForwarder { [weak self] readiness in
            self?.readiness = readiness
        }
        coordinator.delegate = forwarder
        readinessForwarder = forwarder
        readinessCoordinator = coordinator
    }

    /// The tray count is a database query, not a counter.
    ///
    /// §"Data layer rules": the UI stays live through `ValueObservation` and no
    /// view model caches durable state. A local counter would be wrong the
    /// moment a photo is filed from the tray, or deleted, or the process is
    /// force-quit mid-batch — and "wrong number of photos" is the exact thing
    /// that makes an inspector stop trusting the tray.
    private func observeTray() {
        let inspectionId = self.inspectionId
        let observation = database.observe { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM media
                    WHERE inspection_id = ? AND deleted_at IS NULL
                      AND observation_id IS NULL AND finding_id IS NULL
                    """,
                arguments: [inspectionId]) ?? 0
        }
        tasks.append(Task { [weak self, database] in
            do {
                for try await count in observation.values(in: database.dbWriter) {
                    guard let self else { return }
                    self.trayCount = count
                }
            } catch {
                // A failed observation must not take the camera down with it:
                // the shutter still works, the count just stops moving.
                self?.failureMessage = "The photo count stopped updating. Photos are still being saved."
            }
        })
    }

    private func consumePipelineEvents() {
        tasks.append(Task { [weak self, pipeline, store] in
            for await event in pipeline.events {
                guard let self else { return }
                switch event {
                case .stored(let stored):
                    self.pendingCount = max(0, self.pendingCount - 1)
                    // The thumbnail is 256px and already on disk; decoding it
                    // costs well under a frame, but it still happens off the
                    // main actor because "well under a frame" times 250 photos
                    // is not nothing.
                    if let thumbPath = stored.thumbPath {
                        let image = await ThumbnailStore.shared.image(
                            relativePath: thumbPath, store: store)
                        self.latestThumbnail = image
                        if let index = self.flights.firstIndex(where: { $0.id == stored.id }) {
                            self.flights[index].image = image
                        }
                    }
                case .failed(let id, let error):
                    self.pendingCount = max(0, self.pendingCount - 1)
                    self.flights.removeAll { $0.id == id }
                    self.failureMessage = error.userFacingMessage
                case .storage(let status):
                    self.storage = status
                }
            }
        })
    }

    private static func resolveAuthorization() async -> CameraAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .undetermined
        @unknown default: return .denied
        }
    }
}
