import GRDB
import Observation
import PunchlistCore
import SwiftUI

// ============================================================================
// Home.
//
// Budget: cold start to a usable inspection list in under 1.2s (§8). That is
// why this screen reads one indexed query and renders it — no counts, no
// aggregates, no thumbnails fetched per row. Anything richer belongs on the
// inspection itself, which the user has already decided to open.
// ============================================================================

@MainActor
@Observable
final class InspectionListModel {
    private(set) var inspections: [Inspection] = []
    private(set) var addressByPropertyID: [String: String] = [:]
    var filter: InspectionStatus?

    private let database: AppDatabase
    private let orgID: String
    private var task: Task<Void, Never>?

    init(database: AppDatabase, orgID: String) {
        self.database = database
        self.orgID = orgID
    }

    func start() {
        task?.cancel()
        let observation = database.observe { [orgID, filter] db in
            let rows = try InspectionRepository.recent(orgID: orgID, status: filter)(db)
            // Addresses fetched in one query keyed by property, rather than a
            // join per row. The list is capped at 100, so this is one small
            // dictionary rather than 100 round trips.
            let properties = try Property.fetchAll(db, sql: """
                SELECT * FROM property WHERE org_id = ? AND deleted_at IS NULL
                """, arguments: [orgID])
            return (rows, Dictionary(
                properties.map { ($0.id, $0.singleLine) }, uniquingKeysWith: { a, _ in a }))
        }
        task = Task { [weak self, database] in
            do {
                for try await (rows, addresses) in observation.values(in: database.dbWriter) {
                    self?.inspections = rows
                    self?.addressByPropertyID = addresses
                }
            } catch {
                // The list going stale is recoverable by reopening the screen;
                // it is not worth an alert over the whole app.
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func address(for inspection: Inspection) -> String {
        addressByPropertyID[inspection.propertyId] ?? "Address not recorded"
    }
}

struct InspectionListView: View {
    let database: AppDatabase
    @State private var model: InspectionListModel
    @State private var isCreating = false

    init(database: AppDatabase, orgID: String) {
        self.database = database
        _model = State(wrappedValue: InspectionListModel(database: database, orgID: orgID))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.paper.ignoresSafeArea()

                if model.inspections.isEmpty {
                    EmptyInspections { isCreating = true }
                } else {
                    list
                }
            }
            .navigationTitle("Inspections")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isCreating = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: Metrics.tapTarget, height: Metrics.tapTarget)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Start a new inspection")
                }
            }
        }
        .task { model.start() }
        .onDisappear { model.stop() }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.inspections) { inspection in
                    NavigationLink {
                        ChecklistView(database: database, inspectionID: inspection.id)
                    } label: {
                        InspectionRow(
                            inspection: inspection,
                            address: model.address(for: inspection))
                    }
                    .buttonStyle(.plain)
                    Hairline()
                }
            }
        }
    }
}

private struct InspectionRow: View {
    let inspection: Inspection
    let address: String

    var body: some View {
        HStack(spacing: Metrics.spaceM) {
            VStack(alignment: .leading, spacing: Metrics.spaceXS) {
                Text(address)
                    .font(.itemLabel)
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)

                HStack(spacing: Metrics.spaceS) {
                    Text(statusLabel)
                        .font(.figureSmall)
                        .foregroundStyle(Color.slate)
                    if let clientName = inspection.clientName, !clientName.isEmpty {
                        Text("·").foregroundStyle(Color.line)
                        Text(clientName)
                            .font(.caption)
                            .foregroundStyle(Color.slate)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.line)
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(minHeight: 72)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var statusLabel: String {
        switch inspection.status {
        case .draft: return "In progress"
        case .complete: return "Complete"
        case .delivered: return "Delivered"
        }
    }
}

/// Empty states carry direction (§9): say what is missing and give a visible
/// way to fix it. "No inspections yet" on its own is a dead end.
private struct EmptyInspections: View {
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: Metrics.spaceL) {
            Text("No inspections yet")
                .font(.sectionTitle)
                .foregroundStyle(Color.ink)

            Text("Start one and the checklist is ready before you reach the front door.")
                .font(.bodyField)
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            Button(action: onStart) {
                Text("Start an inspection")
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
