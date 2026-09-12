import Foundation
import GRDB

/// The built-in residential template.
///
/// Phase 1 ships one hardcoded template so the checklist has something real to
/// render. It is deliberately a full-size inspection — 60 items across 8
/// sections — because a 6-item toy template hides every problem that matters:
/// scroll performance, section anchoring, conditional items, and whether the
/// progress affordance is legible when it says 41/60 rather than 2/6.
public enum ResidentialTemplate {

    public static let templateName = "Residential — Full"

    struct ItemSpec {
        let label: String
        let type: InputType
        let options: [String]?
        let required: Bool
        let help: String?
        let unit: String?
        let dependsOnLabel: String?
        let dependsOnValue: String?

        init(
            _ label: String, _ type: InputType, options: [String]? = nil, required: Bool = false,
            help: String? = nil, unit: String? = nil,
            dependsOnLabel: String? = nil, dependsOnValue: String? = nil
        ) {
            self.label = label
            self.type = type
            self.options = options
            self.required = required
            self.help = help
            self.unit = unit
            self.dependsOnLabel = dependsOnLabel
            self.dependsOnValue = dependsOnValue
        }
    }

    struct SectionSpec {
        let title: String
        let icon: String
        let items: [ItemSpec]
    }

    /// `condition` is the rating scale used throughout. Four points, no
    /// midpoint: a five-point scale collects a lot of meaningless 3s, and an
    /// inspector who cannot decide should be writing a finding instead.
    static let conditionScale = ["Serviceable", "Marginal", "Defective", "Not inspected"]

    static let sections: [SectionSpec] = [
        SectionSpec(title: "Roof", icon: "house.fill", items: [
            ItemSpec("Roof covering type", .select,
                     options: ["Asphalt shingle", "Tile", "Metal", "Membrane", "Wood shake"],
                     required: true),
            ItemSpec("Estimated age", .number, unit: "yrs"),
            ItemSpec("Shingle condition", .rating, options: conditionScale, required: true,
                     help: "Rate the field of the roof, not the penetrations."),
            ItemSpec("Flashing and penetrations", .rating, options: conditionScale),
            ItemSpec("Gutters and downspouts", .rating, options: conditionScale),
            ItemSpec("Roof drainage discharges away from foundation", .bool),
            ItemSpec("Skylights present", .bool),
            ItemSpec("Skylight condition", .rating, options: conditionScale,
                     dependsOnLabel: "Skylights present", dependsOnValue: "true"),
            ItemSpec("Method of inspection", .select,
                     options: ["Walked", "From ladder at eave", "From ground with binoculars", "Drone"],
                     required: true,
                     help: "Report language and liability both depend on this. Be exact."),
        ]),
        SectionSpec(title: "Exterior", icon: "building.2", items: [
            ItemSpec("Wall cladding", .multiselect,
                     options: ["Brick", "Vinyl", "Stucco", "Fiber cement", "Wood", "Stone"]),
            ItemSpec("Cladding condition", .rating, options: conditionScale, required: true),
            ItemSpec("Trim and soffits", .rating, options: conditionScale),
            ItemSpec("Windows", .rating, options: conditionScale),
            ItemSpec("Exterior doors", .rating, options: conditionScale),
            ItemSpec("Grading slopes away from structure", .bool, required: true),
            ItemSpec("Walkways and driveway", .rating, options: conditionScale),
            ItemSpec("Deck or porch present", .bool),
            ItemSpec("Deck ledger attachment", .rating, options: conditionScale,
                     help: "Ledger failures are the most common deck collapse cause. Photograph it.",
                     dependsOnLabel: "Deck or porch present", dependsOnValue: "true"),
            ItemSpec("Guardrail height", .number, unit: "in",
                     dependsOnLabel: "Deck or porch present", dependsOnValue: "true"),
        ]),
        SectionSpec(title: "Structure", icon: "square.stack.3d.up", items: [
            ItemSpec("Foundation type", .select,
                     options: ["Slab on grade", "Crawlspace", "Basement", "Pier and beam"],
                     required: true),
            ItemSpec("Foundation condition", .rating, options: conditionScale, required: true),
            ItemSpec("Visible cracking", .bool),
            ItemSpec("Crack width", .number, unit: "in",
                     dependsOnLabel: "Visible cracking", dependsOnValue: "true"),
            ItemSpec("Framing condition", .rating, options: conditionScale),
            ItemSpec("Crawlspace access and clearance", .photoOnly,
                     dependsOnLabel: "Foundation type", dependsOnValue: "Crawlspace"),
            ItemSpec("Moisture or standing water observed", .bool),
            ItemSpec("Vapor barrier present", .bool,
                     dependsOnLabel: "Foundation type", dependsOnValue: "Crawlspace"),
        ]),
        SectionSpec(title: "Electrical", icon: "bolt.fill", items: [
            ItemSpec("Service size", .number, unit: "amps", required: true),
            ItemSpec("Service entrance", .select, options: ["Overhead", "Underground"]),
            ItemSpec("Panel manufacturer", .text,
                     help: "Federal Pacific, Zinsco and Challenger panels are a safety finding on sight."),
            ItemSpec("Panel condition", .rating, options: conditionScale, required: true),
            ItemSpec("Grounding and bonding verified", .bool, required: true),
            ItemSpec("AFCI protection present", .bool),
            ItemSpec("GFCI protection at required locations", .bool, required: true),
            ItemSpec("Knob and tube or aluminum branch wiring", .bool),
            ItemSpec("Smoke alarms present and tested", .bool, required: true),
            ItemSpec("Carbon monoxide alarms present", .bool, required: true),
        ]),
        SectionSpec(title: "Plumbing", icon: "drop.fill", items: [
            ItemSpec("Supply piping material", .multiselect,
                     options: ["Copper", "PEX", "CPVC", "Galvanized steel", "Polybutylene"],
                     required: true,
                     help: "Polybutylene is a repair finding regardless of current condition."),
            ItemSpec("Drain piping material", .multiselect,
                     options: ["PVC", "ABS", "Cast iron", "Galvanized steel"]),
            ItemSpec("Functional flow adequate", .bool),
            ItemSpec("Visible leaks", .bool),
            ItemSpec("Water heater type", .select, options: ["Tank — gas", "Tank — electric", "Tankless", "Heat pump"]),
            ItemSpec("Water heater age", .number, unit: "yrs"),
            ItemSpec("TPR valve and discharge piping", .rating, options: conditionScale, required: true,
                     help: "A missing or improperly terminated discharge line is a safety finding."),
            ItemSpec("Main shutoff located", .bool),
        ]),
        SectionSpec(title: "HVAC", icon: "wind", items: [
            ItemSpec("Heating type", .select,
                     options: ["Forced air — gas", "Forced air — electric", "Heat pump", "Boiler", "Baseboard"],
                     required: true),
            ItemSpec("Heating age", .number, unit: "yrs"),
            ItemSpec("Heating condition", .rating, options: conditionScale, required: true),
            ItemSpec("Cooling type", .select, options: ["Split system", "Package unit", "Mini-split", "None"]),
            ItemSpec("Cooling condition", .rating, options: conditionScale,
                     dependsOnLabel: "Cooling type", dependsOnValue: "Split system"),
            ItemSpec("Temperature differential", .number, unit: "°F",
                     help: "Supply minus return. Under 14 or over 22 warrants a finding."),
            ItemSpec("Combustion venting", .rating, options: conditionScale),
            ItemSpec("Filter condition", .rating, options: conditionScale),
        ]),
        SectionSpec(title: "Interior", icon: "sofa.fill", items: [
            ItemSpec("Ceilings", .rating, options: conditionScale),
            ItemSpec("Walls", .rating, options: conditionScale),
            ItemSpec("Floors", .rating, options: conditionScale),
            ItemSpec("Stairs and handrails", .rating, options: conditionScale, required: true),
            ItemSpec("Windows operate", .bool),
            ItemSpec("Evidence of prior water intrusion", .bool),
            ItemSpec("Fireplace present", .bool),
            ItemSpec("Fireplace and chimney condition", .rating, options: conditionScale,
                     dependsOnLabel: "Fireplace present", dependsOnValue: "true"),
        ]),
        SectionSpec(title: "Report", icon: "signature", items: [
            ItemSpec("Areas not inspected", .text,
                     help: "Be specific. This paragraph is the one that gets read back to you."),
            ItemSpec("Weather at time of inspection", .select,
                     options: ["Clear", "Overcast", "Rain", "Snow"], required: true),
            ItemSpec("Occupancy", .select, options: ["Occupied — furnished", "Vacant", "Under construction"]),
            ItemSpec("Client present", .bool),
            ItemSpec("Inspector signature", .signature, required: true),
        ]),
    ]

    /// Install the template into an org. Idempotent by (org, name, version).
    @discardableResult
    public static func install(orgID: String, into ctx: MutationContext) throws -> String {
        if let existing = try String.fetchOne(ctx.db, sql: """
            SELECT id FROM template
            WHERE org_id = ? AND name = ? AND version = 1 AND deleted_at IS NULL
            """, arguments: [orgID, templateName])
        {
            return existing
        }

        let templateID = try ctx.insert(.template, [
            "org_id": orgID,
            "name": templateName,
            "discipline": Discipline.home.rawValue,
            "version": 1,
            "published_at": ctx.now,
        ])

        // Conditional items reference their controller by label in the spec, so
        // resolve labels to ids after every item exists.
        var idByLabel: [String: String] = [:]
        var pendingDependencies: [(itemID: String, controllerLabel: String, value: String)] = []

        for (sectionIndex, section) in sections.enumerated() {
            let sectionID = try ctx.insert(.templateSection, [
                "template_id": templateID,
                "title": section.title,
                "sort_order": sectionIndex,
                "icon": section.icon,
            ])

            for (itemIndex, item) in section.items.enumerated() {
                let optionsJSON = try item.options.map { try CanonicalJSON.encode($0) }
                let itemID = try ctx.insert(.templateItem, [
                    "section_id": sectionID,
                    "label": item.label,
                    "input_type": item.type.rawValue,
                    "options_json": optionsJSON,
                    "required": item.required,
                    "sort_order": itemIndex,
                    "help_text": item.help,
                    "unit": item.unit,
                ])
                idByLabel[item.label] = itemID
                if let controller = item.dependsOnLabel, let value = item.dependsOnValue {
                    pendingDependencies.append((itemID, controller, value))
                }
            }
        }

        for dependency in pendingDependencies {
            guard let controllerID = idByLabel[dependency.controllerLabel] else {
                throw TemplateError.notFound(
                    "conditional item references unknown label '\(dependency.controllerLabel)'")
            }
            try ctx.update(.templateItem, id: dependency.itemID, [
                "depends_on_item_id": controllerID,
                "depends_on_value": dependency.value,
            ])
        }

        return templateID
    }

    public static var itemCount: Int { sections.reduce(0) { $0 + $1.items.count } }
}
