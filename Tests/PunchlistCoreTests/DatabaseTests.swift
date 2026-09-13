import GRDB
import XCTest
@testable import PunchlistCore

/// Helpers shared by the database tests.
enum Fixture {
    /// A database on disk, so tests can close and reopen it — which is how we
    /// simulate a force-quit.
    static func onDisk() throws -> (AppDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("punchlist-test-\(UUID().uuidString).sqlite")
        return (try AppDatabase.open(at: url.path), url)
    }

    static func remove(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: url.path + suffix))
        }
    }
}

final class MigrationTests: XCTestCase {

    func testSchemaResourceLoads() {
        // A migration resource that failed to ship is a bricked app on someone's
        // phone, so it gets its own test rather than being discovered by every
        // other test failing at once.
        XCTAssertFalse(Migrations.all.isEmpty)
        XCTAssertTrue(Migrations.all[0].sql.contains("CREATE TABLE inspection"))
    }

    func testMigratesAndIsIdempotent() throws {
        let (db, url) = try Fixture.onDisk()
        defer { Fixture.remove(url) }

        let tables = try db.read { d in
            try String.fetchAll(
                d, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        }
        for expected in ["inspection", "observation", "finding", "media", "outbox", "sync_state"] {
            XCTAssertTrue(tables.contains(expected), "missing table \(expected)")
        }

        // Reopening must not re-run anything.
        let reopened = try AppDatabase.open(at: url.path)
        let applied = try reopened.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM schema_migration") ?? 0
        }
        XCTAssertEqual(applied, Migrations.all.count)
    }

    func testEditedMigrationIsRejected() throws {
        let (db, url) = try Fixture.onDisk()
        defer { Fixture.remove(url) }

        try db.dbWriter.write { d in
            try d.execute(sql: "UPDATE schema_migration SET checksum = 'tampered' WHERE id = 1")
        }
        XCTAssertThrowsError(try db.read { try Migrations.verifyChecksums($0) }) { error in
            guard case MigrationIntegrityError.checksumMismatch = error else {
                return XCTFail("expected checksumMismatch, got \(error)")
            }
        }
    }

    /// The CHECK constraints exist so a bad enum fails at the write, not three
    /// weeks later inside the PDF renderer.
    func testEnumConstraintsAreEnforced() throws {
        let db = try AppDatabase.inMemory()
        let seed = try FirstRun.bootstrapIfNeeded(db)

        XCTAssertThrowsError(try db.write { ctx in
            try ctx.db.execute(sql: """
                INSERT INTO finding (id, inspection_id, observation_id, severity, narrative,
                                     sort_order, hlc, created_at, updated_at)
                VALUES ('x', ?, 'o', 'catastrophic', '', 0, '0', 0, 0)
                """, arguments: [seed.demoInspectionID])
        })
    }
}

final class MutationTests: XCTestCase {

    /// §5.1: the data write and the outbox append are one transaction. There is
    /// no window in which a row exists without a sync record.
    func testEveryWriteAppendsToTheOutbox() throws {
        let db = try AppDatabase.inMemory()
        let seed = try FirstRun.bootstrapIfNeeded(db)

        let before = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM outbox") ?? 0 }
        XCTAssertGreaterThan(before, 0, "bootstrap itself must be syncable")

        try db.write { ctx in
            try ctx.update(.inspection, id: seed.demoInspectionID, ["client_name": "Marisol Reyes"])
        }

        let entry = try db.read { d in
            try OutboxEntry.fetchOne(d, sql: "SELECT * FROM outbox ORDER BY seq DESC LIMIT 1")
        }
        XCTAssertEqual(entry?.tableName, "inspection")
        XCTAssertEqual(entry?.rowId, seed.demoInspectionID)
        XCTAssertEqual(entry?.op, "upsert")
    }

    /// §5.3: last-writer-wins is per *field*, so the payload must carry only
    /// what changed. A whole-row payload would clobber fields this device never
    /// touched — silently discarding another inspector's work.
    func testOutboxPayloadCarriesOnlyChangedFields() throws {
        let db = try AppDatabase.inMemory()
        let seed = try FirstRun.bootstrapIfNeeded(db)

        try db.write { ctx in
            try ctx.update(.inspection, id: seed.demoInspectionID, ["weather": "Overcast"])
        }

        let payload = try db.read { d in
            try String.fetchOne(d, sql: "SELECT payload_json FROM outbox ORDER BY seq DESC LIMIT 1")
        }
        let json = try XCTUnwrap(payload)
        XCTAssertTrue(json.contains("weather"))
        XCTAssertTrue(json.contains("hlc"))
        XCTAssertTrue(json.contains("updated_at"))
        XCTAssertFalse(json.contains("template_snapshot_json"),
                       "payload must not carry untouched fields")
        XCTAssertFalse(json.contains("client_name"))
    }

    /// A SwiftUI TextField binding fires on events that did not change the text.
    /// Those must cost nothing — no clock tick, no outbox row.
    func testNoOpUpdateWritesNothing() throws {
        let db = try AppDatabase.inMemory()
        let seed = try FirstRun.bootstrapIfNeeded(db)

        try db.write { ctx in
            try ctx.update(.inspection, id: seed.demoInspectionID, ["weather": "Clear"])
        }
        let after = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM outbox") ?? 0 }

        let changed = try db.write { ctx in
            try ctx.update(.inspection, id: seed.demoInspectionID, ["weather": "Clear"])
        }
        XCTAssertFalse(changed)
        let now = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM outbox") ?? 0 }
        XCTAssertEqual(now, after, "a no-op edit must not produce an outbox row")
    }

    func testSoftDeleteIsSyncable() throws {
        let db = try AppDatabase.inMemory()
        let seed = try FirstRun.bootstrapIfNeeded(db)

        try db.write { ctx in try ctx.softDelete(.inspection, id: seed.demoInspectionID) }

        let entry = try db.read { d in
            try OutboxEntry.fetchOne(d, sql: "SELECT * FROM outbox ORDER BY seq DESC LIMIT 1")
        }
        XCTAssertEqual(entry?.op, "delete")

        let stillThere = try db.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM inspection WHERE id = ?",
                             arguments: [seed.demoInspectionID]) ?? 0
        }
        XCTAssertEqual(stillThere, 1, "a hard delete cannot be synced")
    }

    /// HLCs must keep advancing across a force-quit. If the clock only lived in
    /// memory it would restart from wall-clock time and could re-issue a value
    /// it had already spent, making last-writer-wins non-deterministic.
    func testClockSurvivesReopen() throws {
        let (db, url) = try Fixture.onDisk()
        defer { Fixture.remove(url) }
        let seed = try FirstRun.bootstrapIfNeeded(db)

        try db.write { ctx in
            try ctx.update(.inspection, id: seed.demoInspectionID, ["occupancy": "Vacant"])
        }
        let before = db.clock.peek()

        let reopened = try AppDatabase.open(at: url.path)
        XCTAssertEqual(reopened.deviceID, db.deviceID, "device id must be stable")

        try reopened.write { ctx in
            try ctx.update(.inspection, id: seed.demoInspectionID, ["occupancy": "Occupied — furnished"])
        }
        XCTAssertGreaterThan(reopened.clock.peek(), before)
    }
}
