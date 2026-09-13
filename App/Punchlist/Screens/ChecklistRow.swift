import PunchlistCore
import SwiftUI

// ============================================================================
// One checklist item.
//
// `Equatable` and taking only value types, so that answering item 12 does not
// re-render the other 59. That is what holds 60fps on a 200-item template: not
// cell reuse, but doing nothing at all for rows that did not change.
// ============================================================================

struct ChecklistRow: View, Equatable {
    let item: SnapshotItem
    let answer: Observation?
    let findings: [Finding]
    let photoCount: Int

    let onSetAnswer: (AnswerValue) -> Void
    let onAddFinding: (Severity) -> Void
    let onEditFinding: (String, String) -> Void
    let onDeleteFinding: (String) -> Void

    /// Compares only what is rendered. The closures are recreated on every
    /// parent render and would otherwise make every row unequal, which would
    /// silently undo the whole optimisation.
    static func == (lhs: ChecklistRow, rhs: ChecklistRow) -> Bool {
        lhs.item == rhs.item
            && lhs.photoCount == rhs.photoCount
            && lhs.answer?.id == rhs.answer?.id
            && lhs.answer?.updatedAt == rhs.answer?.updatedAt
            && lhs.answer?.severity == rhs.answer?.severity
            && lhs.findings.map(\.id) == rhs.findings.map(\.id)
            && lhs.findings.map(\.updatedAt) == rhs.findings.map(\.updatedAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spaceM) {
            header

            ItemInput(item: item, answer: answer, onSetAnswer: onSetAnswer)

            if !findings.isEmpty {
                VStack(spacing: Metrics.spaceS) {
                    ForEach(findings) { finding in
                        FindingRow(
                            finding: finding,
                            onEdit: { onEditFinding(finding.id, $0) },
                            onDelete: { onDeleteFinding(finding.id) })
                    }
                }
            }

            footer
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.spaceL)
        .contentShape(Rectangle())
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spaceS) {
            Text(item.label)
                .font(.itemLabel)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)

            if item.required && answer == nil {
                // A dot, not the word "required" and not a red asterisk. Red is
                // reserved for safety findings; a neutral marker that
                // disappears when answered says the same thing without
                // borrowing the one colour that means danger.
                Circle()
                    .fill(Color.slate)
                    .frame(width: 5, height: 5)
                    .accessibilityLabel("Required")
            }

            Spacer(minLength: Metrics.spaceS)

            if let severity = answer?.severity {
                SeverityGlyph(severity: severity)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Metrics.spaceL) {
            Menu {
                ForEach(Severity.allCases.reversed(), id: \.self) { severity in
                    Button {
                        onAddFinding(severity)
                    } label: {
                        Label(severity.label, systemImage: severity.glyph)
                    }
                }
            } label: {
                Label("Add finding", systemImage: "plus")
                    .font(.figureSmall)
                    .foregroundStyle(Color.ink)
                    .frame(minHeight: Metrics.tapTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Add a finding to \(item.label)")

            if photoCount > 0 {
                Label("\(photoCount)", systemImage: "photo")
                    .font(.figureSmall)
                    .foregroundStyle(Color.slate)
                    .accessibilityLabel("\(photoCount) photos attached")
            }

            Spacer()

            if let helpText = item.helpText {
                HelpNote(text: helpText)
            }
        }
    }
}

/// Inspector guidance, shown inline rather than behind an info button.
///
/// The help on these items is liability-shaped — "Federal Pacific panels are a
/// safety finding on sight", "a missing TPR discharge line is a safety
/// finding". Hiding that behind a tap means it gets read once, during
/// onboarding, and never again at the moment it matters.
private struct HelpNote: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        Button { isExpanded.toggle() } label: {
            Image(systemName: isExpanded ? "info.circle.fill" : "info.circle")
                .font(.system(size: 17))
                .foregroundStyle(Color.slate)
                .frame(width: Metrics.tapTarget, height: Metrics.tapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Hide guidance" : "Show guidance")
        .popover(isPresented: $isExpanded) {
            Text(text)
                .font(.bodyField)
                .foregroundStyle(Color.ink)
                .padding(Metrics.spaceL)
                .frame(maxWidth: 320)
                .presentationCompactAdaptation(.popover)
        }
    }
}

// MARK: - Finding

private struct FindingRow: View {
    let finding: Finding
    let onEdit: (String) -> Void
    let onDelete: () -> Void

    @State private var draft: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.spaceM) {
            Rectangle()
                .fill(finding.severity.color)
                .frame(width: 3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Metrics.spaceS) {
                SeverityBadge(severity: finding.severity, showsLabel: true)

                TextField(
                    "Describe what you found",
                    text: $draft,
                    axis: .vertical)
                    .font(.bodyField)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1...8)
                    .focused($isFocused)
                    // Write-through on every keystroke. There is no Save button
                    // because there is nothing unsaved — a force-quit
                    // mid-sentence keeps the sentence.
                    .onChange(of: draft) { _, newValue in onEdit(newValue) }

                if let recommendation = finding.recommendation, !recommendation.isEmpty {
                    Text(recommendation)
                        .font(.caption)
                        .foregroundStyle(Color.slate)
                }
            }

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.slate)
                    .frame(width: Metrics.tapTarget, height: Metrics.tapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete this finding")
        }
        .padding(.vertical, Metrics.spaceS)
        .background(finding.severity.wash)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radius))
        .onAppear { draft = finding.narrative }
        // Adopt remote edits (a sync pull, another device) but never while the
        // inspector is typing into this field — yanking the cursor mid-word is
        // worse than a stale byte.
        .onChange(of: finding.narrative) { _, newValue in
            if !isFocused, newValue != draft { draft = newValue }
        }
    }
}
