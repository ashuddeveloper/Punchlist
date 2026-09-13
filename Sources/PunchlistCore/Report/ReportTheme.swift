import Foundation

// ============================================================================
// Three themes. Not a layout designer.
//
// §12 rules out a custom PDF layout designer, and it is right to: it is a
// bottomless feature that produces worse-looking reports than three good fixed
// ones, because inspectors are not typographers and the bad output still
// carries our name. So: three, each a real editorial position rather than a
// colour swap.
// ============================================================================

public struct ReportTheme: Sendable, Equatable {
    public var name: String
    public var pageSize: Size
    public var margin: Points

    public var titleSize: Points
    public var headingSize: Points
    public var bodySize: Points
    public var captionSize: Points

    /// Multiplied by font size to get line height. 138% is the readable range
    /// for body text at these measures; tighter looks cramped in a document
    /// people read on paper.
    public var lineHeightPercent: Int

    /// Photos per row in the detail sections.
    public var photosPerRow: Int
    /// Whether each finding gets its own block of vertical space, or findings
    /// are run together to save pages.
    public var findingsAreBlocks: Bool

    public static let standard = ReportTheme(
        name: "standard",
        pageSize: .letter,
        margin: Points(54),
        titleSize: Points(28),
        headingSize: Points(15),
        bodySize: Points(11),
        captionSize: Points(8),
        lineHeightPercent: 138,
        photosPerRow: 2,
        findingsAreBlocks: true)

    /// Fewer pages. For inspectors who print and mail, where page count is
    /// literal postage.
    public static let compact = ReportTheme(
        name: "compact",
        pageSize: .letter,
        margin: Points(42),
        titleSize: Points(24),
        headingSize: Points(13),
        bodySize: Points(10),
        captionSize: Points(7),
        lineHeightPercent: 126,
        photosPerRow: 3,
        findingsAreBlocks: false)

    /// Larger type, bigger photos, more air. For commercial property condition
    /// assessments, which get read by lenders rather than homeowners and where
    /// looking substantial is part of the job.
    public static let narrative = ReportTheme(
        name: "narrative",
        pageSize: .letter,
        margin: Points(63),
        titleSize: Points(32),
        headingSize: Points(17),
        bodySize: Points(12),
        captionSize: Points(9),
        lineHeightPercent: 150,
        photosPerRow: 2,
        findingsAreBlocks: true)

    public static func named(_ name: String) -> ReportTheme {
        switch name {
        case "compact": return .compact
        case "narrative": return .narrative
        default: return .standard
        }
    }

    // MARK: Derived

    public var contentWidth: Points { pageSize.width - margin - margin }
    public var contentHeight: Points { pageSize.height - margin - margin }

    public func lineHeight(for size: Points) -> Points {
        Points(centi: size.centi * lineHeightPercent / 100)
    }
}
