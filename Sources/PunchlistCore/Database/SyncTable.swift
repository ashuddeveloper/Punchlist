import Foundation

/// Every table the mutation layer is allowed to write.
///
/// This exists so that no table name in the codebase is ever a `String` that
/// came from somewhere else. Table and column names cannot be bound as SQL
/// parameters, so they get interpolated — and the only safe way to interpolate
/// is from a closed set that the compiler checks.
public enum SyncTable: String, CaseIterable, Sendable {
    case org
    case inspector
    case template
    case templateSection = "template_section"
    case templateItem = "template_item"
    case cannedComment = "canned_comment"
    case property
    case inspection
    case observation
    case finding
    case media

    /// Columns the mutation layer manages itself. A caller that tries to set
    /// one of these by hand is doing something wrong.
    public static let managedColumns: Set<String> = ["hlc", "updated_at", "created_at", "deleted_at"]

    /// Columns that exist on every synced table.
    public static let commonColumns: Set<String> = ["id", "hlc", "created_at", "updated_at", "deleted_at"]
}

public enum OutboxOp: String, Sendable {
    case upsert
    case delete
}
