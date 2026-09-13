import Foundation

// ============================================================================
// The layout engine.
//
// Pure. Takes frozen data, returns a resolved `ReportDocument`. No I/O, no
// Apple frameworks, no clock, no randomness — so it runs identically on a
// phone, on a Linux CI box, and in 2029.
//
// Document order is deliberate and is the single most commercially important
// decision in the report:
//
//   1. Cover
//   2. Summary of safety and repair findings
//   3. Section-by-section detail
//
// The summary is second because it is the page clients actually read. An
// inspector who buries three safety findings on page 31 has technically
// reported them and practically has not, and it is their licence at stake.
// ============================================================================

public enum ReportEngine {
    /// Bump only when output is *intended* to change. Recorded in the document.
    public static let version = 1
}

public struct ReportInput: Sendable {
    public var inspection: Inspection
    public var property: Property
    public var org: Org
    public var inspector: Inspector
    public var snapshot: TemplateSnapshot
    public var answers: [String: Observation]
    public var findingsByObservation: [String: [Finding]]
    public var mediaByObservation: [String: [MediaItem]]
    public var coverPhoto: MediaItem?

    public init(
        inspection: Inspection, property: Property, org: Org, inspector: Inspector,
        snapshot: TemplateSnapshot, answers: [String: Observation],
        findingsByObservation: [String: [Finding]], mediaByObservation: [String: [MediaItem]],
        coverPhoto: MediaItem?
    ) {
        self.inspection = inspection
        self.property = property
        self.org = org
        self.inspector = inspector
        self.snapshot = snapshot
        self.answers = answers
        self.findingsByObservation = findingsByObservation
        self.mediaByObservation = mediaByObservation
        self.coverPhoto = coverPhoto
    }
}

public struct ReportLayout {
    let theme: ReportTheme
    let input: ReportInput

    public init(theme: ReportTheme, input: ReportInput) {
        self.theme = theme
        self.input = input
    }

    public func build() -> ReportDocument {
        var pages: [ReportPage] = []
        pages.append(coverPage())

        var cursor = PageCursor(theme: theme)
        let numbering = numberFindings()

        layoutSummary(into: &cursor, numbering: numbering)
        layoutSections(into: &cursor, numbering: numbering)
        pages.append(contentsOf: cursor.finish())

        // Page numbers are added last because until the document is fully
        // paginated we do not know the denominator, and "Page 4 of 40" is what
        // tells a client the report is complete.
        let numbered = pages.enumerated().map { index, page in
            index == 0 ? page : withPageNumber(page, number: index + 1, total: pages.count)
        }

        return ReportDocument(
            pageSize: theme.pageSize,
            pages: numbered,
            metadata: ReportMetadata(
                inspectionID: input.inspection.id,
                templateSnapshotHash: input.inspection.templateSnapshotHash,
                themeName: theme.name,
                engineVersion: ReportEngine.version,
                pageCount: pages.count))
    }

    // MARK: Finding numbering

    /// Every finding gets a stable number, assigned in document order, so the
    /// summary and the detail sections cross-reference each other. "See finding
    /// 12" has to mean the same thing on both pages.
    struct Numbering: Sendable {
        var numberByFindingID: [String: Int] = [:]
        var ordered: [Finding] = []
    }

    func numberFindings() -> Numbering {
        var numbering = Numbering()
        var counter = 1
        for section in input.snapshot.sections {
            for item in section.items {
                guard let observationID = input.answers[item.id]?.id,
                      let findings = input.findingsByObservation[observationID] else { continue }
                for finding in findings.sorted(by: { $0.sortOrder < $1.sortOrder || ($0.sortOrder == $1.sortOrder && $0.id < $1.id) }) {
                    numbering.numberByFindingID[finding.id] = counter
                    numbering.ordered.append(finding)
                    counter += 1
                }
            }
        }
        return numbering
    }

    // MARK: Cover

    func coverPage() -> ReportPage {
        var elements: [ReportElement] = []
        let margin = theme.margin
        let width = theme.contentWidth

        // A hero photo occupying the top half. The property is the subject;
        // leading with a logo would make the report about us.
        let heroHeight = Points(centi: theme.pageSize.height.centi * 42 / 100)
        if let cover = input.coverPhoto {
            elements.append(.photo(.init(
                mediaID: cover.id,
                relativePath: cover.localPath,
                frame: Rect(x: .zero, y: .zero, width: theme.pageSize.width, height: heroHeight),
                sourceWidth: cover.width, sourceHeight: cover.height,
                caption: nil)))
        } else {
            elements.append(.box(.init(
                frame: Rect(x: .zero, y: .zero, width: theme.pageSize.width, height: heroHeight),
                fill: RGB(hex: 0xEDEEEA))))
        }

        var y = heroHeight + Points(40)

        // A brand rule, not a coloured banner. It identifies the firm without
        // making the cover an advertisement.
        elements.append(.rule(.init(
            frame: Rect(x: margin, y: y, width: Points(72), height: Points(centi: 300)),
            color: RGB(hex: parseHex(input.org.brandColor) ?? 0x1B4D3E))))
        y = y + Points(24)

        let addressLines = FontMetrics.wrap(
            input.property.address1, font: .helveticaBold, size: theme.titleSize, maxWidth: width)
        for line in addressLines {
            elements.append(.text(.init(
                string: line,
                origin: Rect(x: margin, y: y, width: width, height: theme.lineHeight(for: theme.titleSize)),
                font: .helveticaBold, size: theme.titleSize, color: .ink)))
            y = y + theme.lineHeight(for: theme.titleSize)
        }

        let locality = [input.property.city, input.property.region, input.property.postalCode]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        if !locality.isEmpty {
            y = y + Points(6)
            elements.append(.text(.init(
                string: locality,
                origin: Rect(x: margin, y: y, width: width, height: theme.lineHeight(for: theme.headingSize)),
                font: .helvetica, size: theme.headingSize, color: .slate)))
            y = y + theme.lineHeight(for: theme.headingSize)
        }

        y = y + Points(28)
        elements.append(.rule(.init(
            frame: Rect(x: margin, y: y, width: width, height: Points(centi: 50)), color: .line)))
        y = y + Points(20)

        // The facts a client checks first, in the order they check them.
        let facts: [(String, String)] = [
            ("Inspection date", Self.formatDate(input.inspection.startedAt ?? input.inspection.createdAt)),
            ("Inspector", input.inspector.name),
            ("Licence", input.inspector.licenseNo ?? input.org.licenseNo ?? "—"),
            ("Prepared for", input.inspection.clientName ?? "—"),
            ("Report type", input.snapshot.name),
        ]
        for (label, value) in facts {
            elements.append(.text(.init(
                string: label,
                origin: Rect(x: margin, y: y, width: Points(140), height: theme.lineHeight(for: theme.bodySize)),
                font: .helvetica, size: theme.bodySize, color: .slate)))
            elements.append(.text(.init(
                string: value,
                origin: Rect(x: margin + Points(150), y: y, width: width - Points(150),
                             height: theme.lineHeight(for: theme.bodySize)),
                font: .helveticaBold, size: theme.bodySize, color: .ink)))
            y = y + theme.lineHeight(for: theme.bodySize) + Points(6)
        }

        // Firm identification sits at the foot, quietly.
        let footY = theme.pageSize.height - margin - theme.lineHeight(for: theme.bodySize)
        elements.append(.text(.init(
            string: input.org.name,
            origin: Rect(x: margin, y: footY, width: width, height: theme.lineHeight(for: theme.bodySize)),
            font: .helveticaBold, size: theme.bodySize, color: .ink)))

        return ReportPage(elements: elements)
    }

    // MARK: Summary

    func layoutSummary(into cursor: inout PageCursor, numbering: Numbering) {
        let actionable = numbering.ordered
            .filter { $0.severity.rank >= Severity.monitor.rank }
            .sorted {
                $0.severity.rank != $1.severity.rank
                    ? $0.severity.rank > $1.severity.rank
                    : (numbering.numberByFindingID[$0.id] ?? 0) < (numbering.numberByFindingID[$1.id] ?? 0)
            }

        cursor.heading("Summary of findings", theme: theme)

        guard !actionable.isEmpty else {
            cursor.paragraph(
                "No safety, repair or monitoring items were identified at the time of inspection.",
                theme: theme, font: .helvetica, size: theme.bodySize, color: .slate)
            return
        }

        cursor.paragraph(
            "The items below require attention. They are repeated in full, with photographs, "
                + "in the section-by-section detail that follows.",
            theme: theme, font: .helvetica, size: theme.bodySize, color: .slate)
        cursor.space(Points(10))

        var lastSeverity: Severity?
        for finding in actionable {
            if finding.severity != lastSeverity {
                cursor.space(Points(8))
                cursor.subheading(finding.severity.label,
                                  color: finding.severity.printColor, theme: theme)
                lastSeverity = finding.severity
            }
            cursor.summaryRow(
                number: numbering.numberByFindingID[finding.id] ?? 0,
                finding: finding,
                theme: theme)
        }
    }

    // MARK: Detail

    func layoutSections(into cursor: inout PageCursor, numbering: Numbering) {
        for section in input.snapshot.sections {
            let items = section.items.filter {
                input.snapshot.isVisible(item: $0, answers: input.answers)
            }
            let answered = items.filter { input.answers[$0.id] != nil }
            // A section nobody touched is omitted rather than printed empty.
            // Fifteen headings over "Not inspected" is padding, and padding in
            // a liability document reads as carelessness.
            guard !answered.isEmpty else { continue }

            cursor.pageBreak()
            cursor.heading(section.title, theme: theme)

            for item in items {
                guard let observation = input.answers[item.id] else { continue }
                layoutItem(item: item, observation: observation,
                           into: &cursor, numbering: numbering)
            }
        }
    }

    private func layoutItem(
        item: SnapshotItem, observation: Observation,
        into cursor: inout PageCursor, numbering: Numbering
    ) {
        let findings = input.findingsByObservation[observation.id] ?? []
        let media = input.mediaByObservation[observation.id] ?? []

        // Keep the label with at least its first line of content. A heading
        // stranded at the foot of a page is the classic amateur PDF tell.
        cursor.reserve(theme.lineHeight(for: theme.bodySize) * 3)

        cursor.labelValue(
            label: item.label,
            value: Self.describe(observation: observation, item: item),
            theme: theme)

        for finding in findings.sorted(by: { $0.sortOrder < $1.sortOrder || ($0.sortOrder == $1.sortOrder && $0.id < $1.id) }) {
            cursor.findingBlock(
                number: numbering.numberByFindingID[finding.id] ?? 0,
                finding: finding,
                theme: theme)
        }

        if !media.isEmpty {
            cursor.photoGrid(media: media, theme: theme)
        }

        cursor.space(Points(10))
    }

    // MARK: Helpers

    /// How an answer reads in the report. Not the raw stored value — "1" is
    /// meaningless to a client, "Marginal" is not.
    static func describe(observation: Observation, item: SnapshotItem) -> String {
        switch item.inputType {
        case .rating:
            guard let index = observation.valueNumber.map({ Int($0) }),
                  let options = item.options, options.indices.contains(index) else { return "—" }
            return options[index]
        case .bool:
            guard let value = observation.valueBool else { return "—" }
            return value ? "Yes" : "No"
        case .number:
            guard let value = observation.valueNumber else { return "—" }
            let formatted = value == value.rounded() ? String(Int(value)) : String(value)
            return item.unit.map { "\(formatted) \($0)" } ?? formatted
        case .multiselect:
            let options = observation.selectedOptions
            return options.isEmpty ? "—" : options.joined(separator: ", ")
        case .signature:
            return observation.valueText == nil ? "—" : "Signed"
        case .photoOnly:
            return "See photographs"
        case .text, .select:
            let text = observation.valueText ?? ""
            return text.isEmpty ? "—" : text
        }
    }

    static func formatDate(_ millis: Int64) -> String {
        // Deliberately hand-formatted rather than using DateFormatter: a
        // formatter's output depends on the device locale and calendar, which
        // would make the same inspection render differently on two phones and
        // break the layout hash.
        let seconds = Int(millis / 1000)
        var days = seconds / 86_400
        var year = 1970
        while true {
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            let length = leap ? 366 : 365
            if days < length { break }
            days -= length
            year += 1
        }
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        let names = ["January", "February", "March", "April", "May", "June", "July",
                     "August", "September", "October", "November", "December"]
        var month = 0
        while month < 12 && days >= lengths[month] {
            days -= lengths[month]
            month += 1
        }
        return "\(names[min(month, 11)]) \(days + 1), \(year)"
    }

    func parseHex(_ string: String) -> Int? {
        Int(string.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16)
    }

    func withPageNumber(_ page: ReportPage, number: Int, total: Int) -> ReportPage {
        var elements = page.elements
        let label = "\(input.property.address1)  ·  Page \(number) of \(total)"
        elements.append(.rule(.init(
            frame: Rect(x: theme.margin, y: theme.pageSize.height - theme.margin + Points(10),
                        width: theme.contentWidth, height: Points(centi: 50)),
            color: .line)))
        elements.append(.text(.init(
            string: label,
            origin: Rect(x: theme.margin, y: theme.pageSize.height - theme.margin + Points(18),
                         width: theme.contentWidth, height: theme.lineHeight(for: theme.captionSize)),
            font: .helvetica, size: theme.captionSize, color: .slate)))
        return ReportPage(elements: elements)
    }
}
