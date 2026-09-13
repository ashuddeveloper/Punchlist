import Foundation
import PunchlistCore
import UIKit

// ============================================================================
// The only decoded images the app holds.
//
// §"Performance budgets": 250 photos scroll at 60fps under 250MB. That is
// achievable only if lists render 256px thumbnails and nothing else — a grid
// cell that decodes a 2048px display variant is using 64× the pixels it can
// show. Full-resolution images belong to the photo viewer alone, which loads
// one and releases it on blur.
// ============================================================================

/// An LRU cache of decoded thumbnails, shared across every grid and list.
actor ThumbnailStore {

    static let shared = ThumbnailStore()

    /// `NSCache` rather than a dictionary: it evicts under memory pressure on
    /// its own, which is the behaviour we want on a phone that is also running
    /// the camera. A hand-rolled LRU would need us to guess the right ceiling
    /// and would still not respond to a memory warning.
    ///
    /// The cost limit is in bytes of decoded bitmap. 256×256 RGBA is ~256KB, so
    /// 48MB holds roughly 190 thumbnails — more than fill a screen several
    /// times over, and well inside the budget.
    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    /// In-flight decodes, so a fast scroll that asks for the same thumbnail
    /// three times decodes it once.
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    func image(relativePath: String, store: MediaStore) async -> UIImage? {
        if let cached = cache.object(forKey: relativePath as NSString) { return cached }

        if let existing = inFlight[relativePath] { return await existing.value }

        let task = Task<UIImage?, Never> { [store] in
            await Self.decode(relativePath: relativePath, store: store)
        }
        inFlight[relativePath] = task
        let image = await task.value
        inFlight[relativePath] = nil

        if let image {
            cache.setObject(image, forKey: relativePath as NSString, cost: image.decodedCost)
        }
        return image
    }

    func evict(relativePath: String) {
        cache.removeObject(forKey: relativePath as NSString)
    }

    func evictAll() {
        cache.removeAllObjects()
    }

    /// Decoded off the main actor, and forced to decode *now* rather than
    /// lazily at draw time. A `UIImage` backed by an undecoded file decodes on
    /// the render thread on first display, which is precisely the dropped frame
    /// we are trying to avoid during a fast scroll.
    private static func decode(relativePath: String, store: MediaStore) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                let url = store.url(forRelativePath: relativePath)
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                      let image = UIImage(data: data) else { return nil }
                return image.preparingForDisplay() ?? image
            }
        }.value
    }
}

private extension UIImage {
    /// Approximate bytes of decoded bitmap, for the cache's cost accounting.
    var decodedCost: Int {
        guard let cgImage else { return 256 * 1024 }
        return cgImage.height * cgImage.bytesPerRow
    }
}
