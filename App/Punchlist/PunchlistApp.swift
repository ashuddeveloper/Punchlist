import PunchlistCore
import SwiftUI

// ============================================================================
// Entry point.
//
// §2.5: no account required to start. First launch opens straight into a
// working inspection with a real template and a real property — no signup
// wall, no onboarding carousel, and no empty list demanding configuration
// before it will show anything. Account creation happens later, at the first
// sync or the first export with a logo.
//
// Cold start budget is 1.2s to a usable list, so the only work on the launch
// path is: open the database, run migrations, seed on first launch. All three
// are synchronous and fast, and none of them touches the network because there
// is no network code to touch.
// ============================================================================

@main
struct PunchlistApp: App {
    @State private var boot: BootState = .loading
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                switch boot {
                case .loading:
                    // Not a splash screen. If the database opens in 40ms, which
                    // it does, nobody ever sees this.
                    Color.paper.ignoresSafeArea()
                case .ready(let environment):
                    InspectionListView(
                        database: environment.database, orgID: environment.orgID)
                        .environment(environment)
                case .failed(let message):
                    LaunchFailure(message: message) { boot = .loading; start() }
                }
            }
            .task { if case .loading = boot { start() } }
        }
    }

    private func start() {
        do {
            let database = try AppDatabase.open(at: AppEnvironment.databasePath())
            let store = try MediaStore()
            let seed = try FirstRun.bootstrapIfNeeded(database)
            boot = .ready(AppEnvironment(
                database: database, store: store, orgID: seed.orgID,
                inspectorID: seed.inspectorID, templateID: seed.templateID))
        } catch {
            boot = .failed(String(describing: error))
        }
    }

    private enum BootState {
        case loading
        case ready(AppEnvironment)
        case failed(String)
    }
}

/// Everything the app needs, resolved once at launch.
@Observable
final class AppEnvironment {
    let database: AppDatabase
    let store: MediaStore
    let orgID: String
    let inspectorID: String
    let templateID: String

    init(database: AppDatabase, store: MediaStore, orgID: String, inspectorID: String, templateID: String) {
        self.database = database
        self.store = store
        self.orgID = orgID
        self.inspectorID = inspectorID
        self.templateID = templateID
    }

    static func databasePath() throws -> String {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return base.appendingPathComponent("punchlist.sqlite").path
    }
}

/// A launch failure is the one error the user cannot work around by retrying a
/// different screen, so it says what happened and offers the only two useful
/// actions rather than a bare "Something went wrong".
private struct LaunchFailure: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: Metrics.spaceL) {
            Text("Punchlist could not open its records")
                .font(.sectionTitle)
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)

            Text("""
                Your inspections are still on this phone. This is usually a full disk — \
                free up space in Settings › General › iPhone Storage and try again.
                """)
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

            Text(message)
                .font(.caption)
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .padding(Metrics.spaceXXL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.paper)
    }
}
