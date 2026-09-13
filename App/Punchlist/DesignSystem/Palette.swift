import PunchlistCore
import SwiftUI

// ============================================================================
// Colour.
//
// The rule that generates everything here: **if a screen has colour on it,
// that colour means something.** Severity is the only saturated ink in the
// product. Chrome, structure, labels, icons and controls are all neutral, so
// that a single repair-orange marker in a list of sixty rows is impossible to
// miss in direct sunlight through a scratched screen protector.
//
// This is why there is no accent/brand colour for buttons. A blue "Done" would
// compete with the only colour that carries information. The org's brand colour
// exists, but it is confined to the PDF cover page where it identifies the
// firm and nothing is being triaged.
// ============================================================================

extension Color {

    // MARK: Neutrals

    /// Primary text. Near-black with a cool cast — pure #000 on paper-white
    /// vibrates under a bright sky, and reads as cheap in print.
    static let ink = Color(light: 0x14181A, dark: 0xF2F3F1)

    /// Secondary text and metadata. Passes 4.5:1 on `paper`; anything lighter
    /// would not, and this app is read at arm's length by people who are not
    /// all twenty-five.
    static let slate = Color(light: 0x5A6570, dark: 0x9AA3AC)

    /// App background. Warm off-white, not #FFF: a pure white field is the
    /// brightest thing in a dim crawlspace and wrecks the reader's night vision
    /// before they look back at the actual wall.
    static let paper = Color(light: 0xFBFAF7, dark: 0x121415)

    /// Input wells and resting surfaces.
    static let field = Color(light: 0xEDEEEA, dark: 0x1E2123)

    /// Hairlines. Structure comes from rules, not from shadows — a drop shadow
    /// is invisible in sunlight and reads as generic everywhere else.
    static let line = Color(light: 0xD2D5CE, dark: 0x2F3335)

    // MARK: Severity — the only saturated colour in the product

    static let severityInfo = Color(light: 0x3E6B8A, dark: 0x6FA3C4)
    static let severityMonitor = Color(light: 0xB07A12, dark: 0xD9A43C)
    static let severityRepair = Color(light: 0xC4541F, dark: 0xE07C46)
    static let severitySafety = Color(light: 0xA31D1D, dark: 0xE05252)

    /// Dark-mode variants are lightened rather than reused. The same #A31D1D on
    /// a near-black ground drops below 4.5:1 and stops reading as urgent, which
    /// defeats the entire point of having exactly one urgent colour.
    init(light: UInt32, dark: UInt32) {
        self.init(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension Severity {
    var color: Color {
        switch self {
        case .info: return .severityInfo
        case .monitor: return .severityMonitor
        case .repair: return .severityRepair
        case .safety: return .severitySafety
        }
    }

    /// The tint behind a severity marker. Kept very light so the marker itself
    /// stays the most saturated thing on the row.
    var wash: Color { color.opacity(0.10) }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}
