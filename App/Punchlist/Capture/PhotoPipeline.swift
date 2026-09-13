import AVFoundation
import CoreImage
import Foundation
import ImageIO
import PunchlistCore
import UIKit
import UniformTypeIdentifiers

// ============================================================================
// Turning an AVCapturePhoto into three files and one database row.
//
// This is the only place in the app that decodes a full-resolution image, and
// it never does so on the main thread. Two budgets meet here:
//
//   * shutter tap to ready-for-next-shot < 350ms — met by never doing any of
//     this work on the capture callback or the main actor
//   * 250 photos under 250MB RSS — met by decoding *downsampled*, one image at
//     a time, inside an explicit autorelease pool
//
// The second is the subtle one. `UIImage(data:)` on a 12MP capture allocates
// roughly 48MB of bitmap; do that for a handful of queued photos and the app
// is dead before the resize even starts. `CGImageSourceCreateThumbnailAtIndex`
// with a max pixel size decodes straight to the size we want, so peak memory
// per photo is the size of the *output*, not the input.
// ============================================================================

// MARK: - Storage

/// Whether there is room to keep shooting.
enum StorageStatus: Sendable, Equatable {
    case ok
    /// Enough for now, but worth warning about.
    case low(availableBytes: Int64)
    /// Not enough to guarantee the next capture completes.
    case full(availableBytes: Int64)

    /// Acceptance test 7 fills the device to 98% and attempts a capture. The
    /// requirement is a graceful, *specific* error — so we stop before the
    /// write rather than after it, and we say what to do.
    ///
    /// The reserve is deliberately generous. A 12MP capture plus its display
    /// and thumb variants is ~8MB, but SQLite's WAL, the system's own
    /// scratch space, and any in-flight photos all need headroom too. Running
    /// a phone to literally zero corrupts more than photographs.
    static let blockingReserveBytes: Int64 = 250 * 1024 * 1024
    static let warningReserveBytes: Int64 = 1024 * 1024 * 1024

    static func evaluate(availableBytes: Int64?) -> StorageStatus {
        guard let availableBytes else { return .ok }
        if availableBytes < blockingReserveBytes { return .full(availableBytes: availableBytes) }
        if availableBytes < warningReserveBytes { return .low(availableBytes: availableBytes) }
        return .ok
    }

    var isBlocking: Bool {
        if case .full = self { return true }
        return false
    }

    var blockingMessage: String? {
        guard case .full(let available) = self else { return nil }
        let formatted = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
        return """
            This phone has \(formatted) left — not enough to save more photos safely. \
            Free up space in Settings › General › iPhone Storage, or finish and deliver \
            this report to clear its originals.
            """
    }

    var warningMessage: String? {
        guard case .low(let available) = self else { return nil }
        let formatted = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
        return "\(formatted) of storage left."
    }
}

// MARK: - Errors

enum PhotoPipelineError: Error, Sendable, Equatable {
    case noImageData
    case downsampleFailed
    case encodeFailed
    case writeFailed(String)
    case databaseFailed(String)
    case storageFull(availableBytes: Int64)
    case captureFailed(String)

    /// Never "Something went wrong" (§9). Say what happened and what to do.
    var userFacingMessage: String {
        switch self {
        case .noImageData:
            return "That shot came back empty. Tap the shutter again."
        case .downsampleFailed, .encodeFailed:
            return "That photo could not be processed. Tap the shutter again."
        case .writeFailed(let detail):
            return "That photo could not be saved to this phone. \(detail)"
        case .databaseFailed:
            return "That photo was saved but could not be filed. It will appear in the tray."
        case .storageFull(let available):
            return StorageStatus.full(availableBytes: available).blockingMessage
                ?? "This phone is out of storage."
        case .captureFailed(let detail):
            return "The camera could not take that photo. \(detail)"
        }
    }
}

// MARK: - Events

struct StoredPhoto: Sendable {
    let id: String
    let displayPath: String
    let thumbPath: String?
    let originalPath: String?
    let width: Int
    let height: Int
    let bytes: Int64
}

enum PhotoPipelineEvent: Sendable {
    case stored(StoredPhoto)
    case failed(String, PhotoPipelineError)
    case storage(StorageStatus)
}

// MARK: - Pipeline

/// Processes captures off the main actor, one at a time, in the order shot.
final class PhotoPipeline: @unchecked Sendable {

    /// Serial, and deliberately so. Parallel resizing would finish sooner in
    /// wall-clock terms and blow the memory ceiling doing it: two concurrent
    /// 12MP decodes is most of our budget for a single frame of work. Serial
    /// also means photos land in the database in the order they were shot,
    /// which is what the tray shows.
    private let queue = DispatchQueue(
        label: "com.punchlist.capture.pipeline", qos: .utility)

    private let database: AppDatabase
    private let store: MediaStore
    private let media: MediaRepository

    private let stateLock = NSLock()
    private var inFlightCount = 0
    private var continuations: [UUID: AsyncStream<PhotoPipelineEvent>.Continuation] = [:]

    /// Reused across photos. A `CIContext` is expensive to build and holds a
    /// Metal command queue; one per photo would dominate the cost of the resize
    /// it is doing.
    private lazy var ciContext: CIContext = {
        CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false])
    }()

    init(database: AppDatabase, store: MediaStore) {
        self.database = database
        self.store = store
        self.media = MediaRepository(database: database)
    }

    /// True while there is unprocessed work. The digest worker reads this so it
    /// never competes with the capture path for CPU.
    var isBusy: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return inFlightCount > 0
    }

    /// Multicast: every caller gets its own stream, so re-entering the camera
    /// screen does not steal events from a previous consumer or drop them on
    /// the floor.
    var events: AsyncStream<PhotoPipelineEvent> {
        AsyncStream { continuation in
            let key = UUID()
            stateLock.lock()
            continuations[key] = continuation
            stateLock.unlock()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.stateLock.lock()
                self.continuations[key] = nil
                self.stateLock.unlock()
            }
        }
    }

    private func emit(_ event: PhotoPipelineEvent) {
        stateLock.lock()
        let targets = Array(continuations.values)
        stateLock.unlock()
        for target in targets { target.yield(event) }
    }

    // MARK: Entry points

    /// Called straight from the AVFoundation capture callback. Does no work.
    func enqueue(_ photo: Handoff<AVCapturePhoto>, request: CaptureRequest) {
        stateLock.lock()
        inFlightCount += 1
        stateLock.unlock()

        queue.async { [self] in
            // One pool per photo. Without it, the CoreGraphics and ImageIO
            // temporaries from a whole batch accumulate until the queue drains
            // — which is exactly the 250-photo case we are budgeted against.
            autoreleasepool {
                process(photo.value, request: request)
            }
            stateLock.lock()
            inFlightCount -= 1
            stateLock.unlock()
        }
    }

    func recordCaptureFailure(request: CaptureRequest, message: String) {
        emit(.failed(request.id, .captureFailed(message)))
    }

    func refreshStorage() {
        queue.async { [self] in
            emit(.storage(StorageStatus.evaluate(availableBytes: store.availableBytes())))
        }
    }

    // MARK: Processing

    private func process(_ photo: AVCapturePhoto, request: CaptureRequest) {
        let status = StorageStatus.evaluate(availableBytes: store.availableBytes())
        emit(.storage(status))
        if case .full(let available) = status {
            emit(.failed(request.id, .storageFull(availableBytes: available)))
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            emit(.failed(request.id, .noImageData))
            return
        }

        do {
            let stored = try write(data: data, request: request)
            try file(stored, request: request)
            emit(.stored(stored))
        } catch let error as PhotoPipelineError {
            emit(.failed(request.id, error))
        } catch {
            emit(.failed(request.id, .writeFailed(error.localizedDescription)))
        }
    }

    /// Write the variants to disk.
    ///
    /// Order matters and is not arbitrary. Files are written **before** the
    /// database row, because the two failure modes are not symmetric: a row
    /// pointing at a missing file renders as a broken box in a client's report,
    /// while a file with no row is invisible and merely wastes a few megabytes
    /// until the orphan sweep collects it. We take the recoverable failure.
    private func write(data: Data, request: CaptureRequest) throws -> StoredPhoto {
        let displayPath = store.relativePath(
            inspectionID: request.inspectionId, mediaID: request.id, variant: .display)
        let thumbPath = store.relativePath(
            inspectionID: request.inspectionId, mediaID: request.id, variant: .thumb)

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw PhotoPipelineError.downsampleFailed
        }

        let display = try downsample(source: source, maxPixels: 2048)
        let displayData = try encodeJPEG(display, quality: 0.8)
        try writeChecked(displayData, to: displayPath)

        var storedThumbPath: String?
        // A missing thumbnail degrades the grid to a placeholder; it is not
        // worth failing the whole capture over, because the report only ever
        // uses the display variant.
        if let thumb = try? downsample(source: source, maxPixels: 256),
           let thumbData = try? encodeJPEG(thumb, quality: 0.7),
           (try? writeChecked(thumbData, to: thumbPath)) != nil {
            storedThumbPath = thumbPath
        }

        var originalPath: String?
        if request.archiveOriginal {
            let path = store.relativePath(
                inspectionID: request.inspectionId, mediaID: request.id, variant: .original)
            // Same reasoning as the thumbnail: the original is an opt-in
            // archive, not report input. Losing it must not lose the photo.
            if (try? writeChecked(data, to: path)) != nil { originalPath = path }
        }

        return StoredPhoto(
            id: request.id,
            displayPath: displayPath,
            thumbPath: storedThumbPath,
            originalPath: originalPath,
            width: display.width,
            height: display.height,
            bytes: store.fileSize(relativePath: displayPath) ?? Int64(displayData.count))
    }

    @discardableResult
    private func writeChecked(_ data: Data, to path: String) throws -> Bool {
        do {
            try store.write(data, toRelativePath: path)
            return true
        } catch let error as NSError {
            // ENOSPC arriving here means free space ran out between our check
            // and this write — a real possibility when another app is also
            // writing. Report it as the storage problem it is, not as a
            // mysterious file error.
            if error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC) {
                throw PhotoPipelineError.storageFull(
                    availableBytes: store.availableBytes() ?? 0)
            }
            throw PhotoPipelineError.writeFailed(error.localizedDescription)
        }
    }

    private func file(_ stored: StoredPhoto, request: CaptureRequest) throws {
        do {
            try media.record(
                orgID: request.orgId,
                inspectionID: request.inspectionId,
                kind: .photo,
                localPath: stored.displayPath,
                thumbPath: stored.thumbPath,
                originalPath: stored.originalPath,
                bytes: stored.bytes,
                width: stored.width,
                height: stored.height,
                capturedAt: request.capturedAt,
                lat: request.latitude,
                lon: request.longitude,
                // The id was minted at the tap and already names the files, so
                // the row and the filesystem agree without anyone having to
                // reconcile them.
                mediaID: request.id)
        } catch {
            // The files are on disk. Leave them: the orphan sweep will either
            // adopt them into rows or collect them, and either is better than
            // deleting an inspector's photo because a write contended.
            throw PhotoPipelineError.databaseFailed(error.localizedDescription)
        }
    }

    // MARK: Image work

    /// Decode straight to the target size.
    ///
    /// `kCGImageSourceCreateThumbnailFromImageAlways` with a max pixel size
    /// makes ImageIO decode at a reduced scale rather than decoding 12MP and
    /// then throwing most of it away. Peak memory is the size of the output.
    /// `kCGImageSourceCreateThumbnailWithTransform` applies the EXIF
    /// orientation during the decode, so the pixels we store are already
    /// upright — a photo that is sideways in the report is the kind of detail
    /// that makes a report look amateur.
    private func downsample(source: CGImageSource, maxPixels: Int) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary) else {
            throw PhotoPipelineError.downsampleFailed
        }
        return image
    }

    private func encodeJPEG(_ image: CGImage, quality: CGFloat) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PhotoPipelineError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoPipelineError.encodeFailed
        }
        return data as Data
    }
}
