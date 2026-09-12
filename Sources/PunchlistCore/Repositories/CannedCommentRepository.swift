import Foundation
import GRDB

/// Reusable phrasing — the single biggest time-saver in the product.
///
/// When an inspector tags an item "repair", they should see *their own* three
/// most-used comments for that item first. By inspection 20, most narrative is
/// one tap. This is the retention mechanic; everything else is table stakes.
public struct CannedCommentRepository: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) { self.database = database }

    /// SQL kept as named constants rather than assembled at call time.
    /// A query built by string concatenation cannot be asserted against
    /// `EXPLAIN QUERY PLAN` in CI, because the string CI checks is not provably
    /// the string that runs.
    ///
    /// Ordered to match the leading columns of `idx_canned_rank`, so the
    /// ranking comes out of the index with no sort step.
    static let itemSpecificSQL = """
        SELECT * FROM canned_comment
        WHERE org_id = ? AND item_id = ? AND severity = ? AND deleted_at IS NULL
        ORDER BY use_count DESC, last_used_at DESC, id
        LIMIT ?
        """

    static let globalSQL = """
        SELECT * FROM canned_comment
        WHERE org_id = ? AND item_id IS NULL AND severity = ? AND deleted_at IS NULL
        ORDER BY use_count DESC, last_used_at DESC, id
        LIMIT ?
        """

    /// Ranked suggestions for an item.
    ///
    /// Two queries, not one with an `ORDER BY (item_id IS NULL)`. That
    /// expression cannot be satisfied from an index, so a single query sorts
    /// its whole candidate set on every tap. Splitting it means both halves
    /// read straight out of `idx_canned_rank` — and it expresses the product
    /// rule more honestly anyway: *their own* comments for *this* item come
    /// first, and the general library only tops up what is left.
    ///
    /// Ranking is frequency first, recency second. "Worn shingles" is a better
    /// suggestion under Shingle Condition than a generic "monitor annually",
    /// even when the generic one has been used more often overall.
    public static func suggestions(
        orgID: String, itemID: String?, severity: Severity, limit: Int = 5
    ) -> @Sendable (Database) throws -> [CannedComment] {
        { db in
            var results: [CannedComment] = []
            if let itemID {
                results = try CannedComment.fetchAll(
                    db, sql: itemSpecificSQL,
                    arguments: [orgID, itemID, severity.rawValue, limit])
            }
            guard results.count < limit else { return results }

            let globals = try CannedComment.fetchAll(
                db, sql: globalSQL,
                arguments: [orgID, severity.rawValue, limit - results.count])
            results.append(contentsOf: globals)
            return results
        }
    }

    /// Save a narrative the inspector just wrote as a reusable comment.
    ///
    /// Offered rather than automatic: an inspector's phrasing is their
    /// professional voice and they are liable for it, so the app never quietly
    /// harvests their words into a library they did not ask for.
    @discardableResult
    public func create(
        orgID: String, itemID: String?, severity: Severity, body: String,
        recommendation: String? = nil
    ) throws -> String {
        try database.write { ctx in
            try ctx.insert(.cannedComment, [
                "org_id": orgID,
                "item_id": itemID,
                "severity": severity.rawValue,
                "body": body,
                "recommendation": recommendation,
                "use_count": 0,
            ])
        }
    }

    public func delete(id: String) throws {
        try database.write { ctx in try ctx.softDelete(.cannedComment, id: id) }
    }
}
