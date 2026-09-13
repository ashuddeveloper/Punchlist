import SwiftUI

// ============================================================================
// Spacing, rules, and touch targets.
// ============================================================================

enum Metrics {

    // MARK: Touch targets

    /// Minimum for anything tappable. Apple's guidance is 44pt; this is 56.
    ///
    /// The difference is gloves. A nitrile or leather glove spreads the
    /// capacitive contact patch and shifts its centroid, so a 44pt target that
    /// is comfortable barehanded becomes a coin toss. Every competitor in this
    /// category ships 44pt controls, and this single number is why inspectors
    /// will describe our app as "the one that works".
    static let tapTarget: CGFloat = 56

    /// For controls used repeatedly: the shutter, rating buttons, the section
    /// jumper. These are pressed hundreds of times per inspection.
    static let tapTargetRepeated: CGFloat = 64

    // MARK: Spacing

    static let spaceXS: CGFloat = 4
    static let spaceS: CGFloat = 8
    static let spaceM: CGFloat = 12
    static let spaceL: CGFloat = 16
    static let spaceXL: CGFloat = 24
    static let spaceXXL: CGFloat = 32

    /// Horizontal page margin.
    static let gutter: CGFloat = 16

    // MARK: Rules

    /// A true hairline on every scale factor. Structure in this app comes from
    /// rules, not from shadows — a soft grey drop shadow is invisible in direct
    /// sun and reads as generic everywhere else.
    static var hairline: CGFloat { 1 / UIScreen.main.scale }

    /// A heavier rule, for the boundary between sections.
    static let rule: CGFloat = 1

    // MARK: Radii

    /// Deliberately small. Field instruments have square corners and a 4pt
    /// radius reads as "machined"; a 16pt radius reads as a consumer card kit,
    /// which is the look the brief explicitly rules out.
    static let radius: CGFloat = 4
    static let radiusLarge: CGFloat = 6
}

// MARK: - Shared shapes

/// A full-width horizontal rule.
struct Hairline: View {
    var color: Color = .line
    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: Metrics.hairline)
            .accessibilityHidden(true)
    }
}

/// A resting surface for an input. A filled well with a hairline, not a
/// floating card with a shadow.
struct FieldWell<Content: View>: View {
    var isActive: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(Color.field)
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radius)
                    .strokeBorder(isActive ? Color.ink : Color.line, lineWidth: isActive ? 2 : Metrics.rule)
            )
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radius))
    }
}
