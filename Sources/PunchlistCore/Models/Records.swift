import Foundation
import GRDB

/// GRDB records for the hot path.
///
/// All of these are plain value types with snake_case column mapping. They are
/// read models: writes go through `MutationContext`, never through
/// `record.save(db)`, because every write has to stamp an HLC and append to the
/// outbox in the same transaction and a bare `save` would silently skip both.
public protocol SyncedRecord: Codable, FetchableRecord, TableRecord, Identifiable, Sendable {
    var id: String { get }
    var hlc: String { get }
    var createdAt: Int64 { get }
    var updatedAt: Int64 { get }
    var deletedAt: Int64? { get }
}

extension SyncedRecord {
    public static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy {
        .convertFromSnakeCase
    }
    public var isDeleted: Bool { deletedAt != nil }
}

// MARK: - Identity

public struct Org: SyncedRecord {
    public static let databaseTableName = "org"
    public var id: String
    public var name: String
    public var logoMediaId: String?
    public var licenseNo: String?
    public var address: String?
    public var phone: String?
    public var email: String?
    public var brandColor: String
    public var reportTheme: String
    public var archiveOriginals: Bool
    public var hlc: String
    public var createdAt: Int64
    public var updatedAt: Int64
    public var deletedAt: Int64?
}

public struct Inspector: SyncedRecord {
    public static let databaseTableName = "inspector"
    public var id: String
    public var orgId: String
    public var name: String
    public var email: String?
    public var licenseNo: String?
    public var signatureMediaId: String?
    public var hlc: String
    public var createdAt: Int64
    public var updatedAt: Int64
    public var deletedAt: Int64?
}

public struct Property: SyncedRecord {
    public static let databaseTableName = "property"
    public var id: String
    public var orgId: String
    public var address1: String
    public var address2: String?
    public var city: String?
    public var region: String?
    public var postalCode: String?
    public var lat: Double?
    public var lon: Double?
    public var yearBuilt: Int?
    public var sqFt: Int?
    public var hlc: String
    public var createdAt: Int64
    public var updatedAt: Int64
    public var deletedAt: Int64?

    /// One line, the way an inspector reads it off a job sheet.
    public var singleLine: String {
        [address1, address2, [city, region].compactMap { $0 }.joined(separator: ", "), postalCode]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

// MARK: - Inspection

public struct Inspection: SyncedRecord {
    public static let databaseTableName = "inspection"
    public var id: String
    public var orgId: String
    public var propertyId: String
    public var inspectorId: String
    public var templateId: String
    public var templateSnapshotJson: String
    public var templateVersion: Int
    public var templateSnapshotHash: String
    public var status: InspectionStatus
    public var scheduledAt: Int64?
    public var startedAt: Int64?
    public var completedAt: Int64?
    public var clientName: String?
    public var clientEmail: String?
    public var weather: String?
    public var temperatureF: Int?
    public var occupancy: String?
    public var resumeSectionId: String?
    public var resumeOffset: Double
    public var searchDirty: Bool
    public var hlc: String
    public var createdAt: Int64
    public var updatedAt: Int64
    public var deletedAt: Int64?

    /// Decodes the frozen template. The report and the checklist both render
    /// from this and never from the live template tables — which is what makes
    /// editing a template unable to change an inspection already performed.
    public func snapshot() throws -> TemplateSnapshot {
        try CanonicalJSON.decode(TemplateSnapshot.self, from: templateSnapshotJson)
    }
}

/// The value recorded for one checklist item. Sparse by design: an untouched
/// checklist costs zero rows.
public struct Observation: SyncedRecord {
    public static let databaseTableName = "observation"
    public var id: String
    public var inspectionId: String
    public var itemId: String
    public var sectionId: String
    public var valueText: String?
    public var valueNumber: Double?
    public var valueBool: Bool?
    /// Rolled up from this observation's findings on every write, so the
    /// checklist can colour a row without a correlated subquery per cell.
    public var severity: Severity?
    public var locationNote: String?
    public var hlc: String
    public var createdAt: Int64
    public var updatedAt: Int64
    public var deletedAt: Int64?

    /// Multiselect values are stored as a tab-joined string in `value_text`
    /// rather than JSON: the report renders them as a list and nothing ever
    /// queries inside them, so JSON would buy nothing and cost a parse on every
    /// row of a 200-item checklist.
    public var selectedOptions: [String] {
        guard let valueText, !valueText.isEmpty else { return [] }
        return valueText.components(separatedBy: "\t")
    }
}

/// A single defect. See the schema comment: one checklist item routinely
/// carries several independent findings with different severities, locations
/// and photo sets.
public struct Finding: SyncedRecord {
    public static let databaseTableName = "finding"
    public var id: String
    public var inspectionId: String
    public var observationId: String
    public var severity: Severity
    public var narrative: String
    public var recommendation: String?
    public var locationNote: String?
    public var cannedCommentId: String?
    public var sortOrder: Int
    public var hlc: String
    public var createdAt: Int64
    public var updatedAt: Int64
    public var deletedAt: Int64?
}

public struct MediaItem: SyncedRecord {
    public static let databaseTableName = "media"
    public var id: String
    public var orgId: String
    public var inspectionId: String?
    public var observationId: String?
    public var findingId: String?
    public var kind: MediaKind
    public var localPath: String
    public var thumbPath: String?
    public var originalPath: String?
    public var remoteKey: String?
    public var uploadState: UploadState
    public var uploadAttempts: Int
    public var bytes: Int64?
    public var width: Int?
    public var height: Int?
    public var durationMs: Int?
    public var transcript: String?
    public var capturedAt: Int64
    public var lat: Double?
    public var lon: Double?
    public var annotationJson: String?
    public var caption: String?
    public var sortOrder: Int
    public var sha256: String?
    public var hlc: String
    public var createdAt: Int64
    public var updatedAt: Int64
    public var deletedAt: Int64?

    /// A photo that has been shot but not yet filed against an item. The tray
    /// (§10.4) is exactly this predicate.
    public var isUnfiled: Bool { observationId == nil && findingId == nil }
}

public struct CannedComment: SyncedRecord {
    public static let databaseTableName = "canned_comment"
    public var id: String
    public var orgId: String
    public var itemId: String?
    public var severity: Severity
    public var body: String
    public var recommendation: String?
    public var useCount: Int
    public var lastUsedAt: Int64?
    public var hlc: String
    public var createdAt: Int64
    public var updatedAt: Int64
    public var deletedAt: Int64?
}

// MARK: - Sync plumbing

public struct OutboxEntry: Codable, FetchableRecord, TableRecord, Sendable {
    public static let databaseTableName = "outbox"
    public static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy {
        .convertFromSnakeCase
    }
    public var seq: Int64
    public var tableName: String
    public var rowId: String
    public var op: String
    public var payloadJson: String
    public var hlc: String
    public var createdAt: Int64
    public var attempts: Int
    public var lastError: String?
}
