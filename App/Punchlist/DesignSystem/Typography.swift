import SwiftUI

// ============================================================================
// Type.
//
// One family, wide weight range, hierarchy from weight and size only. No
// tracked-out all-caps eyebrow over every heading — that device is the single
// clearest tell of a generic SaaS kit, and it costs legibility at exactly the
// sizes where this app needs it most.
//
// Everything scales with Dynamic Type. An inspector who has set their phone to
// Large because they are fifty-two and in a dim basement is the modal user, not
// an edge case, so every style is declared `relativeTo:` a text style rather
// than as a fixed point size.
// ============================================================================

extension Font {

    // MARK: Body — 17pt floor

    /// The floor. Read at arm's length in bad light; smaller is not a design
    /// choice we are allowed to make.
    static let bodyField = Font.system(.body, design: .default).weight(.regular)

    /// Emphasised body, for a finding's narrative.
    static let bodyFieldMedium = Font.system(.body, design: .default).weight(.medium)

    /// Metadata and secondary lines. Still 15pt minimum at default Dynamic
    /// Type — this is the smallest type in the product.
    static let caption = Font.system(.subheadline, design: .default).weight(.regular)

    // MARK: Headings

    /// Section titles in the checklist.
    static let sectionTitle = Font.system(.title3, design: .default).weight(.semibold)

    /// Screen titles.
    static let screenTitle = Font.system(.largeTitle, design: .default).weight(.bold)

    /// A checklist item's label. Medium rather than semibold: on a screen of
    /// sixty of these, semibold everywhere is the same as regular everywhere.
    static let itemLabel = Font.system(.body, design: .default).weight(.medium)

    // MARK: Figures

    /// Measurements, counts, progress, temperatures.
    ///
    /// Monospaced digits, not a monospaced face. Tabular figures stop a
    /// progress counter from shivering as it climbs 9 → 10 → 11, and keep a
    /// column of amperages aligned on the decimal. Using a full monospace font
    /// instead would make the numbers look like code.
    static let figure = Font.system(.body, design: .default)
        .weight(.medium)
        .monospacedDigit()

    static let figureLarge = Font.system(.title2, design: .default)
        .weight(.semibold)
        .monospacedDigit()

    static let figureSmall = Font.system(.subheadline, design: .default)
        .weight(.medium)
        .monospacedDigit()
}

extension Text {
    /// A label above a value. Sentence case at normal weight in `slate` — the
    /// hierarchy comes from colour and position, not from shouting.
    func fieldLabel() -> some View {
        self.font(.caption).foregroundStyle(Color.slate)
    }
}
