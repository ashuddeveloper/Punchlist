import Foundation
import GRDB

/// Gathers everything a report needs, in one read.
///
/// One transaction, not several: a report assembled from reads taken at
/// different moments could show a finding whose photo it does not show, or a
/// page count that does not match its own summary. A single snapshot read makes
/// that impossible rather than unlikely.
public struct ReportBuilder: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) { self.database = database }

    public func buildDocument(inspectionID: String) throws -> ReportDocument {
        let input = try loadInput(inspectionID: inspectionID)
        let theme = ReportTheme.named(input.org.reportTheme)
        return ReportLayout(theme: theme, input: input).build()
    }

    public func loadInput(inspectionID: String) throws -> ReportInput {
        try database.read { db in
            guard let inspection = try Inspection.fetchOne(
                db, sql: "SELECT * FROM inspection WHERE id = ? AND deleted_at IS NULL",
                arguments: [inspectionID])
            else { throw ReportError.inspectionNotFound(inspectionID) }

            guard let property = try Property.fetchOne(
                db, sql: "SELECT * FROM property WHERE id = ?", arguments: [inspection.propertyId]),
                  let org = try Org.fetchOne(
                    db, sql: "SELECT * FROM org WHERE id = ?", arguments: [inspection.orgId]),
                  let inspector = try Inspector.fetchOne(
                    db, sql: "SELECT * FROM inspector WHERE id = ?", arguments: [inspection.inspectorId])
            else { throw ReportError.incompleteRecords(inspectionID) }

            // The frozen snapshot, never the live template tables. This is the
            // line that makes a 2026 inspection still render as a 2026
            // inspection after the template has been edited twice.
            let snapshot = try inspection.snapshot()

            let answers = try ChecklistRepository.answers(inspectionID: inspectionID)(db)
            let findings = try ChecklistRepository.findings(inspectionID: inspectionID)(db)

            let allMedia = try MediaItem.fetchAll(db, sql: """
                SELECT * FROM media
                WHERE inspection_id = ? AND deleted_at IS NULL AND kind = 'photo'
                ORDER BY sort_order, captured_at
                """, arguments: [inspectionID])

            var mediaByObservation: [String: [MediaItem]] = [:]
            for item in allMedia {
                guard let observationID = item.observationId else { continue }
                mediaByObservation[observationID, default: []].append(item)
            }

            // The cover photo is the first one shot. Inspectors photograph the
            // front elevation first, essentially always, so this is right far
            // more often than any heuristic — and it is overridable later.
            let coverPhoto = allMedia.min { $0.capturedAt < $1.capturedAt }

            return ReportInput(
                inspection: inspection, property: property, org: org, inspector: inspector,
                snapshot: snapshot, answers: answers, findingsByObservation: findings,
                mediaByObservation: mediaByObservation, coverPhoto: coverPhoto)
        }
    }
}

public enum ReportError: Error, CustomStringConvertible {
    case inspectionNotFound(String)
    case incompleteRecords(String)

    public var description: String {
        switch self {
        case .inspectionNotFound(let id): return "No inspection with id \(id)"
        case .incompleteRecords(let id):
            return "Inspection \(id) is missing its property, org or inspector record"
        }
    }
}
