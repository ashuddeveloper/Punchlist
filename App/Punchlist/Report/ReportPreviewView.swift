import PDFKit
import PunchlistCore
import SwiftUI

// ============================================================================
// The live report preview.
//
// §10.5: a button that shows the PDF **as it stands right now**, mid-inspection.
// It removes all anxiety about what the output will look like, and it is one of
// the two features that actually sells this product — the other being handing
// the finished thing over in the driveway.
//
// It renders the real report through the real pipeline. A "preview" that took a
// different code path would be a lie exactly when the inspector is relying on
// it to be true.
// ============================================================================

@MainActor
@Observable
final class ReportPreviewModel {
    enum State {
        case rendering(ReportRenderProgress?)
        case ready(URL)
        case failed(String)
    }

    private(set) var state: State = .rendering(nil)

    private let database: AppDatabase
    private let store: MediaStore
    private let inspectionID: String
    private var renderTask: Task<Void, Never>?

    init(database: AppDatabase, store: MediaStore, inspectionID: String) {
        self.database = database
        self.store = store
        self.inspectionID = inspectionID
    }

    func render() {
        renderTask?.cancel()
        state = .rendering(nil)

        renderTask = Task { [database, store, inspectionID] in
            do {
                // Layout and render off the main actor. A 40-page report is a
                // second or two of solid CPU even before the photos, and doing
                // it on the main actor would freeze the app at the exact moment
                // a client is watching over the inspector's shoulder.
                let url = try await Task.detached(priority: .userInitiated) {
                    let document = try ReportBuilder(database: database)
                        .buildDocument(inspectionID: inspectionID)

                    let destination = FileManager.default.temporaryDirectory
                        .appendingPathComponent("\(inspectionID).pdf")
                    try? FileManager.default.removeItem(at: destination)

                    try PDFRenderer(store: store).render(document: document, to: destination) { progress in
                        Task { @MainActor [weak self] in
                            self?.state = .rendering(progress)
                        }
                    }
                    return destination
                }.value

                guard !Task.isCancelled else { return }
                state = .ready(url)
            } catch {
                state = .failed(
                    (error as? LocalizedError)?.errorDescription ?? String(describing: error))
            }
        }
    }

    func cancel() {
        renderTask?.cancel()
        renderTask = nil
    }
}

struct ReportPreviewView: View {
    @State private var model: ReportPreviewModel
    @State private var isSharing = false
    @Environment(\.dismiss) private var dismiss

    init(database: AppDatabase, store: MediaStore, inspectionID: String) {
        _model = State(wrappedValue: ReportPreviewModel(
            database: database, store: store, inspectionID: inspectionID))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.paper.ignoresSafeArea()

                switch model.state {
                case .rendering(let progress):
                    RenderProgressView(progress: progress)
                case .ready(let url):
                    PDFKitView(url: url).ignoresSafeArea(edges: .bottom)
                case .failed(let message):
                    RenderFailureView(message: message) { model.render() }
                }
            }
            .navigationTitle("Report preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { model.cancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if case .ready = model.state {
                        Button { isSharing = true } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share this report")
                    }
                }
            }
            .task { model.render() }
            .onDisappear { model.cancel() }
            .sheet(isPresented: $isSharing) {
                if case .ready(let url) = model.state {
                    // The share sheet, not an email screen of our own: AirDrop
                    // to the client's phone in the driveway is the moment that
                    // produces the referral, and only the system sheet offers it.
                    ShareSheet(items: [url])
                }
            }
        }
    }
}

/// Real progress, not a spinner. "Page 12 of 40" tells an inspector standing
/// next to a client that the thing is working and roughly how long is left; an
/// indeterminate spinner tells them nothing and feels broken after four seconds.
private struct RenderProgressView: View {
    let progress: ReportRenderProgress?

    var body: some View {
        VStack(spacing: Metrics.spaceL) {
            if let progress {
                Text("Page \(progress.page) of \(progress.totalPages)")
                    .font(.figureLarge)
                    .foregroundStyle(Color.ink)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.field)
                        Rectangle()
                            .fill(Color.ink)
                            .frame(width: geometry.size.width * progress.fraction)
                    }
                }
                .frame(height: 3)
                .frame(maxWidth: 260)
            } else {
                Text("Laying out the report")
                    .font(.bodyField)
                    .foregroundStyle(Color.slate)
            }
        }
        .padding(Metrics.spaceXXL)
    }
}

private struct RenderFailureView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: Metrics.spaceL) {
            Text("The report could not be built")
                .font(.sectionTitle)
                .foregroundStyle(Color.ink)
            Text(message)
                .font(.bodyField)
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
            Button(action: onRetry) {
                Text("Try again")
                    .font(.bodyFieldMedium)
                    .foregroundStyle(Color.paper)
                    .padding(.horizontal, Metrics.spaceXL)
                    .frame(minHeight: Metrics.tapTargetRepeated)
                    .background(Color.ink)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.radius))
            }
            .buttonStyle(.plain)
        }
        .padding(Metrics.spaceXXL)
    }
}

struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = UIColor(Color.field)
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.documentURL != url {
            uiView.document = PDFDocument(url: url)
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
