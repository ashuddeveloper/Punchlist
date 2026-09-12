import Foundation

/// UUIDv7 — RFC 9562 §5.7.
///
///     48 bits  unix_ts_ms
///      4 bits  version (0b0111)
///     12 bits  rand_a, used here as a monotonic sub-millisecond counter
///      2 bits  variant (0b10)
///     62 bits  rand_b
///
/// Time-sortable, so inserts land at the right edge of the B-tree instead of
/// scattering across it. With ~250 photo rows per inspection that keeps page
/// splits and index locality sane on a phone's flash.
///
/// The `rand_a` counter guarantees strict monotonicity inside a millisecond,
/// which matters for batch capture: ten shutter taps in one tick must still
/// sort in the order they were shot.
public enum UUIDv7 {

    /// Serialises the monotonic counter. Capture fires from a camera queue
    /// while the UI mints ids on the main actor, so this genuinely contends.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastMillis: Int64 = -1
    nonisolated(unsafe) private static var counter: UInt16 = 0

    public static func generate(now: Int64 = Clock.nowMillis()) -> String {
        lock.lock()
        defer { lock.unlock() }

        var millis = now
        if millis == lastMillis {
            counter &+= 1
            if counter > 0xFFF {
                millis = lastMillis + 1
                lastMillis = millis
                counter = 0
            }
        } else if millis > lastMillis {
            lastMillis = millis
            counter = 0
        } else {
            // The wall clock moved backwards — an NTP correction, or the user
            // changed the date. Keep emitting from our high-water mark; the
            // timestamp here is a sort key, not a truth claim.
            millis = lastMillis
            counter &+= 1
            if counter > 0xFFF {
                millis = lastMillis + 1
                lastMillis = millis
                counter = 0
            }
        }

        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = UInt8(truncatingIfNeeded: millis >> 40)
        bytes[1] = UInt8(truncatingIfNeeded: millis >> 32)
        bytes[2] = UInt8(truncatingIfNeeded: millis >> 24)
        bytes[3] = UInt8(truncatingIfNeeded: millis >> 16)
        bytes[4] = UInt8(truncatingIfNeeded: millis >> 8)
        bytes[5] = UInt8(truncatingIfNeeded: millis)
        bytes[6] = 0x70 | UInt8(truncatingIfNeeded: counter >> 8) & 0x0F
        bytes[7] = UInt8(truncatingIfNeeded: counter)

        var random = [UInt8](repeating: 0, count: 8)
        // SecRandom / getrandom via SystemRandomNumberGenerator. We never fall
        // back to a seeded PRNG: colliding ids across two devices would corrupt
        // sync in a way no user could diagnose.
        var rng = SystemRandomNumberGenerator()
        for i in 0..<8 { random[i] = UInt8.random(in: .min ... .max, using: &rng) }
        bytes[8] = 0x80 | (random[0] & 0x3F)
        for i in 1..<8 { bytes[8 + i] = random[i] }

        return format(bytes)
    }

    private static func format(_ b: [UInt8]) -> String {
        func hex(_ range: Range<Int>) -> String {
            b[range].map { String(format: "%02x", $0) }.joined()
        }
        return "\(hex(0..<4))-\(hex(4..<6))-\(hex(6..<8))-\(hex(8..<10))-\(hex(10..<16))"
    }

    /// The embedded millisecond timestamp. Useful for sync windows and for
    /// ordering rows that were created before any clock was trusted.
    public static func timestamp(of id: String) -> Int64? {
        let hex = id.replacingOccurrences(of: "-", with: "").prefix(12)
        guard hex.count == 12 else { return nil }
        return Int64(hex, radix: 16)
    }

    public static func isValid(_ id: String) -> Bool {
        id.range(
            of: "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
            options: .regularExpression
        ) != nil
    }

    /// Test-only hook so fixtures are reproducible.
    public static func _resetMonotonicState() {
        lock.lock()
        lastMillis = -1
        counter = 0
        lock.unlock()
    }
}

public enum Clock {
    /// Epoch milliseconds, UTC. Every timestamp column in the schema is this.
    public static func nowMillis() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }
}
