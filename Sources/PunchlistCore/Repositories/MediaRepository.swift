import Foundation
import GRDB

/// Photos, voice notes and signatures.
public struct MediaRepository: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) { self.database = database }

    // MARK: Reads

    /// Every photo in an inspection, newest first. Matches
    /// `idx_media_by_inspection` so the ORDER BY comes from the index.
    public static func photos(inspectionID: String) -> @Sendable (Database) throws -> [MediaItem] {
        { db in
            try MediaItem.fetchAll(db, sql: """
                SELECT * FROM media
                WHERE inspection_id = ? AND deleted_at IS NULL
                ORDER BY captured_at DESC
                """, arguments: [inspectionID])
        }
    }

    /// The tray: shot but not yet filed. Inspectors shoot first and organise
    /// later, so this is a first-class view, not an error state.
    public static func tray(inspectionID: String) -> @Sendable (Database) throws -> [MediaItem] {
        { db in
            try MediaItem.fetchAll(db, sql: """
                SELECT * FROM media
                WHERE inspection_id = ? AND deleted_at IS NULL
                  AND observation_id IS NULL AND finding_id IS NULL
                ORDER BY captured_at DESC
                """, arguments: [inspectionID])
        }
    }

    public static func photos(observationID: String) -> @Sendable (Database) throws -> [MediaItem] {
        { db in
            try MediaItem.fetchAll(db, sql: """
                SELECT * FROM media
                WHERE observation_id = ? AND deleted_at IS NULL
                ORDER BY sort_order, id
                """, arguments: [observationID])
        }
    }

    /// Photo counts per item, for the checklist rows. One grouped query rather
    /// than a count per cell — a 200-row checklist at 60fps cannot afford 200
    /// queries per frame.
    public static func photoCountsByObservation(inspectionID: String)
        -> @Sendable (Database) throws -> [String: Int]
    {
        { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT observation_id AS oid, COUNT(*) AS n FROM media
                WHERE inspection_id = ? AND deleted_at IS NULL AND observation_id IS NOT NULL
                GROUP BY observation_id
                """, arguments: [inspectionID])
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["oid"] as String, $0["n"] as Int) })
        }
    }

    // MARK: Writes

    /// Record a captured photo.
    ///
    /// Ordering matters and is the caller's responsibility: the JPEG must be
    /// **fully written and fsync'd to its final path before** this is called. A
    /// row pointing at a file that does not exist renders as a broken box in
    /// the report; a file with no row is invisible but merely wastes space. So
    /// we take the recoverable failure: files first, row second, and an
    /// orphaned-file sweep at idle.
    @discardableResult
    public func record(
        orgID: String,
        inspectionID: String?,
        kind: MediaKind,
        localPath: String,
        thumbPath: String?,
        originalPath: String? = nil,
        bytes: Int64?,
        width: Int?,
        height: Int?,
        capturedAt: Int64,
        lat: Double? = nil,
        lon: Double? = nil,
        durationMs: Int? = nil,
        /// Supplied by the capture path, which mints the id at the shutter tap
        /// so that the files on disk are already named after the row before the
        /// row exists. Nothing has to reconcile the two afterwards.
        mediaID: String? = nil
    ) throws -> String {
        try database.write { ctx in
            try ctx.insert(.media, id: mediaID, [
                "org_id": orgID,
                "inspection_id": inspectionID,
                "kind": kind.rawValue,
                "local_path": localPath,
                "thumb_path": thumbPath,
                "original_path": originalPath,
                "upload_state": UploadState.pending.rawValue,
                "upload_attempts": 0,
                "bytes": bytes,
                "width": width,
                "height": height,
                "duration_ms": durationMs,
                "captured_at": capturedAt,
                "lat": lat,
                "lon": lon,
                "sort_order": 0,
            ])
        }
    }

    /// File photos from the tray onto an item, in bulk. The tray exists because
    /// inspectors shoot freely and organise afterwards; filing one at a time
    /// would defeat the point.
    public func file(mediaIDs: [String], toObservation observationID: String, findingID: String? = nil) throws {
        guard !mediaIDs.isEmpty else { return }
        try database.write { ctx in
            let base = try Int.fetchOne(ctx.db, sql: """
                SELECT COALESCE(MAX(sort_order), -1) + 1 FROM media
                WHERE observation_id = ? AND deleted_at IS NULL
                """, arguments: [observationID]) ?? 0

            for (offset, mediaID) in mediaIDs.enumerated() {
                try ctx.update(.media, id: mediaID, [
                    "observation_id": observationID,
                    "finding_id": findingID,
                    "sort_order": base + offset,
                ])
            }
        }
    }

    /// Return photos to the tray without deleting them. Misfiling a photo is
    /// common and must be cheap to undo.
    public func unfile(mediaIDs: [String]) throws {
        try database.write { ctx in
            for mediaID in mediaIDs {
                try ctx.update(.media, id: mediaID, ["observation_id": nil, "finding_id": nil])
            }
        }
    }

    public func setCaption(mediaID: String, _ caption: String?) throws {
        try database.write { ctx in
            try ctx.update(.media, id: mediaID, ["caption": caption])
        }
    }

    /// Annotation is non-destructive: arrows and circles are re-renderable
    /// vector data, so an annotation made three weeks ago is still undoable and
    /// the original pixels are never touched.
    public func setAnnotation(mediaID: String, json: String?) throws {
        try database.write { ctx in
            try ctx.update(.media, id: mediaID, ["annotation_json": json])
        }
    }

    public func delete(mediaID: String) throws {
        try database.write { ctx in try ctx.softDelete(.media, id: mediaID) }
    }

    // MARK: Digest (idle-time)

    /// Photos still awaiting a content hash. Hashing runs on an idle queue and
    /// never on the capture path — a 4MB JPEG digest would blow the 350ms
    /// shutter budget on its own.
    public static func awaitingDigest(limit: Int = 20) -> @Sendable (Database) throws -> [MediaItem] {
        { db in
            try MediaItem.fetchAll(db, sql: """
                SELECT * FROM media
                WHERE sha256 IS NULL AND deleted_at IS NULL AND kind IN ('photo','video')
                ORDER BY captured_at
                LIMIT ?
                """, arguments: [limit])
        }
    }

    /// Record a digest, and soft-delete this row if an identical file is
    /// already attached to the same inspection — a re-imported photo should not
    /// appear twice in the report.
    public func recordDigest(mediaID: String, sha256: String) throws {
        try database.write { ctx in
            try ctx.update(.media, id: mediaID, ["sha256": sha256])

            let duplicate = try String.fetchOne(ctx.db, sql: """
                SELECT m2.id FROM media m1
                JOIN media m2
                  ON m2.sha256 = m1.sha256
                 AND m2.inspection_id IS m1.inspection_id
                 AND m2.id <> m1.id
                 AND m2.deleted_at IS NULL
                WHERE m1.id = ? AND m1.deleted_at IS NULL
                ORDER BY m2.captured_at
                LIMIT 1
                """, arguments: [mediaID])

            // Keep the earlier one; the later capture is the accidental repeat.
            if duplicate != nil {
                try ctx.softDelete(.media, id: mediaID)
            }
        }
    }
}
