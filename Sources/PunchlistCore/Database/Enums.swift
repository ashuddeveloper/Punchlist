import Foundation
import GRDB

/// Severity is the only saturated colour in the product (§9). It is also the
/// spine of the report: the summary page clients actually read is nothing but
/// safety and repair findings, in this order.
public enum Severity: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case info
    case monitor
    case repair
    case safety

    /// Descending urgency. Drives the summary page and the roll-up onto an
    /// observation, so it is defined once here rather than in a SQL CASE.
    public var rank: Int {
        switch self {
        case .safety: return 3
        case .repair: return 2
        case .monitor: return 1
        case .info: return 0
        }
    }

    public static func mostSevere(_ values: [Severity]) -> Severity? {
        values.max { $0.rank < $1.rank }
    }

    /// Shape as well as colour — §9 requires severity never be encoded by
    /// colour alone, because a meaningful share of inspectors are colour-blind
    /// and every one of them reads this in direct sun.
    public var glyph: String {
        switch self {
        case .info: return "circle"
        case .monitor: return "triangle"
        case .repair: return "diamond"
        case .safety: return "octagon.fill"
        }
    }

    public var label: String {
        switch self {
        case .info: return "Information"
        case .monitor: return "Monitor"
        case .repair: return "Repair"
        case .safety: return "Safety"
        }
    }
}

public enum InspectionStatus: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case draft
    case complete
    case delivered
}

public enum InputType: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case rating
    case bool
    case select
    case multiselect
    case text
    case number
    case photoOnly = "photo_only"
    case signature
}

public enum MediaKind: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case photo
    case video
    case audio
    case signature
    case logo
}

public enum UploadState: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case pending
    case uploading
    case done
    case failed
}

public enum Discipline: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case home
    case fire
    case commercial
}
