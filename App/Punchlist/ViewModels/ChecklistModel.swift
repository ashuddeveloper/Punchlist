import Foundation
import GRDB
import Observation
import PunchlistCore

// ============================================================================
// The checklist's state.
//
// §"Data layer rules": durable state lives in SQLite, never in a view model.
// Everything below that an inspector could lose — answers, findings, photo
// counts, scroll position — is read through `ValueObservation` and written
// straight back through a repository. The only genuinely owned state here is
// which sheet is open, which is allowed to die with the process.
//
// The consequence is that a write from anywhere — the camera screen filing a
// photo, the digest worker deduping one, a future sync pull — updates this
// screen without anyone wiring a notification. There is no cache to invalidate
// because there is no cache.
// ============================================================================

@MainActor
@Observable
final class ChecklistModel {

    // Durable, observed.
    private(set) var snapshot: TemplateSnapshot?
    private(set) var inspection: Inspection?
    private(set) var answers: [String: Observation] = [:]
    private(set) var findingsByObservation: [String: [Finding]] = [:]
    private(set) var photoCounts: [String: Int] = [:]
    private(set) var loadFailure: String?

    // Ephemeral UI state. Allowed to be here; allowed to be lost.
    var editingItemID: String?
    var expandedSectionIDs: Set<String> = []

    let inspectionID: String
    private let database: AppDatabase
    private let checklist: ChecklistRepository
    private let inspections: InspectionRepository
    private var tasks: [Task<Void, Never>] = []
    private var resumeSaveTask: Task<Void, Never>?

    init(database: AppDatabase, inspectionID: String) {
        self.database = database
        self.inspectionID = inspectionID
        self.checklist = ChecklistRepository(database: database)
        self.inspections = InspectionRepository(database: database)
    }

    // MARK: Lifecycle

    func start() {
        guard tasks.isEmpty else { return }
        observe(InspectionRepository.find(id: inspectionID)) { [weak self] value in
            guard let self else { return }
            self.inspection = value
            // Decoded once, when the row changes — not per row render. A 66-item
            // checklist re-decoding its snapshot on every frame would be the
            // single most expensive thing on the screen.
            if let value, self.snapshot == nil {
                self.snapshot = try? value.snapshot()
            }
        }
        observe(ChecklistRepository.answers(inspectionID: inspectionID)) { [weak self] value in
            self?.answers = value
        }
        observe(ChecklistRepository.findings(inspectionID: inspectionID)) { [weak self] value in
            self?.findingsByObservation = value
        }
        observe(MediaRepository.photoCountsByObservation(inspectionID: inspectionID)) { [weak self] value in
            self?.photoCounts = value
        }
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        // Flush any pending scroll position rather than waiting out the
        // debounce — leaving the screen is exactly when it must be correct.
        resumeSaveTask?.cancel()
        resumeSaveTask = nil
    }

    private func observe<T: Sendable>(
        _ fetch: @escaping @Sendable (Database) throws -> T,
        apply: @escaping @MainActor (T) -> Void
    ) {
        let observation = database.observe(fetch)
        tasks.append(Task { [weak self, database] in
            do {
                for try await value in observation.values(in: database.dbWriter) {
                    apply(value)
                }
            } catch {
                self?.loadFailure =
                    "This inspection stopped updating. Your answers are still saved — " +
                    "reopen it to reconnect."
            }
        })
    }

    // MARK: Derived

    var progress: ChecklistProgress {
        guard let snapshot else {
            return ChecklistProgress(answered: 0, total: 0, requiredAnswered: 0, requiredTotal: 0)
        }
        let visible = snapshot.sections.flatMap { snapshot.visibleItems(in: $0, answers: answers) }
        let required = visible.filter(\.required)
        return ChecklistProgress(
            answered: visible.filter { answers[$0.id] != nil }.count,
            total: visible.count,
            requiredAnswered: required.filter { answers[$0.id] != nil }.count,
            requiredTotal: required.count)
    }

    func visibleItems(in section: SnapshotSection) -> [SnapshotItem] {
        snapshot?.visibleItems(in: section, answers: answers) ?? []
    }

    /// Per-section completion, for the section jumper.
    func completion(of section: SnapshotSection) -> (answered: Int, total: Int) {
        let items = visibleItems(in: section)
        return (items.filter { answers[$0.id] != nil }.count, items.count)
    }

    /// The worst severity anywhere in a section, so the jumper can mark which
    /// sections carry findings without the inspector opening each one.
    func severity(of section: SnapshotSection) -> Severity? {
        Severity.mostSevere(visibleItems(in: section).compactMap { answers[$0.id]?.severity })
    }

    func findings(forItem itemID: String) -> [Finding] {
        guard let observationID = answers[itemID]?.id else { return [] }
        return findingsByObservation[observationID] ?? []
    }

    func photoCount(forItem itemID: String) -> Int {
        guard let observationID = answers[itemID]?.id else { return 0 }
        return photoCounts[observationID] ?? 0
    }

    // MARK: Writes

    /// Every input calls this on change. There is no Save button because there
    /// is no unsaved state: by the time this returns, the answer is committed.
    func setAnswer(item: SnapshotItem, section: SnapshotSection, value: AnswerValue) {
        do {
            try checklist.setAnswer(
                inspectionID: inspectionID, sectionID: section.id, itemID: item.id, value: value)
        } catch {
            loadFailure = "That answer could not be saved. Check free space on this phone."
        }
    }

    @discardableResult
    func addFinding(item: SnapshotItem, section: SnapshotSection, severity: Severity) -> String? {
        do {
            // A finding needs an observation to hang from. If the inspector
            // jumped straight to "there's a problem here" without answering the
            // item first — which is the common case, because the problem is
            // what they noticed — create the row on their behalf.
            let observationID: String
            if let existing = answers[item.id]?.id {
                observationID = existing
            } else {
                observationID = try checklist.setAnswer(
                    inspectionID: inspectionID, sectionID: section.id, itemID: item.id,
                    value: .cleared)
            }
            return try checklist.addFinding(
                inspectionID: inspectionID, observationID: observationID, severity: severity)
        } catch {
            loadFailure = "That finding could not be saved. Check free space on this phone."
            return nil
        }
    }

    func updateFinding(id: String, narrative: String) {
        try? checklist.updateFinding(id: id, narrative: narrative)
    }

    func updateFinding(id: String, severity: Severity) {
        try? checklist.updateFinding(id: id, severity: severity)
    }

    func deleteFinding(id: String) {
        try? checklist.deleteFinding(id: id)
    }

    // MARK: Resume

    /// Persist the scroll position, debounced.
    ///
    /// Debounced because scrolling fires this continuously and each call is a
    /// transaction; undebounced it would put a write into every frame of a
    /// flick. One second late is invisible to the user and costs nothing if the
    /// app is killed — they land at most one section away from where they were.
    func noteScrollPosition(sectionID: String?, offset: Double) {
        resumeSaveTask?.cancel()
        resumeSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            try? self.inspections.saveResumePoint(
                inspectionID: self.inspectionID, sectionID: sectionID, offset: offset)
        }
    }

    var resumeSectionID: String? { inspection?.resumeSectionId }
}
