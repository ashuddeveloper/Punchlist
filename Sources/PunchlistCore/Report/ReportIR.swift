import Foundation

// ============================================================================
// The report's layout intermediate representation.
//
// A `ReportDocument` is a complete, resolved description of every page: every
// line of text at its exact position in its exact font, every rule, every photo
// frame. It contains no styles to be resolved later and no text to be wrapped
// later. The renderer draws it and makes no decisions.
//
// This split is what replaces the brief's "byte-identical PDF forever", which
// is not achievable against an OS renderer — PDFKit embeds a creation timestamp
// and a document id, and glyph rasterisation changes across OS versions. What
// *is* achievable, and is what a liability dispute actually needs, is this:
// the layout is a pure function of stored data, and `CanonicalJSON.hash` of
// this document proves it. That claim survives an iOS update; byte equality
// would not.
// ============================================================================

public struct ReportDocument: Codable, Sendable, Equatable {
    public var pageSize: Size
    public var pages: [ReportPage]
    /// Frozen inputs, so the IR is self-describing when read back years later.
    public var metadata: ReportMetadata

    public init(pageSize: Size, pages: [ReportPage], metadata: ReportMetadata) {
        self.pageSize = pageSize
        self.pages = pages
        self.metadata = metadata
    }

    /// The stability guarantee, made checkable.
    public func layoutHash() throws -> String {
        try CanonicalJSON.hash(self)
    }
}

public struct ReportMetadata: Codable, Sendable, Equatable {
    public var inspectionID: String
    public var templateSnapshotHash: String
    public var themeName: String
    /// The layout engine's own version. Bumping it is a deliberate declaration
    /// that output may change — the one legitimate way for a report to differ
    /// from its earlier self, and it is recorded in the document rather than
    /// inferred.
    public var engineVersion: Int
    public var pageCount: Int

    public init(
        inspectionID: String, templateSnapshotHash: String, themeName: String,
        engineVersion: Int, pageCount: Int
    ) {
        self.inspectionID = inspectionID
        self.templateSnapshotHash = templateSnapshotHash
        self.themeName = themeName
        self.engineVersion = engineVersion
        self.pageCount = pageCount
    }
}

public struct Size: Codable, Sendable, Equatable {
    public var width: Points
    public var height: Points
    public init(width: Points, height: Points) {
        self.width = width
        self.height = height
    }

    /// US Letter. The market is North American home and commercial inspection;
    /// A4 is a theme-level choice, not a default.
    public static let letter = Size(width: Points(612), height: Points(792))
    public static let a4 = Size(width: Points(595), height: Points(842))
}

public struct Rect: Codable, Sendable, Equatable {
    public var x: Points
    public var y: Points
    public var width: Points
    public var height: Points

    public init(x: Points, y: Points, width: Points, height: Points) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxY: Points { y + height }
    public var maxX: Points { x + width }
}

/// RGB, 0-255 per channel. Stored as integers for the same determinism reason
/// as `Points`.
public struct RGB: Codable, Sendable, Equatable {
    public var r: Int
    public var g: Int
    public var b: Int

    public init(r: Int, g: Int, b: Int) {
        self.r = r
        self.g = g
        self.b = b
    }

    public init(hex: Int) {
        self.init(r: (hex >> 16) & 0xFF, g: (hex >> 8) & 0xFF, b: hex & 0xFF)
    }

    public static let ink = RGB(hex: 0x14181A)
    public static let slate = RGB(hex: 0x5A6570)
    public static let line = RGB(hex: 0xD2D5CE)
    public static let paper = RGB(hex: 0xFBFAF7)
    public static let white = RGB(hex: 0xFFFFFF)
}

extension Severity {
    /// The print palette. Same hues as on screen — an inspector comparing the
    /// phone to the PDF must not see two different reds.
    public var printColor: RGB {
        switch self {
        case .info: return RGB(hex: 0x3E6B8A)
        case .monitor: return RGB(hex: 0xB07A12)
        case .repair: return RGB(hex: 0xC4541F)
        case .safety: return RGB(hex: 0xA31D1D)
        }
    }

    /// Severity is never colour alone (§9). In print this matters more than on
    /// screen: reports get photocopied in black and white, and a grayscale
    /// safety marker must still be distinguishable from an info one.
    public var printMark: PrintMark {
        switch self {
        case .info: return .circle
        case .monitor: return .triangle
        case .repair: return .diamond
        case .safety: return .octagon
        }
    }
}

public enum PrintMark: String, Codable, Sendable {
    case circle, triangle, diamond, octagon
}

public struct ReportPage: Codable, Sendable, Equatable {
    public var elements: [ReportElement]
    public init(elements: [ReportElement]) { self.elements = elements }
}

/// One drawable thing.
///
/// A flat enum rather than a tree: the layout engine has already resolved every
/// position into page space, so nesting would carry no information and would
/// give the renderer a coordinate transform to get wrong.
public enum ReportElement: Codable, Sendable, Equatable {
    /// A single pre-wrapped line. Never a paragraph — wrapping happened in the
    /// layout engine, where it is deterministic.
    case text(TextRun)
    case rule(Rule)
    case box(Box)
    case mark(Mark)
    case photo(PhotoPlacement)

    public struct TextRun: Codable, Sendable, Equatable {
        public var string: String
        public var origin: Rect
        public var font: ReportFont
        public var size: Points
        public var color: RGB

        public init(string: String, origin: Rect, font: ReportFont, size: Points, color: RGB) {
            self.string = string
            self.origin = origin
            self.font = font
            self.size = size
            self.color = color
        }
    }

    public struct Rule: Codable, Sendable, Equatable {
        public var frame: Rect
        public var color: RGB
        public init(frame: Rect, color: RGB) {
            self.frame = frame
            self.color = color
        }
    }

    public struct Box: Codable, Sendable, Equatable {
        public var frame: Rect
        public var fill: RGB?
        public var stroke: RGB?
        public var strokeWidth: Points

        public init(frame: Rect, fill: RGB?, stroke: RGB? = nil, strokeWidth: Points = Points(centi: 50)) {
            self.frame = frame
            self.fill = fill
            self.stroke = stroke
            self.strokeWidth = strokeWidth
        }
    }

    public struct Mark: Codable, Sendable, Equatable {
        public var frame: Rect
        public var shape: PrintMark
        public var color: RGB
        public init(frame: Rect, shape: PrintMark, color: RGB) {
            self.frame = frame
            self.shape = shape
            self.color = color
        }
    }

    /// A photo's *frame*, not its pixels. The IR references media by id and
    /// path; the renderer loads and releases one image at a time, which is what
    /// keeps a 150-photo report inside the memory budget.
    public struct PhotoPlacement: Codable, Sendable, Equatable {
        public var mediaID: String
        public var relativePath: String
        public var frame: Rect
        /// Set when the source dimensions are known, so the renderer can fit
        /// without decoding the image first to find out.
        public var sourceWidth: Int?
        public var sourceHeight: Int?
        public var caption: String?

        public init(
            mediaID: String, relativePath: String, frame: Rect,
            sourceWidth: Int?, sourceHeight: Int?, caption: String?
        ) {
            self.mediaID = mediaID
            self.relativePath = relativePath
            self.frame = frame
            self.sourceWidth = sourceWidth
            self.sourceHeight = sourceHeight
            self.caption = caption
        }
    }
}
