import AVFoundation
import PunchlistCore
import SwiftUI

// ============================================================================
// The camera.
//
// Batch capture is the default and only mode. The session stays open, the
// shutter fires as fast as the sensor allows, and photos land in a tray to be
// filed afterwards. Inspectors shoot first and organise later; an app that
// demands "which item is this photo for?" between every shot is an app they
// put down.
//
// The one animation in this screen — a photo shrinking into the tray — is
// load-bearing: it is how the inspector knows the shot was captured without
// looking away from the wall they are photographing. Everything else is still.
// ============================================================================

struct CameraView: View {
    @State private var model: CameraModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    init(database: AppDatabase, store: MediaStore, inspectionID: String, orgID: String, archiveOriginals: Bool) {
        _model = State(wrappedValue: CameraModel(
            database: database, store: store, inspectionId: inspectionID, orgId: orgID,
            archiveOriginals: archiveOriginals))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch model.authorization {
            case .authorized:
                preview
            case .undetermined:
                PermissionPrompt(
                    title: "Punchlist needs the camera",
                    detail: "Photographs are most of an inspection report.",
                    actionTitle: "Allow camera access") {
                        Task { await model.requestAccess() }
                    }
            case .denied, .restricted:
                if let guidance = model.authorization.guidance {
                    PermissionPrompt(
                        title: guidance.title, detail: guidance.detail,
                        actionTitle: "Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                }
            }
        }
        .task { await model.appear() }
        .onDisappear { model.disappear() }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(to: phase == .active ? .active
                                    : phase == .inactive ? .inactive : .background)
        }
    }

    private var preview: some View {
        ZStack {
            CameraPreview(session: model.session)
                .ignoresSafeArea()
                .onTapGesture { location in model.focus(atPreviewPoint: location) }

            VStack {
                topBar
                Spacer()
                if let warning = model.storage.warningMessage {
                    StorageWarning(text: warning)
                }
                shutterBar
            }

            // Photos in flight, animating toward the tray.
            ForEach(model.flights) { flight in
                FlightToTray(flight: flight) { model.flightDidLand(flight.id) }
            }
        }
        .alert("Photo problem",
               isPresented: .init(get: { model.failureMessage != nil },
                                  set: { if !$0 { model.dismissFailure() } })) {
            Button("OK", role: .cancel) { model.dismissFailure() }
        } message: {
            Text(model.failureMessage ?? "")
        }
    }

    private var topBar: some View {
        HStack(spacing: Metrics.spaceL) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: Metrics.tapTarget, height: Metrics.tapTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close the camera")

            Spacer()

            Button { model.isTorchOn.toggle() } label: {
                Image(systemName: model.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(model.isTorchOn ? .yellow : .white)
                    .frame(width: Metrics.tapTargetRepeated, height: Metrics.tapTargetRepeated)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(model.isTorchOn ? "Turn the light off" : "Turn the light on")
        }
        .padding(.horizontal, Metrics.spaceS)
        .background(.black.opacity(0.35))
    }

    private var shutterBar: some View {
        HStack {
            TrayButton(count: model.trayCount, thumbnail: model.latestThumbnail)
            Spacer()
            ShutterButton(state: model.shutterState) { model.shutterTapped() }
            Spacer()
            // Balances the shutter without adding a control. A camera screen
            // with an odd number of controls puts the shutter off-centre, and
            // the shutter must be exactly where the thumb expects it.
            Color.clear.frame(width: Metrics.tapTargetRepeated, height: Metrics.tapTargetRepeated)
        }
        .padding(.horizontal, Metrics.spaceL)
        .padding(.vertical, Metrics.spaceL)
        .background(.black.opacity(0.35))
    }
}

// MARK: - Shutter

private struct ShutterButton: View {
    let state: ShutterState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: 78, height: 78)
                Circle()
                    .fill(state.allowsCapture ? .white : .white.opacity(0.35))
                    .frame(width: 64, height: 64)
                if !state.allowsCapture {
                    Image(systemName: state == .storageFull ? "externaldrive.badge.xmark" : "hourglass")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.6))
                }
            }
            .frame(width: 88, height: 88)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // No scale-on-press animation. At three taps a second it becomes a
        // strobe, and the feedback that matters is the photo flying to the tray.
        .accessibilityLabel("Shutter")
        .accessibilityHint(accessibilityHint)
    }

    private var accessibilityHint: String {
        switch state {
        case .ready: return "Takes a photo"
        case .catchingUp: return "Catching up with the last few shots"
        case .sessionNotRunning: return "The camera is not running"
        case .storageFull: return "This phone is out of storage"
        }
    }
}

private struct TrayButton: View {
    let count: Int
    let thumbnail: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.white.opacity(0.15)
                }
            }
            .frame(width: Metrics.tapTargetRepeated, height: Metrics.tapTargetRepeated)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radius))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radius)
                    .strokeBorder(.white.opacity(0.6), lineWidth: 1))

            if count > 0 {
                Text("\(count)")
                    .font(.figureSmall)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.white, in: Capsule())
                    .offset(x: 6, y: -6)
            }
        }
        .accessibilityLabel("\(count) photos in the tray")
    }
}

/// The photo-to-tray animation. The only motion in the app that is not a direct
/// response to a navigation.
private struct FlightToTray: View {
    let flight: PhotoFlight
    let onLand: () -> Void
    @State private var hasLanded = false

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image = flight.image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.6)
                }
            }
            .frame(
                width: hasLanded ? Metrics.tapTargetRepeated : geometry.size.width * 0.5,
                height: hasLanded ? Metrics.tapTargetRepeated : geometry.size.width * 0.5)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radius))
            .position(
                x: hasLanded ? Metrics.spaceL + Metrics.tapTargetRepeated / 2 : geometry.size.width / 2,
                y: hasLanded ? geometry.size.height - 60 : geometry.size.height / 2)
            .opacity(hasLanded ? 0 : 1)
            .onAppear {
                withAnimation(.easeIn(duration: 0.28)) { hasLanded = true }
                // Removed on a timer rather than an animation completion
                // handler: if the pixels never arrive (a failed capture) the
                // view must still clean itself up.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: onLand)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct StorageWarning: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.figureSmall)
            .foregroundStyle(.black)
            .padding(.horizontal, Metrics.spaceL)
            .padding(.vertical, Metrics.spaceS)
            .background(Color.severityMonitor, in: Capsule())
            .padding(.bottom, Metrics.spaceM)
    }
}

private struct PermissionPrompt: View {
    let title: String
    let detail: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: Metrics.spaceL) {
            Text(title).font(.sectionTitle).foregroundStyle(.white)
            Text(detail)
                .font(.bodyField)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
            Button(action: action) {
                Text(actionTitle)
                    .font(.bodyFieldMedium)
                    .foregroundStyle(.black)
                    .padding(.horizontal, Metrics.spaceXL)
                    .frame(minHeight: Metrics.tapTargetRepeated)
                    .background(.white, in: RoundedRectangle(cornerRadius: Metrics.radius))
            }
            .buttonStyle(.plain)
        }
        .padding(Metrics.spaceXXL)
    }
}

/// `AVCaptureVideoPreviewLayer` in a UIView. A SwiftUI-native preview does not
/// exist, and layering one under SwiftUI controls is the standard shape.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
