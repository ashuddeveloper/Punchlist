import Foundation
import GRDB

/// The value an inspector recorded for one checklist item.
public enum AnswerValue: Sendable, Equatable {
    case text(String)
    case number(Double)
    case bool(Bool)
    /// multiselect. Stored tab-joined in `value_text`; nothing queries inside
    /// it, so JSON would buy nothing and cost a parse per row on a 200-item
    /// checklist.
    case options([String])
    case rating(Int)
    /// Clearing an answer. Note this blanks the *value*, not the row: any
    /// findings and photos already attached to the item survive.
    case cleared

    var columns: [String: (any DatabaseValueConvertible)?] {
        switch self {
        case .text(let s):
            return ["value_text": s, "value_number": nil, "value_bool": nil]
        case .number(let d):
            return ["value_text": nil, "value_number": d, "value_bool": nil]
        case .rating(let i):
            return ["value_text": nil, "value_number": Double(i), "value_bool": nil]
        case .bool(let b):
            return ["value_text": nil, "value_number": nil, "value_bool": b]
        case .options(let list):
            return [
                "value_text": list.joined(separator: "\t"), "value_number": nil, "value_bool": nil,
            ]
        case .cleared:
            return ["value_text": nil, "value_number": nil, "value_bool": nil]
        }
    }
}

/// The hot path: reading and writing checklist answers and findings.
public struct ChecklistRepository: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) { self.database = database }

    // MARK: Reads

    /// All answers for an inspection, keyed by item id.
    ///
    /// Fetched as one query and held as a dictionary rather than queried per
    /// row: a 200-item checklist scrolling at 60fps cannot afford a database
    /// round trip per cell, and the whole answer set for a real inspection is a
    /// few tens of kilobytes.
    public static func answers(inspectionID: String) -> @Sendable (Database) throws -> [String: Observation] {
        { db in
            let rows = try Observation.fetchAll(db, sql: """
                SELECT * FROM observation
                WHERE inspection_id = ? AND deleted_at IS NULL
                """, arguments: [inspectionID])
            return Dictionary(rows.map { ($0.itemId, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// All findings for an inspection, grouped by observation id.
    public static func findings(inspectionID: String) -> @Sendable (Database) throws -> [String: [Finding]] {
        { db in
            let rows = try Finding.fetchAll(db, sql: """
                SELECT * FROM finding
                WHERE inspection_id = ? AND deleted_at IS NULL
                ORDER BY sort_order, id
                """, arguments: [inspectionID])
            return Dictionary(grouping: rows, by: \.observationId)
        }
    }

    /// The severity summary — the page clients actually read. Ordered most
    /// urgent first.
    public static func findingsBySeverity(inspectionID: String, minimum: Severity = .monitor)
        -> @Sendable (Database) throws -> [Finding]
    {
        { db in
            let allowed = Severity.allCases.filter { $0.rank >= minimum.rank }.map(\.rawValue)
            let placeholders = Array(repeating: "?", count: allowed.count).joined(separator: ",")
            let rows = try Finding.fetchAll(db, sql: """
                SELECT * FROM finding
                WHERE inspection_id = ? AND severity IN (\(placeholders)) AND deleted_at IS NULL
                ORDER BY sort_order, id
                """, arguments: StatementArguments([inspectionID] + allowed))
            return rows.sorted {
                $0.severity.rank != $1.severity.rank
                    ? $0.severity.rank > $1.severity.rank
                    : ($0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.id < $1.id)
            }
        }
    }

    /// Completion, for the persistent progress affordance on the checklist.
    public static func progress(inspectionID: String, snapshot: TemplateSnapshot)
        -> @Sendable (Database) throws -> ChecklistProgress
    {
        { db in
            let answers = try answers(inspectionID: inspectionID)(db)
            let required = snapshot.allItems.filter { $0.required }
            let visibleRequired = required.filter { snapshot.isVisible(item: $0, answers: answers) }
            let answeredRequired = visibleRequired.filter { answers[$0.id] != nil }
            let visibleAll = snapshot.sections.flatMap {
                snapshot.visibleItems(in: $0, answers: answers)
            }
            return ChecklistProgress(
                answered: visibleAll.filter { answers[$0.id] != nil }.count,
                total: visibleAll.count,
                requiredAnswered: answeredRequired.count,
                requiredTotal: visibleRequired.count)
        }
    }

    // MARK: Writes

    /// Record an answer, creating the observation row lazily.
    ///
    /// Observations are sparse: an untouched checklist costs zero rows, so a
    /// 200-item template is free until the inspector actually touches it. This
    /// is also what makes `ctx.update` safe to call from a SwiftUI binding —
    /// it writes nothing, ticks no clock and appends no outbox row when the
    /// value did not actually change.
    @discardableResult
    public func setAnswer(
        inspectionID: String,
        sectionID: String,
        itemID: String,
        value: AnswerValue
    ) throws -> String {
        try database.write { ctx in
            if let existing = try String.fetchOne(ctx.db, sql: """
                SELECT id FROM observation
                WHERE inspection_id = ? AND item_id = ? AND deleted_at IS NULL
                """, arguments: [inspectionID, itemID])
            {
                try ctx.update(.observation, id: existing, value.columns)
                try markSearchDirty(ctx, inspectionID: inspectionID)
                return existing
            }

            var columns = value.columns
            columns["inspection_id"] = inspectionID
            columns["item_id"] = itemID
            columns["section_id"] = sectionID
            let id = try ctx.insert(.observation, columns)
            try markSearchDirty(ctx, inspectionID: inspectionID)
            return id
        }
    }

    public func setLocationNote(observationID: String, _ note: String?) throws {
        try database.write { ctx in
            try ctx.update(.observation, id: observationID, ["location_note": note])
        }
    }

    /// Add a finding to an item. One item routinely carries several — cracked
    /// shingles at the NE valley, moss on the north slope, a missing vent boot.
    @discardableResult
    public func addFinding(
        inspectionID: String,
        observationID: String,
        severity: Severity,
        narrative: String = "",
        recommendation: String? = nil,
        locationNote: String? = nil,
        cannedCommentID: String? = nil
    ) throws -> String {
        try database.write { ctx in
            let nextOrder = try Int.fetchOne(ctx.db, sql: """
                SELECT COALESCE(MAX(sort_order), -1) + 1 FROM finding
                WHERE observation_id = ? AND deleted_at IS NULL
                """, arguments: [observationID]) ?? 0

            let id = try ctx.insert(.finding, [
                "inspection_id": inspectionID,
                "observation_id": observationID,
                "severity": severity.rawValue,
                "narrative": narrative,
                "recommendation": recommendation,
                "location_note": locationNote,
                "canned_comment_id": cannedCommentID,
                "sort_order": nextOrder,
            ])

            if let cannedCommentID {
                try bumpCannedComment(ctx, id: cannedCommentID)
            }
            try rollUpSeverity(ctx, observationID: observationID)
            try markSearchDirty(ctx, inspectionID: inspectionID)
            return id
        }
    }

    public func updateFinding(
        id: String,
        severity: Severity? = nil,
        narrative: String? = nil,
        recommendation: String? = nil,
        locationNote: String? = nil
    ) throws {
        try database.write { ctx in
            var patch: [String: (any DatabaseValueConvertible)?] = [:]
            if let severity { patch["severity"] = severity.rawValue }
            if let narrative { patch["narrative"] = narrative }
            if let recommendation { patch["recommendation"] = recommendation }
            if let locationNote { patch["location_note"] = locationNote }
            guard !patch.isEmpty else { return }
            guard try ctx.update(.finding, id: id, patch) else { return }

            if let observationID = try String.fetchOne(
                ctx.db, sql: "SELECT observation_id FROM finding WHERE id = ?", arguments: [id])
            {
                try rollUpSeverity(ctx, observationID: observationID)
            }
            if let inspectionID = try String.fetchOne(
                ctx.db, sql: "SELECT inspection_id FROM finding WHERE id = ?", arguments: [id])
            {
                try markSearchDirty(ctx, inspectionID: inspectionID)
            }
        }
    }

    public func deleteFinding(id: String) throws {
        try database.write { ctx in
            let observationID = try String.fetchOne(
                ctx.db, sql: "SELECT observation_id FROM finding WHERE id = ?", arguments: [id])
            try ctx.softDelete(.finding, id: id)
            if let observationID {
                try rollUpSeverity(ctx, observationID: observationID)
            }
        }
    }

    // MARK: Internals

    /// Denormalise the worst severity of an observation's findings onto the
    /// observation, so the checklist can colour a row without a correlated
    /// subquery per cell. Recomputed on every finding write — it is one indexed
    /// lookup against `idx_finding_observation`, and a stale roll-up would show
    /// the inspector the wrong colour, which is worse than the write cost.
    private func rollUpSeverity(_ ctx: MutationContext, observationID: String) throws {
        let severities = try String.fetchAll(ctx.db, sql: """
            SELECT severity FROM finding
            WHERE observation_id = ? AND deleted_at IS NULL
            """, arguments: [observationID]).compactMap(Severity.init(rawValue:))

        try ctx.update(
            .observation, id: observationID,
            ["severity": Severity.mostSevere(severities)?.rawValue])
    }

    /// `use_count` is the engine behind the feature users will love most: by
    /// inspection 20, most narrative should be one tap. Bumped here rather than
    /// in the UI so it counts actual use, not browsing.
    private func bumpCannedComment(_ ctx: MutationContext, id: String) throws {
        let current = try Int.fetchOne(
            ctx.db, sql: "SELECT use_count FROM canned_comment WHERE id = ?", arguments: [id]) ?? 0
        try ctx.update(.cannedComment, id: id, [
            "use_count": current + 1,
            "last_used_at": ctx.now,
        ])
    }

    /// Search is rebuilt lazily. Nobody searches mid-keystroke, and writing FTS
    /// rows on every character would put an insert into the typing path.
    private func markSearchDirty(_ ctx: MutationContext, inspectionID: String) throws {
        try ctx.db.execute(
            sql: "UPDATE inspection SET search_dirty = 1 WHERE id = ? AND search_dirty = 0",
            arguments: [inspectionID])
    }
}

public struct ChecklistProgress: Sendable, Equatable {
    public let answered: Int
    public let total: Int
    public let requiredAnswered: Int
    public let requiredTotal: Int

    public var fraction: Double { total == 0 ? 0 : Double(answered) / Double(total) }
    public var isComplete: Bool { requiredAnswered >= requiredTotal }

    public init(answered: Int, total: Int, requiredAnswered: Int, requiredTotal: Int) {
        self.answered = answered
        self.total = total
        self.requiredAnswered = requiredAnswered
        self.requiredTotal = requiredTotal
    }
}
