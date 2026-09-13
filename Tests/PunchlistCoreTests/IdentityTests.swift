import XCTest
@testable import PunchlistCore

final class UUIDv7Tests: XCTestCase {

    override func setUp() {
        super.setUp()
        UUIDv7._resetMonotonicState()
    }

    func testFormatIsValidV7() {
        for _ in 0..<200 {
            let id = UUIDv7.generate()
            XCTAssertTrue(UUIDv7.isValid(id), "not a well-formed v7: \(id)")
        }
    }

    /// The property the whole schema leans on: ids sort in creation order, so
    /// inserts land at the right edge of the B-tree.
    func testIdsSortInCreationOrder() {
        var ids: [String] = []
        for _ in 0..<5_000 { ids.append(UUIDv7.generate()) }
        XCTAssertEqual(ids, ids.sorted(), "v7 ids must be lexically time-ordered")
    }

    /// Batch capture: ten shutter taps inside one millisecond must still sort in
    /// the order they were shot.
    func testMonotonicWithinOneMillisecond() {
        let fixed: Int64 = 1_800_000_000_000
        let ids = (0..<2_000).map { _ in UUIDv7.generate(now: fixed) }
        XCTAssertEqual(ids, ids.sorted())
        XCTAssertEqual(Set(ids).count, ids.count, "ids must be unique")
    }

    /// An NTP correction or a user changing the date must not produce an id
    /// that sorts before one we already issued.
    func testClockGoingBackwardsStillSortsForward() {
        let a = UUIDv7.generate(now: 1_800_000_000_000)
        let b = UUIDv7.generate(now: 1_700_000_000_000)  // clock jumps back
        let c = UUIDv7.generate(now: 1_700_000_000_001)
        XCTAssertLessThan(a, b)
        XCTAssertLessThan(b, c)
    }

    func testTimestampRoundTrip() {
        let now: Int64 = 1_800_000_123_456
        let id = UUIDv7.generate(now: now)
        XCTAssertEqual(UUIDv7.timestamp(of: id), now)
    }
}

final class HLCTests: XCTestCase {

    private let deviceA = "aaaaaaaaaaaa"
    private let deviceB = "bbbbbbbbbbbb"

    /// The encoding's whole purpose: SQLite compares these as TEXT with `>`, so
    /// lexical order must equal causal order.
    func testLexicalOrderEqualsCausalOrder() {
        let samples = [
            HLC(millis: 1, counter: 0, deviceID: deviceA),
            HLC(millis: 1, counter: 1, deviceID: deviceA),
            HLC(millis: 2, counter: 0, deviceID: deviceA),
            HLC(millis: 10, counter: 0, deviceID: deviceA),
            HLC(millis: 1_800_000_000_000, counter: 99_999, deviceID: deviceA),
        ]
        XCTAssertEqual(samples.map(\.text), samples.map(\.text).sorted())
        XCTAssertEqual(samples, samples.sorted())
    }

    func testTextRoundTrip() {
        let hlc = HLC(millis: 1_800_000_000_123, counter: 42, deviceID: deviceA)
        XCTAssertEqual(HLC(text: hlc.text), hlc)
        XCTAssertEqual(hlc.text.count, HLC.millisWidth + 1 + HLC.counterWidth + 1 + HLC.deviceIDWidth)
    }

    func testTickAdvancesMonotonically() throws {
        var fake: Int64 = 1_000
        let clock = HybridLogicalClock(deviceID: deviceA, now: { fake })
        var previous = try clock.tick()
        for i in 0..<500 {
            if i % 50 == 0 { fake += 1 }
            let next = try clock.tick()
            XCTAssertGreaterThan(next, previous)
            previous = next
        }
    }

    /// Acceptance test 4: two devices edit the same field offline; the higher
    /// HLC wins *deterministically, on both devices*. The device id is what
    /// makes the comparison total rather than merely usually-decisive.
    func testConcurrentWritesResolveIdenticallyOnBothDevices() throws {
        let sameInstant: Int64 = 1_800_000_000_000
        let a = HybridLogicalClock(deviceID: deviceA, now: { sameInstant })
        let b = HybridLogicalClock(deviceID: deviceB, now: { sameInstant })

        let writeA = try a.tick()
        let writeB = try b.tick()

        XCTAssertNotEqual(writeA, writeB, "equal HLCs would make LWW a coin toss")

        // Both devices, applying the same rule to the same pair, pick the same
        // winner — which is the actual requirement.
        let winnerOnA = max(writeA, writeB)
        let winnerOnB = max(writeB, writeA)
        XCTAssertEqual(winnerOnA, winnerOnB)
        XCTAssertEqual(winnerOnA.deviceID, deviceB, "ties break on device id, higher wins")
    }

    func testObservePullsLocalClockForward() throws {
        var fake: Int64 = 1_000
        let local = HybridLogicalClock(deviceID: deviceA, now: { fake })
        _ = try local.tick()

        let remote = HLC(millis: 5_000, counter: 7, deviceID: deviceB)
        let merged = try local.observe(remote)

        XCTAssertGreaterThan(merged, remote, "observing must advance past what we saw")
        XCTAssertEqual(merged.millis, 5_000)
        XCTAssertEqual(merged.counter, 8)

        fake = 6_000
        let next = try local.tick()
        XCTAssertGreaterThan(next, merged)
    }

    /// A peer with a badly wrong clock must fail loudly rather than poison every
    /// later write with a timestamp from years in the future.
    func testExcessiveDriftIsRejected() throws {
        let now: Int64 = 1_800_000_000_000
        let clock = HybridLogicalClock(deviceID: deviceA, now: { now })
        let wayAhead = HLC(millis: now + HLC.maxDriftMillis + 1, counter: 0, deviceID: deviceB)
        XCTAssertThrowsError(try clock.observe(wayAhead)) { error in
            guard case HLCError.excessiveDrift = error else {
                return XCTFail("expected excessiveDrift, got \(error)")
            }
        }
    }

    func testDeviceIDIsFixedWidth() {
        XCTAssertEqual(HLC.deviceID(from: UUID().uuidString).count, HLC.deviceIDWidth)
        XCTAssertEqual(HLC.deviceID(from: "ab").count, HLC.deviceIDWidth)
    }
}
