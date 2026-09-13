import Foundation

// ============================================================================
// Deterministic text measurement.
//
// The report's guarantee is that its layout is a pure function of stored data —
// the same inspection produces the same pages in 2027 as in 2026. That is only
// true if text measurement is deterministic, and measuring with CoreText would
// break it: system font metrics change across OS versions, and `PunchlistCore`
// must build on Linux CI anyway, where CoreText does not exist.
//
// The way out is to use the PDF base-14 fonts. Helvetica's advance widths are
// fixed by the Adobe AFM specification, have not changed since 1985, and are
// required to be present in every conforming PDF viewer. Embedding the width
// table here makes measurement exact rather than approximate, on every platform
// and every OS version, forever.
//
// This is also why line breaking happens *here* and not in the renderer. The IR
// carries explicit, pre-broken lines with their positions; the renderer draws
// what it is given and never re-wraps. Rendering therefore cannot disagree with
// layout, because it is not allowed an opinion.
// ============================================================================

public enum ReportFont: String, Codable, Sendable, CaseIterable {
    case helvetica = "Helvetica"
    case helveticaBold = "Helvetica-Bold"
    case helveticaOblique = "Helvetica-Oblique"

    /// Advance widths in 1/1000 em, indexed by ASCII code point.
    var widths: [Int] {
        switch self {
        case .helvetica, .helveticaOblique: return FontMetrics.helvetica
        case .helveticaBold: return FontMetrics.helveticaBold
        }
    }
}

public enum FontMetrics {

    /// Width of one character in 1/1000 em.
    ///
    /// Anything outside printable ASCII falls back to the width of "n". The
    /// report is English-language inspection prose; a character that is not in
    /// this table is rare enough that a one-glyph measurement error cannot
    /// cascade, and falling back to a mid-width letter keeps the error
    /// symmetric rather than systematically narrow.
    static func width(of scalar: Character, font: ReportFont) -> Int {
        guard let ascii = scalar.asciiValue, ascii >= 32, ascii <= 126 else {
            return font.widths[Int(Character("n").asciiValue!) - 32]
        }
        return font.widths[Int(ascii) - 32]
    }

    /// Text width in points at a given size.
    public static func width(of text: String, font: ReportFont, size: Points) -> Points {
        var total = 0
        for character in text { total += width(of: character, font: font) }
        // Integer arithmetic throughout: a Double here would reintroduce the
        // float-formatting nondeterminism the centipoint unit exists to avoid.
        return Points(centi: total * size.centi / 1000)
    }

    /// Break text into lines that fit `maxWidth`.
    ///
    /// Greedy, breaking on spaces, with a hard character-level break for a
    /// single word longer than the line — an unbroken 90-character serial
    /// number in a finding must not silently run off the page edge.
    public static func wrap(
        _ text: String, font: ReportFont, size: Points, maxWidth: Points
    ) -> [String] {
        guard maxWidth.centi > 0 else { return [text] }
        var lines: [String] = []

        for paragraph in text.components(separatedBy: "\n") {
            if paragraph.isEmpty {
                lines.append("")
                continue
            }
            var line = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: false) {
                let candidate = line.isEmpty ? String(word) : line + " " + word
                if width(of: candidate, font: font, size: size) <= maxWidth {
                    line = candidate
                    continue
                }
                if !line.isEmpty {
                    lines.append(line)
                    line = ""
                }
                // The word alone may still not fit — an unbroken 90-character
                // serial number in a finding must not run off the page edge.
                //
                // The scan stops at the FIRST character that does not fit and
                // takes everything after it as the remainder. Continuing the
                // scan would be a bug: a narrow character later in the word
                // (an "i" after a run of "W"s) would still pass the width test
                // and be appended to the chunk while the wider characters
                // before it had already gone to the remainder — silently
                // reordering the text.
                var remainder = Substring(word)
                while width(of: String(remainder), font: font, size: size) > maxWidth,
                      remainder.count > 1 {
                    var chunk = ""
                    var splitIndex = remainder.startIndex
                    for index in remainder.indices {
                        let next = chunk + String(remainder[index])
                        if width(of: next, font: font, size: size) > maxWidth { break }
                        chunk = next
                        splitIndex = remainder.index(after: index)
                    }
                    if chunk.isEmpty { break }
                    lines.append(chunk)
                    remainder = remainder[splitIndex...]
                }
                line = String(remainder)
            }
            lines.append(line)
        }
        return lines
    }

    /// Adobe AFM advance widths for Helvetica, ASCII 32-126.
    static let helvetica: [Int] = [
        278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,
        556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
        1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
        667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
        333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
        556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584,
    ]

    /// Adobe AFM advance widths for Helvetica-Bold, ASCII 32-126.
    static let helveticaBold: [Int] = [
        278, 333, 474, 556, 556, 889, 722, 238, 333, 333, 389, 584, 278, 333, 278, 278,
        556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 333, 333, 584, 584, 584, 611,
        975, 722, 722, 722, 722, 667, 611, 778, 722, 278, 556, 722, 611, 833, 722, 778,
        667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 333, 278, 333, 584, 556,
        333, 556, 611, 556, 611, 556, 333, 611, 611, 278, 278, 556, 278, 889, 611, 611,
        611, 611, 389, 556, 333, 611, 556, 778, 556, 556, 500, 389, 280, 389, 584,
    ]
}

/// A length in hundredths of a point.
///
/// Integer, not `Double`. The entire IR is integer arithmetic so that its
/// canonical JSON encoding is byte-stable — `0.1 + 0.2` formatting differently
/// across two Foundation versions would be enough to break the hash that the
/// immutability guarantee rests on. A hundredth of a point is ~3.5 microns,
/// which is four orders of magnitude finer than anything a printer resolves.
public struct Points: Codable, Sendable, Equatable, Comparable, AdditiveArithmetic {
    public var centi: Int

    public init(centi: Int) { self.centi = centi }
    public init(_ points: Int) { self.centi = points * 100 }

    public static let zero = Points(centi: 0)

    public var doubleValue: Double { Double(centi) / 100 }

    public static func < (lhs: Points, rhs: Points) -> Bool { lhs.centi < rhs.centi }
    public static func + (lhs: Points, rhs: Points) -> Points { Points(centi: lhs.centi + rhs.centi) }
    public static func - (lhs: Points, rhs: Points) -> Points { Points(centi: lhs.centi - rhs.centi) }
    public static func * (lhs: Points, rhs: Int) -> Points { Points(centi: lhs.centi * rhs) }
    public static func / (lhs: Points, rhs: Int) -> Points { Points(centi: lhs.centi / rhs) }

    /// Encoded as a bare integer rather than an object, so the IR's JSON stays
    /// compact — a 40-page report has tens of thousands of these.
    public init(from decoder: any Decoder) throws {
        centi = try decoder.singleValueContainer().decode(Int.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(centi)
    }
}
