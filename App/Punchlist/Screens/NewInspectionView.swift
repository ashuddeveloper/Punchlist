import PunchlistCore
import SwiftUI

// ============================================================================
// Starting an inspection.
//
// §10.1: three taps from app open to first photo. So this screen asks for
// exactly one thing — the address — and nothing else is required. Client name,
// year built and square footage are all recorded later, from the inspection
// itself, because standing in a driveway with a client waiting is the worst
// possible moment to fill in a form.
// ============================================================================

/// Applies focus only to the field that asked for it, so a shared row builder
/// does not need a separate FocusState per field.
private struct ConditionalFocus: ViewModifier {
    let isTarget: Bool
    let binding: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if isTarget { content.focused(binding) } else { content }
    }
}

struct NewInspectionView: View {
    let environment: AppEnvironment
    let onCreated: (String) -> Void

    @State private var address = ""
    @State private var city = ""
    @State private var region = ""
    @State private var clientName = ""
    @State private var failure: String?
    @FocusState private var addressFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.paper.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: Metrics.spaceXL) {
                        field(label: "Address", text: $address, focused: true)
                        HStack(spacing: Metrics.spaceM) {
                            field(label: "City", text: $city)
                            field(label: "State", text: $region)
                        }
                        field(label: "Client name (optional)", text: $clientName)

                        Text("""
                            Everything else — year built, square footage, weather — you can \
                            record from the checklist while you walk.
                            """)
                            .font(.caption)
                            .foregroundStyle(Color.slate)
                    }
                    .padding(Metrics.gutter)
                }
            }
            .navigationTitle("New inspection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start", action: create)
                        .fontWeight(.semibold)
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { addressFocused = true }
            .alert("That inspection could not be started",
                   isPresented: .init(get: { failure != nil },
                                      set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil }
            } message: {
                Text(failure ?? "")
            }
        }
    }

    private func field(label: String, text: Binding<String>, focused: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spaceS) {
            Text(label).fieldLabel()
            TextField("", text: text)
                .font(.bodyField)
                .foregroundStyle(Color.ink)
                .textInputAutocapitalization(.words)
                .padding(Metrics.spaceM)
                .frame(minHeight: Metrics.tapTarget)
                .background(Color.field)
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.radius)
                        .strokeBorder(Color.line, lineWidth: Metrics.rule))
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radius))
                // Only the address is focused on open. It is the one required
                // field, and raising the keyboard onto it saves a tap in a
                // flow budgeted at three.
                .modifier(ConditionalFocus(isTarget: focused, binding: $addressFocused))
        }
    }

    private func create() {
        do {
            let id = try InspectionRepository(database: environment.database).create(
                orgID: environment.orgID,
                inspectorID: environment.inspectorID,
                templateID: environment.templateID,
                property: NewProperty(
                    address1: address.trimmingCharacters(in: .whitespaces),
                    city: city.isEmpty ? nil : city,
                    region: region.isEmpty ? nil : region),
                clientName: clientName.isEmpty ? nil : clientName,
                scheduledAt: Clock.nowMillis())
            onCreated(id)
            dismiss()
        } catch {
            failure = "Check that this phone has free space, then try again."
        }
    }
}
