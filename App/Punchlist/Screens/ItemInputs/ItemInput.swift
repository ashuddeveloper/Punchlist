import PunchlistCore
import SwiftUI

// ============================================================================
// The eight data-entry controls.
//
// Common rules, applied to all of them:
//
//   * Every target is at least 56pt; repeated ones are 64pt. Gloves.
//   * Every control writes through on change. Nothing is staged, nothing is
//     committed later, and there is no Save button anywhere in the product.
//   * State is unambiguous at a glance in bad light: selected means filled and
//     outlined, not a 1pt tint difference.
//   * No control uses colour as its only signal, because severity owns colour.
// ============================================================================

struct ItemInput: View {
    let item: SnapshotItem
    let answer: Observation?
    let onSetAnswer: (AnswerValue) -> Void

    var body: some View {
        switch item.inputType {
        case .rating:
            RatingInput(options: item.options ?? [], selected: selectedIndex, onSelect: {
                onSetAnswer($0 == nil ? .cleared : .rating($0!))
            })
        case .bool:
            BoolInput(value: answer?.valueBool) { onSetAnswer($0 == nil ? .cleared : .bool($0!)) }
        case .select:
            SelectInput(options: item.options ?? [], selected: answer?.valueText) {
                onSetAnswer($0 == nil ? .cleared : .text($0!))
            }
        case .multiselect:
            MultiSelectInput(options: item.options ?? [], selected: Set(answer?.selectedOptions ?? [])) {
                onSetAnswer($0.isEmpty ? .cleared : .options(Array($0)))
            }
        case .text:
            TextInput(value: answer?.valueText ?? "") { onSetAnswer(.text($0)) }
        case .number:
            NumberInput(value: answer?.valueNumber, unit: item.unit) {
                onSetAnswer($0 == nil ? .cleared : .number($0!))
            }
        case .photoOnly:
            PhotoOnlyInput()
        case .signature:
            SignatureInput(hasSignature: answer?.valueText != nil) {
                onSetAnswer(.text($0))
            }
        }
    }

    private var selectedIndex: Int? {
        answer?.valueNumber.map { Int($0) }
    }
}

// MARK: - Rating

/// The scale used throughout the residential template.
///
/// Laid out as a row of equal-width buttons rather than a segmented control:
/// a `Picker(.segmented)` is 32pt tall, which is unusable through a glove, and
/// its selected state is a subtle fill that disappears in sunlight.
struct RatingInput: View {
    let options: [String]
    let selected: Int?
    let onSelect: (Int?) -> Void

    var body: some View {
        HStack(spacing: Metrics.spaceS) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                Button {
                    onSelect(selected == index ? nil : index)
                } label: {
                    Text(option)
                        .font(.figureSmall)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity, minHeight: Metrics.tapTargetRepeated)
                        .foregroundStyle(selected == index ? Color.paper : Color.ink)
                        .background(selected == index ? Color.ink : Color.field)
                        .overlay(
                            RoundedRectangle(cornerRadius: Metrics.radius)
                                .strokeBorder(Color.line, lineWidth: Metrics.rule))
                        .clipShape(RoundedRectangle(cornerRadius: Metrics.radius))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option)
                .accessibilityAddTraits(selected == index ? [.isSelected] : [])
            }
        }
    }
}

// MARK: - Bool

struct BoolInput: View {
    let value: Bool?
    let onChange: (Bool?) -> Void

    var body: some View {
        HStack(spacing: Metrics.spaceS) {
            choice(title: "Yes", isSelected: value == true) { onChange(value == true ? nil : true) }
            choice(title: "No", isSelected: value == false) { onChange(value == false ? nil : false) }
        }
    }

    private func choice(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.bodyFieldMedium)
                .frame(maxWidth: .infinity, minHeight: Metrics.tapTargetRepeated)
                .foregroundStyle(isSelected ? Color.paper : Color.ink)
                .background(isSelected ? Color.ink : Color.field)
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.radius)
                        .strokeBorder(Color.line, lineWidth: Metrics.rule))
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Select

/// A wrapping grid of options, all visible.
///
/// Not a dropdown. A `Picker` hides every option but the chosen one behind a
/// tap, which costs two interactions per answer and sixty-six items means a
/// hundred and thirty wasted taps per inspection.
struct SelectInput: View {
    let options: [String]
    let selected: String?
    let onSelect: (String?) -> Void

    var body: some View {
        FlowLayout(spacing: Metrics.spaceS) {
            ForEach(options, id: \.self) { option in
                Chip(title: option, isSelected: selected == option) {
                    onSelect(selected == option ? nil : option)
                }
            }
        }
    }
}

struct MultiSelectInput: View {
    let options: [String]
    let selected: Set<String>
    let onChange: (Set<String>) -> Void

    var body: some View {
        FlowLayout(spacing: Metrics.spaceS) {
            ForEach(options, id: \.self) { option in
                Chip(title: option, isSelected: selected.contains(option), isMulti: true) {
                    var next = selected
                    if next.contains(option) { next.remove(option) } else { next.insert(option) }
                    onChange(next)
                }
            }
        }
    }
}

private struct Chip: View {
    let title: String
    let isSelected: Bool
    var isMulti: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.spaceS) {
                if isMulti {
                    // A checkbox, so multi-select is distinguishable from
                    // single-select without reading the help text.
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 15))
                }
                Text(title).font(.figureSmall)
            }
            .padding(.horizontal, Metrics.spaceL)
            .frame(minHeight: Metrics.tapTarget)
            .foregroundStyle(isSelected ? Color.paper : Color.ink)
            .background(isSelected ? Color.ink : Color.field)
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radius)
                    .strokeBorder(Color.line, lineWidth: Metrics.rule))
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Text

struct TextInput: View {
    let value: String
    let onChange: (String) -> Void

    @State private var draft: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Notes", text: $draft, axis: .vertical)
            .font(.bodyField)
            .foregroundStyle(Color.ink)
            .lineLimit(1...10)
            .focused($isFocused)
            .padding(Metrics.spaceM)
            .frame(minHeight: Metrics.tapTarget, alignment: .topLeading)
            .background(Color.field)
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radius)
                    .strokeBorder(isFocused ? Color.ink : Color.line,
                                  lineWidth: isFocused ? 2 : Metrics.rule))
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radius))
            .onAppear { draft = value }
            .onChange(of: draft) { _, newValue in onChange(newValue) }
            .onChange(of: value) { _, newValue in
                // Accept an external change only when the field is idle. Moving
                // the cursor while someone is typing is worse than being a
                // keystroke behind.
                if !isFocused, newValue != draft { draft = newValue }
            }
    }
}

struct NumberInput: View {
    let value: Double?
    let unit: String?
    let onChange: (Double?) -> Void

    @State private var draft: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Metrics.spaceM) {
            TextField("—", text: $draft)
                .font(.figure)
                .foregroundStyle(Color.ink)
                // `.decimalPad`, not `.numberPad`: crack widths and temperature
                // differentials are fractional, and a keypad with no decimal
                // point makes an inspector round to the nearest inch.
                .keyboardType(.decimalPad)
                .focused($isFocused)
                .padding(Metrics.spaceM)
                .frame(maxWidth: 160, minHeight: Metrics.tapTarget, alignment: .leading)
                .background(Color.field)
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.radius)
                        .strokeBorder(isFocused ? Color.ink : Color.line,
                                      lineWidth: isFocused ? 2 : Metrics.rule))
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radius))

            if let unit {
                Text(unit).font(.bodyField).foregroundStyle(Color.slate)
            }
            Spacer()
        }
        .onAppear { draft = value.map(Self.format) ?? "" }
        .onChange(of: draft) { _, newValue in
            onChange(newValue.isEmpty ? nil : Double(newValue.replacingOccurrences(of: ",", with: ".")))
        }
        .onChange(of: value) { _, newValue in
            guard !isFocused else { return }
            let formatted = newValue.map(Self.format) ?? ""
            if formatted != draft { draft = formatted }
        }
    }

    /// Trailing ".0" on a whole number looks like a machine wrote the report.
    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

// MARK: - Photo only / signature

/// Some items have no value of their own — the answer *is* the photograph.
/// Crawlspace clearance is the canonical case: nobody wants a rating, they want
/// to see it.
struct PhotoOnlyInput: View {
    var body: some View {
        Text("Attach a photo from the tray, or shoot one now.")
            .font(.caption)
            .foregroundStyle(Color.slate)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SignatureInput: View {
    let hasSignature: Bool
    let onCapture: (String) -> Void
    @State private var isDrawing = false

    var body: some View {
        Button { isDrawing = true } label: {
            HStack(spacing: Metrics.spaceM) {
                Image(systemName: hasSignature ? "checkmark.seal" : "signature")
                    .font(.system(size: 18))
                Text(hasSignature ? "Signed — tap to re-sign" : "Tap to sign")
                    .font(.bodyFieldMedium)
                Spacer()
            }
            .foregroundStyle(Color.ink)
            .padding(.horizontal, Metrics.spaceL)
            .frame(minHeight: Metrics.tapTargetRepeated)
            .background(Color.field)
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radius)
                    .strokeBorder(Color.line, lineWidth: Metrics.rule))
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hasSignature ? "Signed. Tap to sign again" : "Tap to sign")
        .sheet(isPresented: $isDrawing) {
            SignatureCanvas { strokes in
                onCapture(strokes)
                isDrawing = false
            }
        }
    }
}
