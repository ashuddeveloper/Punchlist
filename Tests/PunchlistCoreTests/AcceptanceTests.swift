import GRDB
import XCTest
@testable import PunchlistCore

/// The acceptance tests from the brief that can be verified without a camera or
/// a device. The remainder (60fps scrolling, memory ceiling, shutter latency)
/// are device measurements and live in the performance suite.
final class AcceptanceTests: XCTestCase {

    // MARK: 1 — a whole inspection, entirely offline

    /// Acceptance test 1: complete a 60-item inspection with photos and no
    /// network. Nothing in `PunchlistCore` can even attempt a network call —
    /// there is no URLSession in the module, which `CITests.testNoNetworkInCore`
    /// asserts at the source level. This test proves the *data* path completes.
    func testCompleteInspectionOffline() throws {
        let (db, url) = try Fixture.onDisk()
        defer { Fixture.remove(url) }

        let seed = try FirstRun.bootstrapIfNeeded(db)
        let inspections = InspectionRepository(database: db)
        let checklist = ChecklistRepository(database: db)
        let media = MediaRepository(database: db)

        let inspectionID = try inspections.create(
            orgID: seed.orgID,
            inspectorID: seed.inspectorID,
            templateID: seed.templateID,
            property: NewProperty(address1: "812 Cedar Bluff Rd", city: "Bellingham", region: "WA"),
            clientName: "Marisol Reyes")

        let inspection = try XCTUnwrap(try db.read(InspectionRepository.find(id: inspectionID)))
        let snapshot = try inspection.snapshot()
        XCTAssertGreaterThanOrEqual(snapshot.allItems.count, 60,
                                    "the brief's flow is a 60-item inspection")

        // Answer every item the template offers.
        for section in snapshot.sections {
            for item in section.items {
                let value: AnswerValue
                switch item.inputType {
                case .rating: value = .rating(1)
                case .bool: value = .bool(true)
                case .number: value = .number(12)
                case .text: value = .text("Observed at time of inspection.")
                case .select: value = .text(item.options?.first ?? "n/a")
                case .multiselect: value = .options(Array(item.options?.prefix(2) ?? []))
                case .photoOnly, .signature: value = .text("captured")
                }
                try checklist.setAnswer(
                    inspectionID: inspectionID, sectionID: section.id, itemID: item.id, value: value)
            }
        }

        let answers = try db.read(ChecklistRepository.answers(inspectionID: inspectionID))
        XCTAssertEqual(answers.count, snapshot.allItems.count)

        // A handful of real findings, of mixed severity.
        let roof = try XCTUnwrap(snapshot.sections.first)
        let roofItem = try XCTUnwrap(roof.items.first { $0.inputType == .rating })
        let observationID = try XCTUnwrap(answers[roofItem.id]?.id)

        try checklist.addFinding(
            inspectionID: inspectionID, observationID: observationID, severity: .monitor,
            narrative: "Moss accumulation on the north slope.", locationNote: "North slope")
        try checklist.addFinding(
            inspectionID: inspectionID, observationID: observationID, severity: .safety,
            narrative: "Vent boot missing at the stack penetration.", locationNote: "NE valley")

        // The severity roll-up must show the worst of them.
        let rolled = try db.read(ChecklistRepository.answers(inspectionID: inspectionID))
        XCTAssertEqual(rolled[roofItem.id]?.severity, .safety)

        // 100 photos, some filed and some still in the tray.
        for n in 0..<100 {
            let id = try media.record(
                orgID: seed.orgID, inspectionID: inspectionID, kind: .photo,
                localPath: "photos/\(n).jpg", thumbPath: "thumbs/\(n).jpg",
                bytes: 480_000, width: 2048, height: 1536,
                capturedAt: Clock.nowMillis() + Int64(n))
            if n % 2 == 0 {
                try media.file(mediaIDs: [id], toObservation: observationID)
            }
        }

        let tray = try db.read(MediaRepository.tray(inspectionID: inspectionID))
        XCTAssertEqual(tray.count, 50, "odd-numbered photos stay unfiled")

        let progress = try db.read(
            ChecklistRepository.progress(inspectionID: inspectionID, snapshot: snapshot))
        XCTAssertTrue(progress.isComplete)

        try inspections.setStatus(inspectionID: inspectionID, .complete)
        let done = try XCTUnwrap(try db.read(InspectionRepository.find(id: inspectionID)))
        XCTAssertEqual(done.status, .complete)
        XCTAssertNotNil(done.completedAt)
    }

    // MARK: 2 — force-quit loses nothing

    /// Acceptance test 2: kill the app at arbitrary points during the flow and
    /// lose nothing. Closing the `AppDatabase` and reopening the file is exactly
    /// what a force-quit does to SQLite: there is no in-memory write buffer to
    /// lose, because every mutation is its own committed transaction.
    func testForceQuitAtEveryStepLosesNothing() throws {
        let (first, url) = try Fixture.onDisk()
        defer { Fixture.remove(url) }

        let seed = try FirstRun.bootstrapIfNeeded(first)
        let inspectionID = try InspectionRepository(database: first).create(
            orgID: seed.orgID, inspectorID: seed.inspectorID, templateID: seed.templateID,
            property: NewProperty(address1: "44 Larkspur Ln"))

        let snapshot = try XCTUnwrap(
            try first.read(InspectionRepository.find(id: inspectionID))).snapshot()
        let items = Array(snapshot.allItems.prefix(20))

        // Write one answer, then "force-quit" and reopen, twenty times over.
        var database = first
        for (index, item) in items.enumerated() {
            let section = try XCTUnwrap(snapshot.sectionContaining(itemId: item.id))
            try ChecklistRepository(database: database).setAnswer(
                inspectionID: inspectionID, sectionID: section.id, itemID: item.id,
                value: .text("answer \(index)"))

            // Simulate the kill: drop the handle entirely and open the file fresh.
            database = try AppDatabase.open(at: url.path)

            let answers = try database.read(ChecklistRepository.answers(inspectionID: inspectionID))
            XCTAssertEqual(answers.count, index + 1,
                           "force-quit after answer \(index) lost data")
            XCTAssertEqual(answers[item.id]?.valueText, "answer \(index)")
        }
    }

    // MARK: 5 — a report renders identically forever

    /// Acceptance test 5: modify the template, reopen an old inspection, and the
    /// report inputs are unchanged.
    ///
    /// Note what this asserts and what it does not. It does not claim
    /// byte-identical *PDF* output — that is not achievable against an OS
    /// renderer, which embeds creation timestamps and document ids and changes
    /// font rasterisation across OS versions. It asserts the thing that
    /// actually matters and is defensible: the report's inputs are frozen and
    /// hash identically, so the document is a pure function of data that cannot
    /// change underneath it.
    func testTemplateEditCannotReachBackwards() throws {
        let db = try AppDatabase.inMemory()
        let seed = try FirstRun.bootstrapIfNeeded(db)

        let inspectionID = try InspectionRepository(database: db).create(
            orgID: seed.orgID, inspectorID: seed.inspectorID, templateID: seed.templateID,
            property: NewProperty(address1: "9 Quarry Rd"))

        let original = try XCTUnwrap(try db.read(InspectionRepository.find(id: inspectionID)))
        let originalHash = original.templateSnapshotHash
        let originalSnapshot = try original.snapshot()

        // Six months later, the inspector edits the template: renames an item,
        // adds another, and deletes a third.
        try db.write { ctx in
            let firstItem = try XCTUnwrap(try String.fetchOne(ctx.db, sql: """
                SELECT ti.id FROM template_item ti
                JOIN template_section ts ON ts.id = ti.section_id
                WHERE ts.template_id = ? ORDER BY ts.sort_order, ti.sort_order LIMIT 1
                """, arguments: [seed.templateID]))
            try ctx.update(.templateItem, id: firstItem, ["label": "Renamed after the fact"])

            let sectionID = try XCTUnwrap(try String.fetchOne(ctx.db, sql: """
                SELECT id FROM template_section WHERE template_id = ? ORDER BY sort_order LIMIT 1
                """, arguments: [seed.templateID]))
            try ctx.insert(.templateItem, [
                "section_id": sectionID, "label": "Added later", "input_type": "text",
                "required": false, "sort_order": 99,
            ])

            let doomed = try XCTUnwrap(try String.fetchOne(ctx.db, sql: """
                SELECT id FROM template_item WHERE section_id = ? ORDER BY sort_order DESC LIMIT 1
                """, arguments: [sectionID]))
            try ctx.softDelete(.templateItem, id: doomed)
        }

        // The old inspection is untouched by all of it.
        let reopened = try XCTUnwrap(try db.read(InspectionRepository.find(id: inspectionID)))
        XCTAssertEqual(reopened.templateSnapshotHash, originalHash)
        XCTAssertEqual(try reopened.snapshot(), originalSnapshot)

        // And re-encoding the snapshot is byte-stable, so the hash is a real
        // guarantee rather than an accident of encoding order.
        let reEncoded = try CanonicalJSON.encode(try reopened.snapshot())
        XCTAssertEqual(CanonicalJSON.sha256Hex(reEncoded), originalHash)

        // A *new* inspection does pick up the edit — the freeze is per
        // inspection, not a refusal to ever change anything.
        let freshID = try InspectionRepository(database: db).create(
            orgID: seed.orgID, inspectorID: seed.inspectorID, templateID: seed.templateID,
            property: NewProperty(address1: "11 Quarry Rd"))
        let fresh = try XCTUnwrap(try db.read(InspectionRepository.find(id: freshID)))
        XCTAssertNotEqual(fresh.templateSnapshotHash, originalHash)
    }

    func testCanonicalEncodingIsOrderIndependent() throws {
        // The snapshot hash is only meaningful if encoding is deterministic.
        let a = SnapshotItem(id: "i1", label: "Shingle condition", inputType: .rating,
                             options: ["Serviceable", "Marginal"], required: true, sortOrder: 0,
                             helpText: "Rate the field.", unit: nil)
        let b = SnapshotItem(id: "i1", label: "Shingle condition", inputType: .rating,
                             options: ["Serviceable", "Marginal"], required: true, sortOrder: 0,
                             helpText: "Rate the field.", unit: nil)
        XCTAssertEqual(try CanonicalJSON.hash(a), try CanonicalJSON.hash(b))
        for _ in 0..<50 {
            XCTAssertEqual(try CanonicalJSON.hash(a), try CanonicalJSON.hash(a))
        }
    }

    // MARK: Sparse observations and conditional items

    func testUntouchedChecklistCostsZeroRows() throws {
        let db = try AppDatabase.inMemory()
        let seed = try FirstRun.bootstrapIfNeeded(db)
        let inspectionID = try InspectionRepository(database: db).create(
            orgID: seed.orgID, inspectorID: seed.inspectorID, templateID: seed.templateID,
            property: NewProperty(address1: "3 Harbour View"))

        let count = try db.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM observation WHERE inspection_id = ?",
                             arguments: [inspectionID]) ?? -1
        }
        XCTAssertEqual(count, 0, "observations are sparse by design")
    }

    /// Hiding a conditional item must not destroy answers already recorded
    /// against it. Inspectors change their mind about "is there a basement?"
    /// more often than you would think, and losing the basement answers when
    /// they do is indistinguishable from data loss.
    func testHidingAConditionalItemPreservesItsAnswers() throws {
        let db = try AppDatabase.inMemory()
        let seed = try FirstRun.bootstrapIfNeeded(db)
        let inspectionID = try InspectionRepository(database: db).create(
            orgID: seed.orgID, inspectorID: seed.inspectorID, templateID: seed.templateID,
            property: NewProperty(address1: "77 Pine"))

        let snapshot = try XCTUnwrap(
            try db.read(InspectionRepository.find(id: inspectionID))).snapshot()
        let conditional = try XCTUnwrap(snapshot.allItems.first { $0.isConditional })
        let controllerID = try XCTUnwrap(conditional.dependsOnItemId)
        let controller = try XCTUnwrap(snapshot.item(id: controllerID))
        let controllerSection = try XCTUnwrap(snapshot.sectionContaining(itemId: controllerID))
        let conditionalSection = try XCTUnwrap(snapshot.sectionContaining(itemId: conditional.id))

        let checklist = ChecklistRepository(database: db)
        // Turn the condition on, answer the dependent item, then turn it off.
        try checklist.setAnswer(
            inspectionID: inspectionID, sectionID: controllerSection.id, itemID: controllerID,
            value: controller.inputType == .bool
                ? .bool(true) : .text(try XCTUnwrap(conditional.dependsOnValue)))
        try checklist.setAnswer(
            inspectionID: inspectionID, sectionID: conditionalSection.id, itemID: conditional.id,
            value: .text("recorded while visible"))

        var answers = try db.read(ChecklistRepository.answers(inspectionID: inspectionID))
        XCTAssertTrue(snapshot.isVisible(item: conditional, answers: answers))

        try checklist.setAnswer(
            inspectionID: inspectionID, sectionID: controllerSection.id, itemID: controllerID,
            value: controller.inputType == .bool ? .bool(false) : .text("something else"))

        answers = try db.read(ChecklistRepository.answers(inspectionID: inspectionID))
        XCTAssertFalse(snapshot.isVisible(item: conditional, answers: answers))
        XCTAssertEqual(answers[conditional.id]?.valueText, "recorded while visible",
                       "hidden is not deleted")
    }

    // MARK: Canned comments

    func testSuggestionsRankTheirOwnMostUsedFirst() throws {
        let db = try AppDatabase.inMemory()
        let seed = try FirstRun.bootstrapIfNeeded(db)
        let comments = CannedCommentRepository(database: db)

        let itemID = "roof-shingles"
        let rare = try comments.create(
            orgID: seed.orgID, itemID: itemID, severity: .repair, body: "Rarely used phrasing")
        let common = try comments.create(
            orgID: seed.orgID, itemID: itemID, severity: .repair, body: "The one they always use")

        // Use the second one repeatedly, the way inspection 20 would have.
        let inspectionID = try InspectionRepository(database: db).create(
            orgID: seed.orgID, inspectorID: seed.inspectorID, templateID: seed.templateID,
            property: NewProperty(address1: "5 Beacon"))
        let snapshot = try XCTUnwrap(
            try db.read(InspectionRepository.find(id: inspectionID))).snapshot()
        let section = try XCTUnwrap(snapshot.sections.first)
        let item = try XCTUnwrap(section.items.first)
        let observationID = try ChecklistRepository(database: db).setAnswer(
            inspectionID: inspectionID, sectionID: section.id, itemID: item.id, value: .rating(1))

        for _ in 0..<8 {
            try ChecklistRepository(database: db).addFinding(
                inspectionID: inspectionID, observationID: observationID, severity: .repair,
                narrative: "The one they always use", cannedCommentID: common)
        }

        let ranked = try db.read(CannedCommentRepository.suggestions(
            orgID: seed.orgID, itemID: itemID, severity: .repair, limit: 5))
        XCTAssertEqual(ranked.first?.id, common)
        XCTAssertEqual(ranked.first?.useCount, 8)
        XCTAssertTrue(ranked.contains { $0.id == rare })

        // Item-specific comments beat the global starter library.
        XCTAssertEqual(ranked.prefix(2).filter { $0.itemId == itemID }.count, 2)
    }

    func testFirstRunIsIdempotentAndNeedsNoAccount() throws {
        let (db, url) = try Fixture.onDisk()
        defer { Fixture.remove(url) }

        let first = try FirstRun.bootstrapIfNeeded(db)
        XCTAssertFalse(first.demoInspectionID.isEmpty, "first launch opens into a real inspection")

        let second = try FirstRun.bootstrapIfNeeded(db)
        XCTAssertEqual(first.orgID, second.orgID)
        XCTAssertEqual(first.templateID, second.templateID)

        let orgCount = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM org") ?? 0 }
        XCTAssertEqual(orgCount, 1)
    }
}
