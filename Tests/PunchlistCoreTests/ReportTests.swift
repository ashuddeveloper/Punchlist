import GRDB
import XCTest
@testable import PunchlistCore

final class FontMetricsTests: XCTestCase {

    /// The width tables are the foundation of every layout decision. A single
    /// wrong entry would shift line breaks, which would shift pages, which
    /// would change the layout hash for every report ever produced.
    func testWidthTablesAreComplete() {
        XCTAssertEqual(FontMetrics.helvetica.count, 95, "ASCII 32-126 inclusive")
        XCTAssertEqual(FontMetrics.helveticaBold.count, 95)
        XCTAssertTrue(FontMetrics.helvetica.allSatisfy { $0 > 0 })
        XCTAssertTrue(FontMetrics.helveticaBold.allSatisfy { $0 > 0 })
    }

    /// Spot-checks against the published Adobe AFM values.
    func testKnownAdvanceWidths() {
        XCTAssertEqual(FontMetrics.width(of: " ", font: .helvetica), 278)
        XCTAssertEqual(FontMetrics.width(of: "M", font: .helvetica), 833)
        XCTAssertEqual(FontMetrics.width(of: "i", font: .helvetica), 222)
        XCTAssertEqual(FontMetrics.width(of: "0", font: .helvetica), 556)
        XCTAssertEqual(FontMetrics.width(of: "W", font: .helveticaBold), 944)
        XCTAssertEqual(FontMetrics.width(of: "l", font: .helveticaBold), 278)
    }

    /// Digits must all be the same width, or every number in the report shivers
    /// and columns of measurements stop aligning.
    func testDigitsAreTabular() {
        let widths = Set("0123456789".map { FontMetrics.width(of: $0, font: .helvetica) })
        XCTAssertEqual(widths.count, 1)
    }

    func testWrapRespectsMaxWidth() {
        let text = "Granule loss and cupping were observed across the field of the roof covering."
        let maxWidth = Points(200)
        let lines = FontMetrics.wrap(text, font: .helvetica, size: Points(11), maxWidth: maxWidth)

        XCTAssertGreaterThan(lines.count, 1)
        for line in lines {
            XCTAssertLessThanOrEqual(
                FontMetrics.width(of: line, font: .helvetica, size: Points(11)).centi,
                maxWidth.centi,
                "line overflows: \(line)")
        }
        XCTAssertEqual(lines.joined(separator: " "), text, "wrapping must not lose words")
    }

    /// A 90-character serial number in a finding must not run off the page.
    func testUnbreakableWordIsHardBroken() {
        let long = String(repeating: "X", count: 120)
        let lines = FontMetrics.wrap(long, font: .helvetica, size: Points(11), maxWidth: Points(100))
        XCTAssertGreaterThan(lines.count, 1)
        for line in lines {
            XCTAssertLessThanOrEqual(
                FontMetrics.width(of: line, font: .helvetica, size: Points(11)).centi, 10_000)
        }
        XCTAssertEqual(lines.joined(), long, "hard breaking must not lose characters")
    }

    /// Regression: the hard-break scan used to continue past the first
    /// character that did not fit, so a narrow character later in a long word
    /// (an "i" after a run of "W"s) would still pass the width test and be
    /// appended to the current chunk while the wider characters before it had
    /// already gone to the remainder — silently reordering the text.
    func testHardBreakPreservesCharacterOrder() {
        for word in [
            String(repeating: "W", count: 20) + String(repeating: "i", count: 10),
            String(repeating: "i", count: 10) + String(repeating: "W", count: 20),
            "MMMMMMMMMMlllllllllMMMMMMMMMM",
        ] {
            let lines = FontMetrics.wrap(
                word, font: .helvetica, size: Points(11), maxWidth: Points(60))
            XCTAssertGreaterThan(lines.count, 1, "\(word) should have been broken")
            XCTAssertEqual(lines.joined(), word, "characters were reordered or dropped")
        }
    }

    func testWrapPreservesExplicitNewlines() {
        let lines = FontMetrics.wrap("one\ntwo", font: .helvetica, size: Points(11), maxWidth: Points(400))
        XCTAssertEqual(lines, ["one", "two"])
    }

    /// `Points` is integer precisely so the IR's encoding is byte-stable.
    func testPointsEncodesAsBareInteger() throws {
        let json = try CanonicalJSON.encode(["x": Points(centi: 1234)])
        XCTAssertEqual(json, "{\"x\":1234}")
    }
}

final class ReportLayoutTests: XCTestCase {

    /// Builds a realistic inspection: answers across every section, findings of
    /// mixed severity, and photos.
    private func seededReport() throws -> (AppDatabase, String) {
        let db = try AppDatabase.inMemory()
        let seed = try FirstRun.bootstrapIfNeeded(db)
        let checklist = ChecklistRepository(database: db)
        let media = MediaRepository(database: db)

        let inspectionID = try InspectionRepository(database: db).create(
            orgID: seed.orgID, inspectorID: seed.inspectorID, templateID: seed.templateID,
            property: NewProperty(
                address1: "1490 Alder Creek Road", city: "Bellingham", region: "WA",
                postalCode: "98225"),
            clientName: "Marisol Reyes")

        let snapshot = try XCTUnwrap(
            try db.read(InspectionRepository.find(id: inspectionID))).snapshot()

        var findingCount = 0
        for section in snapshot.sections {
            for (index, item) in section.items.enumerated() {
                let value: AnswerValue
                switch item.inputType {
                case .rating: value = .rating(index % 3)
                case .bool: value = .bool(index % 2 == 0)
                case .number: value = .number(Double(index + 4))
                case .multiselect: value = .options(Array(item.options?.prefix(2) ?? []))
                case .select: value = .text(item.options?.first ?? "n/a")
                case .text: value = .text("Observed at the time of inspection.")
                case .photoOnly, .signature: value = .text("captured")
                }
                let observationID = try checklist.setAnswer(
                    inspectionID: inspectionID, sectionID: section.id, itemID: item.id, value: value)

                if index % 5 == 0 {
                    let severity = Severity.allCases[findingCount % Severity.allCases.count]
                    try checklist.addFinding(
                        inspectionID: inspectionID, observationID: observationID,
                        severity: severity,
                        narrative: "Condition observed at \(item.label). "
                            + "Documented with photographs and described for the client's record.",
                        recommendation: "Have a licensed contractor evaluate and correct.",
                        locationNote: "North elevation")
                    findingCount += 1

                    let mediaID = try media.record(
                        orgID: seed.orgID, inspectionID: inspectionID, kind: .photo,
                        localPath: "photos/\(item.id).jpg", thumbPath: "thumbs/\(item.id).jpg",
                        bytes: 400_000, width: 2048, height: 1536,
                        capturedAt: 1_700_000_000_000 + Int64(findingCount))
                    try media.file(mediaIDs: [mediaID], toObservation: observationID)
                }
            }
        }
        return (db, inspectionID)
    }

    func testProducesAMultiPageDocument() throws {
        let (db, inspectionID) = try seededReport()
        let document = try ReportBuilder(database: db).buildDocument(inspectionID: inspectionID)

        XCTAssertGreaterThan(document.pages.count, 3)
        XCTAssertEqual(document.metadata.pageCount, document.pages.count)
        XCTAssertEqual(document.pageSize, .letter)
        XCTAssertFalse(document.pages[0].elements.isEmpty, "the cover must not be blank")
    }

    /// Acceptance test 5, in its defensible form: the layout is a pure function
    /// of stored data, so building it twice is bit-for-bit identical.
    func testLayoutIsDeterministic() throws {
        let (db, inspectionID) = try seededReport()
        let builder = ReportBuilder(database: db)

        let first = try builder.buildDocument(inspectionID: inspectionID)
        let second = try builder.buildDocument(inspectionID: inspectionID)

        XCTAssertEqual(first, second)
        XCTAssertEqual(try first.layoutHash(), try second.layoutHash())

        // And stable across repeated encodings, which is what the hash relies on.
        for _ in 0..<20 {
            XCTAssertEqual(try first.layoutHash(), try second.layoutHash())
        }
    }

    /// Editing the template must not change a report that has already been
    /// performed — the claim the whole snapshot mechanism exists to support.
    func testTemplateEditDoesNotChangeAnExistingReport() throws {
        let (db, inspectionID) = try seededReport()
        let builder = ReportBuilder(database: db)
        let before = try builder.buildDocument(inspectionID: inspectionID)
        let beforeHash = try before.layoutHash()

        let templateID = try XCTUnwrap(
            try db.read(InspectionRepository.find(id: inspectionID))).templateId
        try db.write { ctx in
            let items = try String.fetchAll(ctx.db, sql: """
                SELECT ti.id FROM template_item ti
                JOIN template_section ts ON ts.id = ti.section_id
                WHERE ts.template_id = ?
                """, arguments: [templateID])
            for id in items.prefix(10) {
                try ctx.update(.templateItem, id: id, ["label": "Renamed \(id)"])
            }
            let sectionID = try XCTUnwrap(try String.fetchOne(ctx.db, sql: """
                SELECT id FROM template_section WHERE template_id = ? ORDER BY sort_order LIMIT 1
                """, arguments: [templateID]))
            try ctx.insert(.templateItem, [
                "section_id": sectionID, "label": "Added later", "input_type": "text",
                "required": false, "sort_order": 999,
            ])
        }

        let after = try builder.buildDocument(inspectionID: inspectionID)
        XCTAssertEqual(try after.layoutHash(), beforeHash)
        XCTAssertEqual(after.pages.count, before.pages.count)
    }

    /// The summary is the page clients read. Safety must lead it, and every
    /// actionable finding must appear on it — an inspector who buries a safety
    /// item has practically not reported it.
    func testSummaryLeadsWithSafetyAndListsEveryActionableFinding() throws {
        let (db, inspectionID) = try seededReport()
        let input = try ReportBuilder(database: db).loadInput(inspectionID: inspectionID)
        let layout = ReportLayout(theme: .standard, input: input)
        let document = layout.build()

        let actionable = input.findingsByObservation.values.flatMap { $0 }
            .filter { $0.severity.rank >= Severity.monitor.rank }
        XCTAssertFalse(actionable.isEmpty, "the fixture must produce findings")

        // Page 2 onward is the summary; collect its severity marks in order.
        let summaryMarks = document.pages[1].elements.compactMap { element -> PrintMark? in
            if case .mark(let mark) = element { return mark.shape }
            return nil
        }
        XCTAssertEqual(summaryMarks.first, Severity.safety.printMark,
                       "the summary must open with safety items")

        // Every actionable finding is numbered somewhere in the document.
        let numbering = layout.numberFindings()
        for finding in actionable {
            XCTAssertNotNil(numbering.numberByFindingID[finding.id],
                            "finding \(finding.id) was never numbered")
        }
    }

    /// Numbers must be unique and contiguous, or a cross-reference from the
    /// summary points at the wrong item in the detail.
    func testFindingNumbersAreUniqueAndContiguous() throws {
        let (db, inspectionID) = try seededReport()
        let input = try ReportBuilder(database: db).loadInput(inspectionID: inspectionID)
        let numbering = ReportLayout(theme: .standard, input: input).numberFindings()

        let numbers = numbering.numberByFindingID.values.sorted()
        XCTAssertEqual(Set(numbers).count, numbers.count, "numbers must be unique")
        XCTAssertEqual(numbers, Array(1...numbers.count), "numbers must be contiguous from 1")
    }

    /// Nothing may be placed below the bottom margin. An element drawn off-page
    /// is a silently missing finding.
    func testNoElementEscapesThePage() throws {
        let (db, inspectionID) = try seededReport()
        let document = try ReportBuilder(database: db).buildDocument(inspectionID: inspectionID)
        let theme = ReportTheme.standard
        // The cover deliberately bleeds its hero photo to the page edge.
        for (index, page) in document.pages.enumerated() where index > 0 {
            for element in page.elements {
                guard let frame = element.frame else { continue }
                XCTAssertGreaterThanOrEqual(frame.x.centi, 0, "page \(index + 1)")
                XCTAssertLessThanOrEqual(
                    frame.maxX.centi, theme.pageSize.width.centi + 100, "page \(index + 1)")
                XCTAssertLessThanOrEqual(
                    frame.maxY.centi, theme.pageSize.height.centi, "page \(index + 1) overflows")
            }
        }
    }

    func testAllThreeThemesLayOut() throws {
        let (db, inspectionID) = try seededReport()
        let input = try ReportBuilder(database: db).loadInput(inspectionID: inspectionID)

        var hashes: Set<String> = []
        for theme in [ReportTheme.standard, .compact, .narrative] {
            let document = ReportLayout(theme: theme, input: input).build()
            XCTAssertGreaterThan(document.pages.count, 1, "\(theme.name) produced nothing")
            XCTAssertEqual(document.metadata.themeName, theme.name)
            hashes.insert(try document.layoutHash())
        }
        XCTAssertEqual(hashes.count, 3, "the three themes must actually differ")

        // Compact earns its name.
        let compact = ReportLayout(theme: .compact, input: input).build()
        let narrative = ReportLayout(theme: .narrative, input: input).build()
        XCTAssertLessThan(compact.pages.count, narrative.pages.count)
    }

    /// Date formatting is hand-rolled to avoid locale dependence; that only
    /// helps if it is correct.
    func testDateFormatting() {
        XCTAssertEqual(ReportLayout.formatDate(0), "January 1, 1970")
        XCTAssertEqual(ReportLayout.formatDate(1_700_000_000_000), "November 14, 2023")
        // A leap day, the case a hand-rolled calendar gets wrong.
        XCTAssertEqual(ReportLayout.formatDate(1_709_164_800_000), "February 29, 2024")
    }
}

extension ReportElement {
    /// The frame of whatever this element is, for bounds assertions.
    var frame: Rect? {
        switch self {
        case .text(let run): return run.origin
        case .rule(let rule): return rule.frame
        case .box(let box): return box.frame
        case .mark(let mark): return mark.frame
        case .photo(let photo): return photo.frame
        }
    }
}
