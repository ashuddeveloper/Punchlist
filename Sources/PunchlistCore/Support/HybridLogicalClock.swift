import Foundation

/// Hybrid Logical Clock.
///
/// Wire format: `{physical_ms}:{counter}:{device_id}`, every field fixed-width
/// and zero-padded so that lexical string comparison *is* causal comparison.
/// SQLite can then order and compare HLCs with a plain `>` on a TEXT column —
/// no collation, no custom function, no deserialisation on the hot path.
///
///     physical_ms  15 digits  (good past the year 33000)
///     counter       5 digits  (99,999 events inside one millisecond)
///     device_id    12 chars   (low 48 bits of the device UUID, hex)
///
/// The device id is the final tiebreaker. Without it, two devices writing the
/// same field in the same millisecond with the same counter would produce equal
/// HLCs and last-writer-wins would not be deterministic. Acceptance test 4 asks
/// for the *same* winner on both devices, not merely for a winner.
public struct HLC: Hashable, Comparable, Sendable {
    public static let millisWidth = 15
    public static let counterWidth = 5
    public static let deviceIDWidth = 12
    public static let maxCounter = 99_999

    /// If logical time runs this far ahead of the wall clock, a peer's clock is
    /// badly wrong. We fail loudly rather than poison every later write with a
    /// timestamp from 2087.
    public static let maxDriftMillis: Int64 = 60 * 60 * 1000

    public let millis: Int64
    public let counter: Int
    public let deviceID: String

    public init(millis: Int64, counter: Int, deviceID: String) {
        self.millis = millis
        self.counter = counter
        self.deviceID = deviceID
    }

    public var text: String {
        let m = String(millis).leftPadded(to: Self.millisWidth)
        let c = String(counter).leftPadded(to: Self.counterWidth)
        return "\(m):\(c):\(deviceID)"
    }

    public init?(text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let m = Int64(parts[0]),
              let c = Int(parts[1]) else { return nil }
        self.init(millis: m, counter: c, deviceID: String(parts[2]))
    }

    /// Causal order. Thanks to the fixed-width encoding this agrees exactly
    /// with a lexical comparison of `text`, which is what the database does.
    public static func < (lhs: HLC, rhs: HLC) -> Bool { lhs.text < rhs.text }

    public static let zero = HLC(
        millis: 0, counter: 0, deviceID: String(repeating: "0", count: HLC.deviceIDWidth))

    /// Normalise any UUID to a fixed-width device id.
    public static func deviceID(from uuid: String) -> String {
        let hex = uuid.lowercased().filter { $0.isHexDigit }
        return String(hex.suffix(deviceIDWidth)).leftPadded(to: deviceIDWidth)
    }
}

public enum HLCError: Error, CustomStringConvertible {
    case counterOverflow
    case excessiveDrift(Int64)

    public var description: String {
        switch self {
        case .counterOverflow:
            return "HLC counter overflow: more than 100,000 events in one millisecond."
        case .excessiveDrift(let d):
            return "HLC drift of \(d)ms exceeds the \(HLC.maxDriftMillis)ms limit; a peer clock is badly wrong."
        }
    }
}

/// Stateful clock. One instance per open database, persisted to `sync_state`
/// inside the same transaction as the mutation it stamps — otherwise a
/// force-quit could let the clock restart behind values already written.
public final class HybridLogicalClock: @unchecked Sendable {
    private let lock = NSLock()
    private let deviceID: String
    private let now: @Sendable () -> Int64
    private var millis: Int64
    private var counter: Int

    public init(deviceID: String, last: HLC? = nil, now: @escaping @Sendable () -> Int64 = Clock.nowMillis) {
        precondition(deviceID.count == HLC.deviceIDWidth, "device id must be \(HLC.deviceIDWidth) chars")
        self.deviceID = deviceID
        self.now = now
        self.millis = last?.millis ?? 0
        self.counter = last?.counter ?? 0
    }

    public func peek() -> HLC {
        lock.lock(); defer { lock.unlock() }
        return HLC(millis: millis, counter: counter, deviceID: deviceID)
    }

    /// Stamp a local mutation. Every write in the app goes through here.
    public func tick() throws -> HLC {
        lock.lock(); defer { lock.unlock() }
        let physical = now()
        let previous = millis
        millis = max(previous, physical)
        counter = (millis == previous) ? counter + 1 : 0
        try guardState(physical: physical)
        return HLC(millis: millis, counter: counter, deviceID: deviceID)
    }

    /// Merge an HLC observed from a peer during a sync pull.
    public func observe(_ remote: HLC) throws -> HLC {
        lock.lock(); defer { lock.unlock() }
        let physical = now()
        let previousMillis = millis
        let previousCounter = counter

        millis = max(previousMillis, remote.millis, physical)
        if millis == previousMillis && millis == remote.millis {
            counter = max(previousCounter, remote.counter) + 1
        } else if millis == previousMillis {
            counter = previousCounter + 1
        } else if millis == remote.millis {
            counter = remote.counter + 1
        } else {
            counter = 0
        }
        try guardState(physical: physical)
        return HLC(millis: millis, counter: counter, deviceID: deviceID)
    }

    private func guardState(physical: Int64) throws {
        if counter > HLC.maxCounter { throw HLCError.counterOverflow }
        let drift = millis - physical
        if drift > HLC.maxDriftMillis { throw HLCError.excessiveDrift(drift) }
    }
}

extension String {
    func leftPadded(to width: Int, with pad: Character = "0") -> String {
        count >= width ? self : String(repeating: String(pad), count: width - count) + self
    }
}
