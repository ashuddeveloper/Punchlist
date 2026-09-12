import Foundation
import GRDB

/// First launch.
///
/// §2.5: no account required to start. The app opens straight into a working
/// inspection with a real template and a real property, so the first thing a
/// prospective buyer sees is the product doing its job — not a signup wall, not
/// an onboarding carousel, and not an empty list asking them to configure
/// something before it will show them anything.
///
/// Account creation happens later, when they first sync or first export with a
/// logo.
public enum FirstRun {

    public struct Result: Sendable {
        public let orgID: String
        public let inspectorID: String
        public let templateID: String
        public let demoInspectionID: String
    }

    /// Idempotent: safe to call on every launch.
    public static func bootstrapIfNeeded(_ database: AppDatabase) throws -> Result {
        try database.write { ctx in
            if let orgID = try String.fetchOne(
                ctx.db, sql: "SELECT id FROM org WHERE deleted_at IS NULL ORDER BY created_at LIMIT 1")
            {
                let inspectorID = try String.fetchOne(
                    ctx.db,
                    sql: "SELECT id FROM inspector WHERE org_id = ? AND deleted_at IS NULL ORDER BY created_at LIMIT 1",
                    arguments: [orgID]) ?? ""
                let templateID = try ResidentialTemplate.install(orgID: orgID, into: ctx)
                let demoID = try String.fetchOne(
                    ctx.db,
                    sql: "SELECT id FROM inspection WHERE org_id = ? AND deleted_at IS NULL ORDER BY created_at LIMIT 1",
                    arguments: [orgID]) ?? ""
                return Result(
                    orgID: orgID, inspectorID: inspectorID, templateID: templateID,
                    demoInspectionID: demoID)
            }

            // A placeholder org, not a fake company. The name is what they will
            // see on their first report, so it has to read as "fill this in",
            // not as a brand someone might accidentally ship to a client.
            let orgID = try ctx.insert(.org, [
                "name": "My Inspection Company",
                "brand_color": "#1B4D3E",
                "report_theme": "standard",
                "archive_originals": false,
            ])

            let inspectorID = try ctx.insert(.inspector, [
                "org_id": orgID,
                "name": "Inspector",
            ])

            let templateID = try ResidentialTemplate.install(orgID: orgID, into: ctx)

            let snapshot = try TemplateSnapshotBuilder.build(templateID: templateID, db: ctx.db)
            let json = try CanonicalJSON.encode(snapshot)

            let propertyID = try ctx.insert(.property, [
                "org_id": orgID,
                "address_1": "1490 Alder Creek Road",
                "city": "Bellingham",
                "region": "WA",
                "postal_code": "98225",
                "year_built": 1978,
                "sq_ft": 2140,
            ])

            let inspectionID = try ctx.insert(.inspection, [
                "org_id": orgID,
                "property_id": propertyID,
                "inspector_id": inspectorID,
                "template_id": templateID,
                "template_snapshot_json": json,
                "template_version": snapshot.version,
                "template_snapshot_hash": CanonicalJSON.sha256Hex(json),
                "status": InspectionStatus.draft.rawValue,
                "scheduled_at": ctx.now,
                "started_at": ctx.now,
                "client_name": "Demo inspection",
                "resume_offset": 0.0,
                "search_dirty": true,
            ])

            try seedStarterComments(orgID: orgID, templateID: templateID, ctx: ctx)

            return Result(
                orgID: orgID, inspectorID: inspectorID, templateID: templateID,
                demoInspectionID: inspectionID)
        }
    }

    /// A small starter library so the canned-comment affordance is visible on
    /// day one rather than on day twenty.
    ///
    /// These start at `use_count` 0 deliberately: the ranking must reflect what
    /// *this* inspector actually uses, and pre-weighting our phrasing above
    /// theirs would make the feature feel wrong exactly when it should start
    /// feeling personal.
    private static func seedStarterComments(orgID: String, templateID: String, ctx: MutationContext) throws {
        let starters: [(severity: Severity, body: String, recommendation: String?)] = [
            (.safety,
             "Ground fault circuit interrupter protection is absent at one or more required locations.",
             "Have a licensed electrician install GFCI protection at all required receptacles."),
            (.safety,
             "The temperature and pressure relief valve discharge line terminates improperly.",
             "Have a licensed plumber extend the discharge line to within 6 inches of the floor."),
            (.repair,
             "Granule loss and cupping were observed across the field of the roof covering, consistent with a covering at or near the end of its service life.",
             "Budget for replacement and obtain an evaluation from a licensed roofing contractor."),
            (.repair,
             "Grading adjacent to the foundation is flat or slopes toward the structure.",
             "Regrade to provide a minimum fall of 6 inches over the first 10 feet."),
            (.monitor,
             "Minor settlement cracking was observed. No displacement or active movement was evident at the time of inspection.",
             "Monitor for change and seal to limit moisture entry."),
            (.info,
             "The unit was operating normally at the time of inspection.", nil),
        ]

        for starter in starters {
            try ctx.insert(.cannedComment, [
                "org_id": orgID,
                "item_id": nil,
                "severity": starter.severity.rawValue,
                "body": starter.body,
                "recommendation": starter.recommendation,
                "use_count": 0,
            ])
        }
    }
}
