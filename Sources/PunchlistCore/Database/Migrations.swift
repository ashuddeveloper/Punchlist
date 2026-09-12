import Foundation
import GRDB

/// Forward-only migration runner.
///
/// Migration SQL lives in `Resources/Migrations/*.sql` — one source of truth
/// that both the app and the CI schema checker read, so the query plans we
/// assert in CI are plans for the schema that actually ships.
///
/// Each migration is checksummed. Editing an already-applied migration is the
/// kind of mistake that produces a database whose schema does not match what
/// the code believes, on a device you cannot reach, in a crawlspace. The runner
/// refuses to open such a database rather than limp on.
public enum Migrations {

    public struct Descriptor: Sendable {
        public let id: Int
        public let name: String
        public let sql: String
        public var identifier: String { String(format: "%03d_%@", id, name) }
    }

    /// Append only.
    public static let all: [Descriptor] = [
        Descriptor(id: 1, name: "init", sql: loadSQL("001_init"))
    ]

    static func loadSQL(_ name: String) -> String {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "sql", subdirectory: "Resources/Migrations")
            ?? Bundle.module.url(forResource: name, withExtension: "sql")
        else {
            // Not recoverable and not worth degrading: an app whose schema
            // resource did not ship cannot store anything.
            fatalError("Missing migration resource \(name).sql — check Package.swift resources.")
        }
        return (try? String(contentsOf: url, encoding: .utf8))
            ?? { fatalError("Migration \(name).sql is not valid UTF-8") }()
    }

    public static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // The bookkeeping table is owned by the runner, not by a migration.
        migrator.registerMigration("000_bookkeeping") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS schema_migration (
                  id INTEGER PRIMARY KEY,
                  name TEXT NOT NULL,
                  checksum TEXT NOT NULL,
                  applied_at INTEGER NOT NULL
                )
                """)
        }

        for descriptor in all.sorted(by: { $0.id < $1.id }) {
            migrator.registerMigration(descriptor.identifier) { db in
                try db.execute(sql: descriptor.sql)
                try db.execute(
                    sql: "INSERT INTO schema_migration (id, name, checksum, applied_at) VALUES (?,?,?,?)",
                    arguments: [
                        descriptor.id, descriptor.name,
                        CanonicalJSON.sha256Hex(descriptor.sql), Clock.nowMillis(),
                    ])
            }
        }
        return migrator
    }

    /// Verify that no applied migration has been edited since it ran.
    public static func verifyChecksums(_ db: Database) throws {
        let applied = try Row.fetchAll(db, sql: "SELECT id, name, checksum FROM schema_migration")
        let byID = Dictionary(uniqueKeysWithValues: applied.map { ($0["id"] as Int, $0) })
        for descriptor in all {
            guard let row = byID[descriptor.id] else { continue }
            let expected = CanonicalJSON.sha256Hex(descriptor.sql)
            if row["checksum"] as String != expected {
                throw MigrationIntegrityError.checksumMismatch(
                    id: descriptor.id, name: descriptor.name)
            }
        }
    }
}

public enum MigrationIntegrityError: Error, CustomStringConvertible {
    case checksumMismatch(id: Int, name: String)

    public var description: String {
        switch self {
        case .checksumMismatch(let id, let name):
            return """
                Migration \(id) (\(name)) has changed since it was applied to this database. \
                Applied migrations are immutable — add a new migration instead.
                """
        }
    }
}
