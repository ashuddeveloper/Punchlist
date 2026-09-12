import Foundation
import GRDB

/// The application's database handle.
///
/// A `DatabasePool`, not a queue: SwiftUI reads through `ValueObservation` on
/// reader connections while capture writes on a background queue. With WAL,
/// those readers never block the writer and the writer never blocks them —
/// which is the difference between a photo grid that scrolls at 60fps during a
/// batch import and one that stutters every time a row lands.
public final class AppDatabase: Sendable {
    public let dbWriter: any DatabaseWriter
    public let clock: HybridLogicalClock
    public let deviceID: String

    private init(dbWriter: any DatabaseWriter, clock: HybridLogicalClock, deviceID: String) {
        self.dbWriter = dbWriter
        self.clock = clock
        self.deviceID = deviceID
    }

    // MARK: Opening

    public static func open(at path: String) throws -> AppDatabase {
        let pool = try DatabasePool(path: path, configuration: configuration())
        return try bootstrap(pool)
    }

    /// In-memory database for tests. Uses a queue because an in-memory SQLite
    /// database cannot be opened by a second connection.
    public static func inMemory() throws -> AppDatabase {
        let queue = try DatabaseQueue(configuration: configuration())
        return try bootstrap(queue)
    }

    public static func configuration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            // synchronous = NORMAL is durable across an app crash when paired
            // with WAL, and our threat model is a force-quit, not a power cut.
            // It is several times faster than FULL on phone flash, which is
            // what lets every keystroke be its own committed transaction.
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
            try db.execute(sql: "PRAGMA cache_size = -8000")
        }
        return config
    }

    private static func bootstrap(_ writer: any DatabaseWriter) throws -> AppDatabase {
        try Migrations.makeMigrator().migrate(writer)
        try writer.read { try Migrations.verifyChecksums($0) }

        let (deviceID, lastHLC) = try writer.write { db -> (String, HLC?) in
            let deviceID = try Self.ensureDeviceID(db)
            let last = try String.fetchOne(
                db, sql: "SELECT value FROM sync_state WHERE key = 'last_hlc'")
            return (deviceID, last.flatMap(HLC.init(text:)))
        }

        return AppDatabase(
            dbWriter: writer,
            clock: HybridLogicalClock(deviceID: deviceID, last: lastHLC),
            deviceID: deviceID)
    }

    /// Every device needs a stable id before any account exists — §2.5 says the
    /// first launch goes straight into a demo inspection, and that inspection's
    /// rows already need HLCs that will not collide with anyone else's.
    private static func ensureDeviceID(_ db: Database) throws -> String {
        if let existing = try String.fetchOne(
            db, sql: "SELECT value FROM sync_state WHERE key = 'device_id'") {
            return existing
        }
        let id = HLC.deviceID(from: UUID().uuidString)
        try db.execute(
            sql: "INSERT INTO sync_state (key, value) VALUES ('device_id', ?)", arguments: [id])
        return id
    }

    // MARK: Access

    /// The only write entry point. Everything inside runs in one transaction.
    public func write<T>(_ body: (MutationContext) throws -> T) throws -> T {
        try dbWriter.write { db in
            try body(MutationContext(db: db, clock: clock))
        }
    }

    public func read<T>(_ body: (Database) throws -> T) throws -> T {
        try dbWriter.read(body)
    }

    /// Observe a query and re-emit whenever its results change. This is what
    /// makes "durable state lives in SQLite" and "the UI is reactive" the same
    /// mechanism instead of two mechanisms that can disagree.
    public func observe<T>(
        _ fetch: @escaping @Sendable (Database) throws -> T
    ) -> ValueObservation<ValueReducers.Fetch<T>> {
        ValueObservation.tracking(fetch)
    }
}
