import Foundation

/// The frozen template.
///
/// An inspection stores one of these as canonical JSON at the moment it is
/// created, and both the checklist and the report render from it. The live
/// `template*` tables are the *authoring* side; nothing that has already been
/// performed ever reads them again. That is the whole mechanism behind
/// "a report renders identically forever" — there is no version of the code in
/// which editing a template reaches backwards into a completed inspection.
///
/// Deliberately contains no `Double`. Float formatting is the classic source of
/// "same data, different bytes", and nothing in a template needs one.
public struct TemplateSnapshot: Codable, Sendable, Equatable {
    public var templateId: String
    public var name: String
    public var discipline: Discipline
    public var version: Int
    public var sections: [SnapshotSection]

    public init(
        templateId: String, name: String, discipline: Discipline, version: Int,
        sections: [SnapshotSection]
    ) {
        self.templateId = templateId
        self.name = name
        self.discipline = discipline
        self.version = version
        self.sections = sections
    }

    public var allItems: [SnapshotItem] { sections.flatMap(\.items) }

    public func section(id: String) -> SnapshotSection? { sections.first { $0.id == id } }

    public func item(id: String) -> SnapshotItem? {
        for s in sections { if let i = s.items.first(where: { $0.id == id }) { return i } }
        return nil
    }

    public func sectionContaining(itemId: String) -> SnapshotSection? {
        sections.first { $0.items.contains { $0.id == itemId } }
    }

    public var requiredItemCount: Int { allItems.filter(\.required).count }
}

public struct SnapshotSection: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var sortOrder: Int
    public var icon: String?
    public var items: [SnapshotItem]

    public init(id: String, title: String, sortOrder: Int, icon: String? = nil, items: [SnapshotItem]) {
        self.id = id
        self.title = title
        self.sortOrder = sortOrder
        self.icon = icon
        self.items = items
    }
}

public struct SnapshotItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var inputType: InputType
    public var options: [String]?
    public var required: Bool
    public var sortOrder: Int
    public var helpText: String?
    public var unit: String?
    public var dependsOnItemId: String?
    public var dependsOnValue: String?

    public init(
        id: String, label: String, inputType: InputType, options: [String]? = nil,
        required: Bool = false, sortOrder: Int, helpText: String? = nil, unit: String? = nil,
        dependsOnItemId: String? = nil, dependsOnValue: String? = nil
    ) {
        self.id = id
        self.label = label
        self.inputType = inputType
        self.options = options
        self.required = required
        self.sortOrder = sortOrder
        self.helpText = helpText
        self.unit = unit
        self.dependsOnItemId = dependsOnItemId
        self.dependsOnValue = dependsOnValue
    }

    public var isConditional: Bool { dependsOnItemId != nil }
}

// MARK: - Conditional display

extension TemplateSnapshot {
    /// Whether a conditional item should be shown, given the answers so far.
    ///
    /// A hidden item is hidden, not deleted: if the controlling answer changes
    /// back, any observation already recorded against it reappears untouched.
    /// Inspectors change their mind about "is there a basement?" more often
    /// than you would think, and losing the basement answers when they do would
    /// be indistinguishable from data loss.
    public func isVisible(item: SnapshotItem, answers: [String: Observation]) -> Bool {
        guard let controllerId = item.dependsOnItemId else { return true }
        guard let expected = item.dependsOnValue else { return true }
        guard let controller = answers[controllerId] else { return false }

        if let b = controller.valueBool {
            return expected.lowercased() == (b ? "true" : "false")
        }
        if let n = controller.valueNumber {
            return expected == String(n) || Double(expected) == n
        }
        guard let text = controller.valueText else { return false }
        // multiselect: visible if the expected value is any of the choices
        return text.components(separatedBy: "\t").contains(expected)
    }

    public func visibleItems(in section: SnapshotSection, answers: [String: Observation]) -> [SnapshotItem] {
        section.items.filter { isVisible(item: $0, answers: answers) }
    }
}
