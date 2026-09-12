import Foundation
import GRDB

/// The only way to write data in Punchlist.
///
/// Three invariants, all enforced here rather than by convention:
///
///  1. Every write stamps a fresh HLC.
///  2. Every write appends to `outbox` in the *same* SQLite transaction as the
///     data. There is no window in which the data exists and the sync record
///     does not, so a force-quit can never produce a row that will never sync.
///  3. The outbox payload carries only the fields this mutation *changed*.
///     Last-writer-wins is per field (§5.3); a whole-row payload cannot do that
///     — replaying it would clobber fields this device never touched, silently
///     discarding another inspector's work.
///
/// `MutationContext` is only ever constructed inside `dbWriter.write { }`, so
/// holding one is proof you are inside a transaction.
public struct MutationContext {
    public let db: Database
    public let clock: HybridLogicalClock
    public let now: Int64

    init(db: Database, clock: HybridLogicalClock, now: Int64 = Clock.nowMillis()) {
        self.db = db
        self.clock = clock
        self.now = now
    }

    // MARK: Insert

    /// Insert a new row. Returns the id (minted here if not supplied).
    @discardableResult
    public func insert(
        _ table: SyncTable,
        id: String? = nil,
        _ fields: [String: (any DatabaseValueConvertible)?]
    ) throws -> String {
        let rowID = id ?? UUIDv7.generate()
        let hlc = try stamp()

        var columns = fields
        columns["id"] = rowID
        columns["hlc"] = hlc.text
        columns["created_at"] = now
        columns["updated_at"] = now

        let names = columns.keys.sorted()
        let placeholders = Array(repeating: "?", count: names.count).joined(separator: ",")
        let values: [any DatabaseValueConvertible?] = names.map { columns[$0] ?? nil }

        try db.execute(
            sql: "INSERT INTO \(table.rawValue) (\(names.joined(separator: ","))) VALUES (\(placeholders))",
            arguments: StatementArguments(values)
        )

        try appendToOutbox(table: table, rowID: rowID, op: .upsert, fields: columns, hlc: hlc)
        return rowID
    }

    // MARK: Update

    /// Update a row, writing only the fields whose value actually changes.
    ///
    /// The read-before-write is a single primary-key lookup. It costs one B-tree
    /// descent and buys two things: a per-field outbox payload, and the ability
    /// to make a no-op edit genuinely free — which matters because a SwiftUI
    /// `TextField` binding fires on events that did not change the text, and we
    /// do not want a `.tick()` and an outbox row per cursor move.
    @discardableResult
    public func update(
        _ table: SyncTable,
        id: String,
        _ patch: [String: (any DatabaseValueConvertible)?]
    ) throws -> Bool {
        precondition(
            patch.keys.allSatisfy { !SyncTable.managedColumns.contains($0) },
            "\(table.rawValue): hlc/created_at/updated_at/deleted_at are managed by MutationContext"
        )

        guard let existing = try Row.fetchOne(
            db, sql: "SELECT * FROM \(table.rawValue) WHERE id = ?", arguments: [id]
        ) else {
            throw MutationError.rowNotFound(table: table.rawValue, id: id)
        }

        var changed: [String: (any DatabaseValueConvertible)?] = [:]
        for (column, newValue) in patch {
            guard existing.hasColumn(column) else {
                throw MutationError.unknownColumn(table: table.rawValue, column: column)
            }
            let old: DatabaseValue = existing[column]
            let new = newValue?.databaseValue ?? .null
            if old != new { changed[column] = newValue }
        }
        guard !changed.isEmpty else { return false }

        let hlc = try stamp()
        changed["hlc"] = hlc.text
        changed["updated_at"] = now

        let names = changed.keys.sorted()
        let assignments = names.map { "\($0) = ?" }.joined(separator: ",")
        var values: [any DatabaseValueConvertible?] = names.map { changed[$0] ?? nil }
        values.append(id)

        try db.execute(
            sql: "UPDATE \(table.rawValue) SET \(assignments) WHERE id = ?",
            arguments: StatementArguments(values)
        )

        try appendToOutbox(table: table, rowID: id, op: .upsert, fields: changed, hlc: hlc)
        return true
    }

    // MARK: Delete

    /// Soft delete. A hard delete cannot be synced — the peer would have no way
    /// to learn that the row is gone rather than merely absent.
    public func softDelete(_ table: SyncTable, id: String) throws {
        let hlc = try stamp()
        try db.execute(
            sql: "UPDATE \(table.rawValue) SET deleted_at = ?, hlc = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL",
            arguments: [now, hlc.text, now, id]
        )
        guard db.changesCount > 0 else { return }
        try appendToOutbox(
            table: table, rowID: id, op: .delete, fields: ["deleted_at": now], hlc: hlc)
    }

    // MARK: Plumbing

    private func stamp() throws -> HLC {
        let hlc = try clock.tick()
        // Persisted in this same transaction. If the clock only lived in
        // memory, a force-quit would restart it from wall-clock time and it
        // could re-issue an HLC it had already spent — which would make
        // last-writer-wins non-deterministic across a crash.
        try db.execute(
            sql: "INSERT INTO sync_state (key, value) VALUES ('last_hlc', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [hlc.text]
        )
        return hlc
    }

    private func appendToOutbox(
        table: SyncTable,
        rowID: String,
        op: OutboxOp,
        fields: [String: (any DatabaseValueConvertible)?],
        hlc: HLC
    ) throws {
        var payload: [String: AnyEncodableValue] = [:]
        for (k, v) in fields where k != "id" {
            payload[k] = AnyEncodableValue(v?.databaseValue ?? .null)
        }
        let json = try CanonicalJSON.encode(payload)

        try db.execute(
            sql: """
                INSERT INTO outbox (table_name, row_id, op, payload_json, hlc, created_at)
                VALUES (?,?,?,?,?,?)
                """,
            arguments: [table.rawValue, rowID, op.rawValue, json, hlc.text, now]
        )
    }
}

public enum MutationError: Error, CustomStringConvertible {
    case rowNotFound(table: String, id: String)
    case unknownColumn(table: String, column: String)

    public var description: String {
        switch self {
        case .rowNotFound(let t, let id): return "\(t): no row with id \(id)"
        case .unknownColumn(let t, let c): return "\(t): no column named \(c)"
        }
    }
}

/// Encodes a `DatabaseValue` into the outbox payload without losing its type.
/// The sync server needs to tell an integer 0 from a false from a null, because
/// applying the wrong one to a `CHECK`-constrained column fails the write on
/// the far side rather than here, where someone could still see the error.
struct AnyEncodableValue: Encodable {
    let value: DatabaseValue

    init(_ value: DatabaseValue) { self.value = value }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value.storage {
        case .null: try c.encodeNil()
        case .int64(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .blob(let d): try c.encode(d.base64EncodedString())
        }
    }
}
