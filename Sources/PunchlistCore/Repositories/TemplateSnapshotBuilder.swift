import Foundation
import GRDB

/// Builds a frozen `TemplateSnapshot` from the live authoring tables.
///
/// Called exactly once per inspection, at creation. After that the authoring
/// tables are irrelevant to that inspection forever — which is the entire
/// mechanism behind "a report renders identically forever".
public enum TemplateSnapshotBuilder {

    public static func build(templateID: String, db: Database) throws -> TemplateSnapshot {
        guard let template = try Row.fetchOne(
            db, sql: "SELECT * FROM template WHERE id = ? AND deleted_at IS NULL",
            arguments: [templateID])
        else { throw TemplateError.notFound(templateID) }

        let sectionRows = try Row.fetchAll(db, sql: """
            SELECT * FROM template_section
            WHERE template_id = ? AND deleted_at IS NULL
            ORDER BY sort_order, id
            """, arguments: [templateID])

        var sections: [SnapshotSection] = []
        sections.reserveCapacity(sectionRows.count)

        for s in sectionRows {
            let sectionID: String = s["id"]
            let itemRows = try Row.fetchAll(db, sql: """
                SELECT * FROM template_item
                WHERE section_id = ? AND deleted_at IS NULL
                ORDER BY sort_order, id
                """, arguments: [sectionID])

            let items = try itemRows.map { i -> SnapshotItem in
                let raw: String = i["input_type"]
                guard let inputType = InputType(rawValue: raw) else {
                    throw TemplateError.unknownInputType(raw)
                }
                return SnapshotItem(
                    id: i["id"],
                    label: i["label"],
                    inputType: inputType,
                    options: decodeOptions(i["options_json"]),
                    required: (i["required"] as Int) != 0,
                    sortOrder: i["sort_order"],
                    helpText: i["help_text"],
                    unit: i["unit"],
                    dependsOnItemId: i["depends_on_item_id"],
                    dependsOnValue: i["depends_on_value"])
            }

            sections.append(SnapshotSection(
                id: sectionID,
                title: s["title"],
                sortOrder: s["sort_order"],
                icon: s["icon"],
                items: items))
        }

        let raw: String = template["discipline"]
        guard let discipline = Discipline(rawValue: raw) else {
            throw TemplateError.unknownDiscipline(raw)
        }

        return TemplateSnapshot(
            templateId: templateID,
            name: template["name"],
            discipline: discipline,
            version: template["version"],
            sections: sections)
    }

    /// `options_json` is the one place the schema stores a JSON array, because
    /// nothing ever queries inside it. Decoded into `[String]` here so the
    /// snapshot itself holds a real array and the report never parses JSON.
    private static func decodeOptions(_ json: String?) -> [String]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }
}

public enum TemplateError: Error, CustomStringConvertible {
    case notFound(String)
    case unknownInputType(String)
    case unknownDiscipline(String)

    public var description: String {
        switch self {
        case .notFound(let id): return "No template with id \(id)"
        case .unknownInputType(let t): return "Unknown template item input_type: \(t)"
        case .unknownDiscipline(let d): return "Unknown template discipline: \(d)"
        }
    }
}
