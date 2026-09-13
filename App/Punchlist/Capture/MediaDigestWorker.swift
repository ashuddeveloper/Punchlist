import CryptoKit
import Foundation
import PunchlistCore

// ============================================================================
// Content hashing, deferred.
//
// §"media pipeline": dedupe on sha256 so a re-imported photo does not appear
// twice. But hashing a 4MB JPEG costs tens of milliseconds and touches the
// whole file, and doing it on the capture path would spend most of the 350ms
// shutter budget on a feature nobody is waiting for. So it happens here:
// later, slowly, and never while the inspector is shooting.
// ============================================================================

/// Hashes captured media during idle moments.
final class MediaDigestWorker: @unchecked Sendable {

    private let queue = DispatchQueue(
        label: "com.punchlist.media.digest", qos: .background)

    private let database: AppDatabase
    private let store: MediaStore
    private let media: MediaRepository
    private let isPipelineBusy: @Sendable () -> Bool

    private let stateLock = NSLock()
    private var lastCaptureActivity = Date.distantPast
    private var isSweeping = false
    private var isStarted = false

    /// How long after the last shutter tap we consider the inspector "done
    /// shooting". Short enough that a sweep happens during the walk between
    /// rooms; long enough that it never starts mid-burst.
    private let quietPeriod: TimeInterval = 4

    /// Hashing reads the file in chunks rather than loading it whole. 250
    /// photos at 4MB each is a gigabyte; `Data(contentsOf:)` on each would be
    /// correct and would also be the single largest allocation in the app.
    private let chunkSize = 256 * 1024

    init(
        database: AppDatabase,
        store: MediaStore,
        isBusy: @escaping @Sendable () -> Bool
    ) {
        self.database = database
        self.store = store
        self.media = MediaRepository(database: database)
        self.isPipelineBusy = isBusy
    }

    func start() {
        stateLock.lock()
        let alreadyStarted = isStarted
        isStarted = true
        stateLock.unlock()
        guard !alreadyStarted else { return }
        scheduleSweep()
    }

    /// Called on every shutter tap. Pushes the sweep out of the way.
    func noteCaptureActivity() {
        stateLock.lock()
        lastCaptureActivity = Date()
        stateLock.unlock()
    }

    func scheduleSweep() {
        queue.asyncAfter(deadline: .now() + quietPeriod) { [weak self] in
            self?.sweepIfQuiet()
        }
    }

    private func sweepIfQuiet() {
        stateLock.lock()
        let quiet = Date().timeIntervalSince(lastCaptureActivity) >= quietPeriod
        let busy = isSweeping
        if quiet && !busy { isSweeping = true }
        stateLock.unlock()

        guard quiet, !busy else {
            // Still shooting. Try again rather than giving up — the work is
            // never urgent but it must not be forgotten either, or the dedupe
            // guarantee quietly stops holding.
            scheduleSweep()
            return
        }

        defer {
            stateLock.lock()
            isSweeping = false
            stateLock.unlock()
        }

        // The capture pipeline always wins. Competing with it for CPU would
        // show up as shutter latency, which is the one thing this work is not
        // allowed to cost.
        guard !isPipelineBusy() else {
            scheduleSweep()
            return
        }

        do {
            let batch = try database.read(MediaRepository.awaitingDigest(limit: 20))
            guard !batch.isEmpty else { return }

            for item in batch {
                if isPipelineBusy() { break }
                autoreleasepool {
                    guard let digest = hash(relativePath: item.localPath) else { return }
                    try? media.recordDigest(mediaID: item.id, sha256: digest)
                }
            }
            // More to do: come back for the next batch.
            scheduleSweep()
        } catch {
            // A failed sweep is not worth surfacing. Dedupe is a convenience;
            // the photos are all still there and all still in the report.
        }
    }

    private func hash(relativePath: String) -> String? {
        let url = store.url(forRelativePath: relativePath)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
