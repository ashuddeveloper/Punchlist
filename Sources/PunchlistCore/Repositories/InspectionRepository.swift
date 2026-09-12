import Foundation
import GRDB

/// Creating and listing inspections.
public struct InspectionRepository: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) { self.database = database }

    // MARK: Create

    /// Create an inspection, freezing the template into it.
    ///
    /// Budget: tap "new inspection" to first checklist item is 400ms (§8). That
    /// is why the snapshot is built and hashed here, once, rather than being
    /// recomputed whenever the checklist is opened — and why the whole thing is
    /// one transaction rather than a property insert followed by an inspection
    /// insert that could be interrupted between them.
    public func create(
        orgID: String,
        inspectorID: String,
        templateID: String,
        property: NewProperty,
        clientName: String? = nil,
        clientEmail: String? = nil,
        scheduledAt: Int64? = nil
    ) throws -> String {
        try database.write { ctx in
            let snapshot = try TemplateSnapshotBuilder.build(templateID: templateID, db: ctx.db)
            let json = try CanonicalJSON.encode(snapshot)
            let hash = CanonicalJSON.sha256Hex(json)

            let propertyID = try ctx.insert(.property, [
                "org_id": orgID,
                "address_1": property.address1,
                "address_2": property.address2,
                "city": property.city,
                "region": property.region,
                "postal_code": property.postalCode,
                "lat": property.lat,
                "lon": property.lon,
                "year_built": property.yearBuilt,
                "sq_ft": property.sqFt,
            ])

            return try ctx.insert(.inspection, [
                "org_id": orgID,
                "property_id": propertyID,
                "inspector_id": inspectorID,
                "template_id": templateID,
                "template_snapshot_json": json,
                "template_version": snapshot.version,
                "template_snapshot_hash": hash,
                "status": InspectionStatus.draft.rawValue,
                "scheduled_at": scheduledAt,
                "started_at": ctx.now,
                "client_name": clientName,
                "client_email": clientEmail,
                "resume_offset": 0.0,
                "search_dirty": true,
            ])
        }
    }

    // MARK: Read

    /// The home screen. Ordered to match `idx_inspection_recent` exactly so the
    /// planner can satisfy the ORDER BY from the index instead of sorting.
    public static func recent(orgID: String, status: InspectionStatus?, limit: Int = 100)
        -> (Database) throws -> [Inspection]
    {
        { db in
            if let status {
                return try Inspection.fetchAll(db, sql: """
                    SELECT * FROM inspection
                    WHERE org_id = ? AND status = ? AND deleted_at IS NULL
                    ORDER BY scheduled_at DESC
                    LIMIT ?
                    """, arguments: [orgID, status.rawValue, limit])
            }
            return try Inspection.fetchAll(db, sql: """
                SELECT * FROM inspection
                WHERE org_id = ? AND deleted_at IS NULL
                ORDER BY scheduled_at DESC
                LIMIT ?
                """, arguments: [orgID, limit])
        }
    }

    public static func find(id: String) -> (Database) throws -> Inspection? {
        { db in
            try Inspection.fetchOne(
                db, sql: "SELECT * FROM inspection WHERE id = ? AND deleted_at IS NULL",
                arguments: [id])
        }
    }

    // MARK: Update

    /// Persist scroll position so reopening returns exactly where they left off
    /// (§10.8). Durable, not in-memory: the whole point is surviving a
    /// force-quit, and a view model dies with the process.
    public func saveResumePoint(inspectionID: String, sectionID: String?, offset: Double) throws {
        try database.write { ctx in
            try ctx.update(.inspection, id: inspectionID, [
                "resume_section_id": sectionID,
                "resume_offset": offset,
            ])
        }
    }

    public func setStatus(inspectionID: String, _ status: InspectionStatus) throws {
        try database.write { ctx in
            var patch: [String: (any DatabaseValueConvertible)?] = ["status": status.rawValue]
            if status == .complete { patch["completed_at"] = ctx.now }
            try ctx.update(.inspection, id: inspectionID, patch)
        }
    }

    public func updateDetails(
        inspectionID: String,
        clientName: String? = nil,
        clientEmail: String? = nil,
        weather: String? = nil,
        temperatureF: Int? = nil,
        occupancy: String? = nil
    ) throws {
        try database.write { ctx in
            var patch: [String: (any DatabaseValueConvertible)?] = [:]
            if let clientName { patch["client_name"] = clientName }
            if let clientEmail { patch["client_email"] = clientEmail }
            if let weather { patch["weather"] = weather }
            if let temperatureF { patch["temperature_f"] = temperatureF }
            if let occupancy { patch["occupancy"] = occupancy }
            guard !patch.isEmpty else { return }
            try ctx.update(.inspection, id: inspectionID, patch)
        }
    }
}

public struct NewProperty: Sendable {
    public var address1: String
    public var address2: String?
    public var city: String?
    public var region: String?
    public var postalCode: String?
    public var lat: Double?
    public var lon: Double?
    public var yearBuilt: Int?
    public var sqFt: Int?

    public init(
        address1: String, address2: String? = nil, city: String? = nil, region: String? = nil,
        postalCode: String? = nil, lat: Double? = nil, lon: Double? = nil,
        yearBuilt: Int? = nil, sqFt: Int? = nil
    ) {
        self.address1 = address1
        self.address2 = address2
        self.city = city
        self.region = region
        self.postalCode = postalCode
        self.lat = lat
        self.lon = lon
        self.yearBuilt = yearBuilt
        self.sqFt = sqFt
    }
}
