import GRDB
import Observation
import PunchlistCore
import SwiftUI

// ============================================================================
// The photo grid and the tray.
//
// §8: 250 photos scroll at 60fps under 250MB. That holds because of one rule,
// applied without exception: **grids render 256px thumbnails and nothing
// else.** Full-resolution pixels exist in one place, the viewer, which loads a
// single image and releases it on blur.
//
// A grid cell that rendered the 2048px display variant would be decoding 64×
// the pixels it can show, and 250 of those is several gigabytes of bitmap.
// ============================================================================

@MainActor
@Observable
final class PhotoGridModel {
    private(set) var items: [MediaItem] = []
    var selection: Set<String> = []

    private let database: AppDatabase
    private let inspectionID: String
    private let trayOnly: Bool
    private var task: Task<Void, Never>?

    init(database: AppDatabase, inspectionID: String, trayOnly: Bool) {
        self.database = database
        self.inspectionID = inspectionID
        self.trayOnly = trayOnly
    }

    func start() {
        guard task == nil else { return }
        let fetch = trayOnly
            ? MediaRepository.tray(inspectionID: inspectionID)
            : MediaRepository.photos(inspectionID: inspectionID)
        let observation = database.observe(fetch)
        task = Task { [weak self, database] in
            do {
                for try await rows in observation.values(in: database.dbWriter) {
                    self?.items = rows
                    // Drop selections for photos that no longer exist, or
                    // "file 6 photos" would silently file five.
                    let ids = Set(rows.map(\.id))
                    self?.selection.formIntersection(ids)
                }
            } catch {}
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
}

struct PhotoGridView: View {
    let store: MediaStore
    @State private var model: PhotoGridModel
    let onFile: ((Set<String>) -> Void)?

    init(
        database: AppDatabase, store: MediaStore, inspectionID: String,
        trayOnly: Bool = false, onFile: ((Set<String>) -> Void)? = nil
    ) {
        self.store = store
        self.onFile = onFile
        _model = State(wrappedValue: PhotoGridModel(
            database: database, inspectionID: inspectionID, trayOnly: trayOnly))
    }

    /// Adaptive rather than a fixed column count, so the grid is right on a
    /// phone held one-handed and on an iPad propped on a tailgate.
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 2)]

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.paper.ignoresSafeArea()

            if model.items.isEmpty {
                EmptyTray()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(model.items) { item in
                            ThumbnailCell(
                                item: item,
                                store: store,
                                isSelected: model.selection.contains(item.id))
                            .onTapGesture { model.toggle(item.id) }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }

            if let onFile, !model.selection.isEmpty {
                Button { onFile(model.selection) } label: {
                    Text("File \(model.selection.count) photo\(model.selection.count == 1 ? "" : "s")")
                        .font(.bodyFieldMedium)
                        .foregroundStyle(Color.paper)
                        .frame(maxWidth: .infinity, minHeight: Metrics.tapTargetRepeated)
                        .background(Color.ink)
                }
                .buttonStyle(.plain)
                .padding(Metrics.gutter)
            }
        }
        .task { model.start() }
        .onDisappear { model.stop() }
    }
}

/// One cell. Loads its thumbnail through the shared cache and releases it when
/// the cell scrolls away, which is what keeps a 250-photo grid flat in memory.
private struct ThumbnailCell: View {
    let item: MediaItem
    let store: MediaStore
    let isSelected: Bool

    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Rectangle()
                .fill(Color.field)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .clipped()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.paper, Color.ink)
                    .padding(Metrics.spaceXS)
            }
        }
        .overlay {
            if isSelected {
                Rectangle().strokeBorder(Color.ink, lineWidth: 3)
            }
        }
        .task(id: item.id) {
            guard let thumbPath = item.thumbPath else { return }
            image = await ThumbnailStore.shared.image(relativePath: thumbPath, store: store)
        }
        .onDisappear {
            // Drop the strong reference. The cache keeps it if there is room;
            // if there is not, this is what lets it go.
            image = nil
        }
        .accessibilityLabel(item.caption ?? "Photo")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct EmptyTray: View {
    var body: some View {
        VStack(spacing: Metrics.spaceM) {
            Text("No photos yet")
                .font(.sectionTitle)
                .foregroundStyle(Color.ink)
            Text("Shoot freely — you can file them against items afterwards.")
                .font(.bodyField)
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
        }
        .padding(Metrics.spaceXXL)
    }
}
