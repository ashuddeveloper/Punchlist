import Foundation

// ============================================================================
// Pagination.
//
// A cursor that accumulates elements down a page and breaks when it runs out of
// room. Every method that emits content first asks whether what it is about to
// emit fits; nothing is ever placed below the bottom margin and then trimmed,
// because a trimmed element is a silently missing finding.
// ============================================================================

public struct PageCursor {
    private let theme: ReportTheme
    private var pages: [ReportPage] = []
    private var current: [ReportElement] = []
    private var y: Points

    public init(theme: ReportTheme) {
        self.theme = theme
        self.y = theme.margin
    }

    private var bottom: Points { theme.pageSize.height - theme.margin }
    private var left: Points { theme.margin }
    private var width: Points { theme.contentWidth }

    // MARK: Page management

    public mutating func finish() -> [ReportPage] {
        if !current.isEmpty { pages.append(ReportPage(elements: current)) }
        current = []
        return pages
    }

    public mutating func pageBreak() {
        guard !current.isEmpty else { return }
        pages.append(ReportPage(elements: current))
        current = []
        y = theme.margin
    }

    /// Ensure `height` is available, breaking first if it is not. This is how
    /// a heading is kept with its content.
    public mutating func reserve(_ height: Points) {
        if y + height > bottom { pageBreak() }
    }

    public mutating func space(_ height: Points) {
        y = y + height
    }

    // MARK: Text

    public mutating func heading(_ text: String, theme: ReportTheme) {
        reserve(theme.lineHeight(for: theme.headingSize) * 2)
        let lineHeight = theme.lineHeight(for: theme.headingSize)
        for line in FontMetrics.wrap(text, font: .helveticaBold, size: theme.headingSize, maxWidth: width) {
            current.append(.text(.init(
                string: line,
                origin: Rect(x: left, y: y, width: width, height: lineHeight),
                font: .helveticaBold, size: theme.headingSize, color: .ink)))
            y = y + lineHeight
        }
        y = y + Points(4)
        current.append(.rule(.init(
            frame: Rect(x: left, y: y, width: width, height: Points(centi: 100)), color: .ink)))
        y = y + Points(12)
    }

    public mutating func subheading(_ text: String, color: RGB, theme: ReportTheme) {
        let lineHeight = theme.lineHeight(for: theme.bodySize)
        reserve(lineHeight * 2)
        current.append(.text(.init(
            string: text,
            origin: Rect(x: left, y: y, width: width, height: lineHeight),
            font: .helveticaBold, size: theme.bodySize, color: color)))
        y = y + lineHeight + Points(4)
    }

    public mutating func paragraph(
        _ text: String, theme: ReportTheme, font: ReportFont = .helvetica,
        size: Points? = nil, color: RGB = .ink, indent: Points = .zero
    ) {
        let fontSize = size ?? theme.bodySize
        let lineHeight = theme.lineHeight(for: fontSize)
        let available = width - indent
        for line in FontMetrics.wrap(text, font: font, size: fontSize, maxWidth: available) {
            // Break per line, not per paragraph. A long narrative must be
            // allowed to flow across a page boundary; refusing to split it
            // would leave an eighth of a page blank and still not fit.
            reserve(lineHeight)
            current.append(.text(.init(
                string: line,
                origin: Rect(x: left + indent, y: y, width: available, height: lineHeight),
                font: font, size: fontSize, color: color)))
            y = y + lineHeight
        }
    }

    /// A checklist item and its answer, on one row where they fit.
    public mutating func labelValue(label: String, value: String, theme: ReportTheme) {
        let lineHeight = theme.lineHeight(for: theme.bodySize)
        let labelWidth = Points(centi: width.centi * 45 / 100)
        let valueWidth = width - labelWidth - Points(12)

        let labelLines = FontMetrics.wrap(label, font: .helvetica, size: theme.bodySize, maxWidth: labelWidth)
        let valueLines = FontMetrics.wrap(value, font: .helveticaBold, size: theme.bodySize, maxWidth: valueWidth)
        let rowHeight = lineHeight * max(labelLines.count, valueLines.count)

        reserve(rowHeight + Points(6))
        let top = y

        for (index, line) in labelLines.enumerated() {
            current.append(.text(.init(
                string: line,
                origin: Rect(x: left, y: top + lineHeight * index, width: labelWidth, height: lineHeight),
                font: .helvetica, size: theme.bodySize, color: .slate)))
        }
        for (index, line) in valueLines.enumerated() {
            current.append(.text(.init(
                string: line,
                origin: Rect(x: left + labelWidth + Points(12), y: top + lineHeight * index,
                             width: valueWidth, height: lineHeight),
                font: .helveticaBold, size: theme.bodySize, color: .ink)))
        }

        y = top + rowHeight + Points(4)
        current.append(.rule(.init(
            frame: Rect(x: left, y: y, width: width, height: Points(centi: 50)), color: .line)))
        y = y + Points(8)
    }

    // MARK: Findings

    /// A summary line: number, severity marker, and the first sentence.
    public mutating func summaryRow(number: Int, finding: Finding, theme: ReportTheme) {
        let lineHeight = theme.lineHeight(for: theme.bodySize)
        let indent = Points(34)
        let available = width - indent

        let text = finding.narrative.isEmpty ? "(no description recorded)" : finding.narrative
        let lines = FontMetrics.wrap(text, font: .helvetica, size: theme.bodySize, maxWidth: available)
        // Reserve the whole row, not a couple of lines of it. Breaking inside
        // this block would strand the severity marker and the finding number at
        // the foot of one page with their text on the next — a numbered finding
        // whose number is on a different page is worse than a short page.
        reserve(lineHeight * max(1, lines.count) + Points(8))
        let top = y

        current.append(.mark(.init(
            frame: Rect(x: left, y: top + Points(centi: 100), width: Points(9), height: Points(9)),
            shape: finding.severity.printMark, color: finding.severity.printColor)))
        current.append(.text(.init(
            string: "\(number)",
            origin: Rect(x: left + Points(14), y: top, width: Points(18), height: lineHeight),
            font: .helveticaBold, size: theme.bodySize, color: .ink)))

        for line in lines {
            current.append(.text(.init(
                string: line,
                origin: Rect(x: left + indent, y: y, width: available, height: lineHeight),
                font: .helvetica, size: theme.bodySize, color: .ink)))
            y = y + lineHeight
        }
        y = y + Points(6)
    }

    /// A finding in the detail sections: severity bar, number, narrative and
    /// recommendation.
    public mutating func findingBlock(number: Int, finding: Finding, theme: ReportTheme) {
        let lineHeight = theme.lineHeight(for: theme.bodySize)
        let indent = Points(16)

        reserve(lineHeight * 3)
        let top = y

        current.append(.mark(.init(
            frame: Rect(x: left, y: top + Points(centi: 150), width: Points(9), height: Points(9)),
            shape: finding.severity.printMark, color: finding.severity.printColor)))

        let header = "\(number). \(finding.severity.label)"
            + (finding.locationNote.map { " — \($0)" } ?? "")
        current.append(.text(.init(
            string: header,
            origin: Rect(x: left + indent, y: y, width: width - indent, height: lineHeight),
            font: .helveticaBold, size: theme.bodySize, color: finding.severity.printColor)))
        y = y + lineHeight + Points(2)

        if !finding.narrative.isEmpty {
            paragraph(finding.narrative, theme: theme, font: .helvetica,
                      size: theme.bodySize, color: .ink, indent: indent)
        }
        if let recommendation = finding.recommendation, !recommendation.isEmpty {
            y = y + Points(3)
            paragraph("Recommendation: \(recommendation)", theme: theme, font: .helveticaOblique,
                      size: theme.bodySize, color: .slate, indent: indent)
        }

        y = y + Points(8)
    }

    // MARK: Photos

    /// Photos inline, N-up per the theme.
    ///
    /// Frames are fixed at a 4:3 box and the renderer fits the image inside it
    /// preserving aspect. Laying out to each photo's true aspect ratio would
    /// make row heights depend on image dimensions, which would mean the page
    /// count of a report could change if a photo were re-imported at a
    /// different size — and page count is part of the layout hash.
    public mutating func photoGrid(media: [MediaItem], theme: ReportTheme) {
        let perRow = max(1, theme.photosPerRow)
        let gap = Points(8)
        let cellWidth = (width - gap * (perRow - 1)) / perRow
        let cellHeight = Points(centi: cellWidth.centi * 3 / 4)
        let captionHeight = theme.lineHeight(for: theme.captionSize)

        var index = 0
        while index < media.count {
            let row = Array(media[index..<min(index + perRow, media.count)])
            let rowHeight = cellHeight + captionHeight + Points(6)
            reserve(rowHeight)
            let top = y

            for (column, item) in row.enumerated() {
                let x = left + (cellWidth + gap) * column
                current.append(.photo(.init(
                    mediaID: item.id,
                    relativePath: item.localPath,
                    frame: Rect(x: x, y: top, width: cellWidth, height: cellHeight),
                    sourceWidth: item.width, sourceHeight: item.height,
                    caption: item.caption)))

                if let caption = item.caption, !caption.isEmpty {
                    let lines = FontMetrics.wrap(
                        caption, font: .helvetica, size: theme.captionSize, maxWidth: cellWidth)
                    // One line only. A three-line caption under one photo and a
                    // one-line caption under its neighbour would make the row
                    // ragged and the next row's position depend on text.
                    if let first = lines.first {
                        current.append(.text(.init(
                            string: first,
                            origin: Rect(x: x, y: top + cellHeight + Points(3),
                                         width: cellWidth, height: captionHeight),
                            font: .helvetica, size: theme.captionSize, color: .slate)))
                    }
                }
            }

            y = top + rowHeight + Points(4)
            index += perRow
        }
    }
}
