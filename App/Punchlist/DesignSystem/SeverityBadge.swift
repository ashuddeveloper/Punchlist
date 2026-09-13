import PunchlistCore
import SwiftUI

// ============================================================================
// Severity, rendered.
//
// Colour AND shape, always, never colour alone. Roughly one man in twelve has a
// red-green colour vision deficiency, and this is a trade where nearly all the
// users are men; encoding "safety" as red-only would make the most important
// marker in the product invisible to a meaningful share of the people paying
// for it. It also survives a photocopied report and a phone in sunlight.
// ============================================================================

/// The marker used in lists and on checklist rows.
struct SeverityBadge: View {
    let severity: Severity
    var showsLabel: Bool = false

    var body: some View {
        HStack(spacing: Metrics.spaceS) {
            SeverityGlyph(severity: severity)
            if showsLabel {
                Text(severity.label)
                    .font(.figureSmall)
                    .foregroundStyle(severity.color)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(severity.label)
    }
}

/// The shape alone, for dense rows where a label will not fit.
struct SeverityGlyph: View {
    let severity: Severity
    var size: CGFloat = 14

    var body: some View {
        Image(systemName: severity.glyph)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(severity.color)
            .accessibilityHidden(true)
    }
}

/// A severity picker. Four large targets rather than a segmented control,
/// which is 32pt tall and unusable in gloves.
struct SeverityPicker: View {
    @Binding var selection: Severity?

    var body: some View {
        HStack(spacing: Metrics.spaceS) {
            ForEach(Severity.allCases, id: \.self) { severity in
                Button {
                    // Tapping the current severity clears it. A finding marked
                    // by accident must be as easy to unmark as to mark.
                    selection = (selection == severity) ? nil : severity
                } label: {
                    VStack(spacing: Metrics.spaceXS) {
                        SeverityGlyph(severity: severity, size: 18)
                        Text(severity.label)
                            .font(.figureSmall)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: Metrics.tapTargetRepeated)
                    .background(selection == severity ? severity.wash : Color.field)
                    .overlay(
                        RoundedRectangle(cornerRadius: Metrics.radius)
                            .strokeBorder(
                                selection == severity ? severity.color : Color.line,
                                lineWidth: selection == severity ? 2 : Metrics.rule)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.radius))
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == severity ? severity.color : Color.slate)
                .accessibilityLabel(severity.label)
                .accessibilityAddTraits(selection == severity ? [.isSelected] : [])
            }
        }
    }
}
