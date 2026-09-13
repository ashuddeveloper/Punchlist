import Foundation
import PunchlistCore

// ============================================================================
// Where photo bytes live.
//
// The database stores *relative* paths, never absolute ones. iOS rewrites the
// application container path on reinstall and can move it across OS upgrades,
// so an absolute path saved in March is a broken image in September. Every
// path in the `media` table is relative to this store's root, and only this
// type ever turns one into a URL.
// ============================================================================

/// Resolves the sandbox-relative paths held in the `media` table.
struct MediaStore: Sendable {

    /// `Application Support/Media`, not `Documents` and not `Caches`.
    ///
    /// `Caches` is wrong because iOS will evict it under disk pressure — which
    /// is *precisely* when an inspector has 250 photos on a full phone, so the
    /// system would delete their morning's work at the worst possible moment.
    /// `Documents` is wrong because it is user-visible in Files and these are
    /// derived artifacts, not documents.
    let root: URL

    init(root: URL? = nil) throws {
        if let root {
            self.root = root
        } else {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            self.root = base.appendingPathComponent("Media", isDirectory: true)
        }
        try FileManager.default.createDirectory(
            at: self.root, withIntermediateDirectories: true)

        // Photos are re-derivable from nothing — they are the only copy — so
        // they must not go to iCloud backup implicitly *and* must not be
        // purgeable. Excluding from backup keeps a 4GB inspection from filling
        // the user's iCloud quota; the app's own export is the backup story.
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableRoot = self.root
        try? mutableRoot.setResourceValues(resourceValues)
    }

    // MARK: Paths

    /// Photos are bucketed per inspection so that deleting an inspection is one
    /// directory removal rather than 750 unlinks, and so a directory never
    /// holds more than a few hundred entries.
    func directory(forInspection inspectionID: String, variant: Variant) -> String {
        "\(inspectionID)/\(variant.rawValue)"
    }

    func relativePath(inspectionID: String, mediaID: String, variant: Variant) -> String {
        "\(directory(forInspection: inspectionID, variant: variant))/\(mediaID).\(variant.fileExtension)"
    }

    func url(forRelativePath path: String) -> URL {
        root.appendingPathComponent(path)
    }

    func createDirectories(forInspection inspectionID: String) throws {
        for variant in Variant.allCases {
            try FileManager.default.createDirectory(
                at: url(forRelativePath: directory(forInspection: inspectionID, variant: variant)),
                withIntermediateDirectories: true)
        }
    }

    enum Variant: String, CaseIterable, Sendable {
        /// 2048px long edge, q=0.8. What the report embeds.
        case display
        /// 256px. What every list renders.
        case thumb
        /// Full sensor resolution. Written only when the org opts in.
        case original
        /// Voice notes.
        case audio

        var fileExtension: String {
            switch self {
            case .display, .thumb, .original: return "jpg"
            case .audio: return "m4a"
            }
        }
    }

    // MARK: Writing

    /// Write bytes to their final path via a temporary file and an atomic
    /// rename.
    ///
    /// A force-quit mid-write must never leave a truncated JPEG at a path the
    /// database will later claim is a photo. `.atomic` gives us all-or-nothing:
    /// either the file is complete at that path or it is not there at all, and
    /// "not there" is the recoverable case.
    func write(_ data: Data, toRelativePath path: String) throws {
        let destination = url(forRelativePath: path)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: [.atomic])
    }

    func remove(relativePath: String) {
        try? FileManager.default.removeItem(at: url(forRelativePath: relativePath))
    }

    func fileSize(relativePath: String) -> Int64? {
        let values = try? url(forRelativePath: relativePath)
            .resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize.map(Int64.init)
    }

    func exists(relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url(forRelativePath: relativePath).path)
    }

    // MARK: Free space

    /// Bytes actually available to this app.
    ///
    /// `volumeAvailableCapacityForImportantUsageKey`, not
    /// `volumeAvailableCapacityKey`: the former accounts for space iOS would
    /// free by evicting purgeable caches, which is the number that decides
    /// whether our write will really succeed. The plain capacity key reports a
    /// phone as full when it is merely full of other apps' caches, and we would
    /// block the shutter for no reason.
    func availableBytes() -> Int64? {
        let values = try? root.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
