import PunchlistCore
import SwiftUI

// ============================================================================
// Signature capture.
//
// Strokes are stored as **vector points**, not as a rasterised image, for the
// same reason photo annotation is non-destructive: the report renders the
// signature at whatever resolution the page needs, so it stays crisp in a
// printed PDF instead of being a 300px PNG scaled up to a signature line.
//
// It also keeps the row small. A rasterised signature is tens of kilobytes in
// the database; this is a few hundred bytes.
// ============================================================================

/// The stored form. Points are normalised to the 0...1 box so the signature is
/// resolution- and orientation-independent.
struct SignatureStrokes: Codable, Sendable, Equatable {
    struct Point: Codable, Sendable, Equatable {
        let x: Double
        let y: Double
    }
    var strokes: [[Point]]

    var isEmpty: Bool { strokes.allSatisfy(\.isEmpty) }
}

struct SignatureCanvas: View {
    let onCapture: (String) -> Void

    @State private var strokes: [[CGPoint]] = []
    @State private var current: [CGPoint] = []
    @State private var canvasSize: CGSize = .zero
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                    .font(.bodyField)
                    .frame(minHeight: Metrics.tapTarget)
                Spacer()
                Button("Clear") { strokes = []; current = [] }
                    .font(.bodyField)
                    .frame(minHeight: Metrics.tapTarget)
                    .disabled(strokes.isEmpty && current.isEmpty)
            }
            .foregroundStyle(Color.ink)
            .padding(.horizontal, Metrics.gutter)

            Hairline()

            GeometryReader { geometry in
                ZStack {
                    Color.field

                    Path { path in
                        for stroke in strokes + (current.isEmpty ? [] : [current]) {
                            guard let first = stroke.first else { continue }
                            path.move(to: first)
                            for point in stroke.dropFirst() { path.addLine(to: point) }
                        }
                    }
                    .stroke(Color.ink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                    // The signature line. Present because people sign *on* a
                    // line; without it they sign in the middle of a grey box
                    // and it reads as a doodle.
                    VStack {
                        Spacer()
                        Hairline(color: .slate)
                            .padding(.horizontal, Metrics.spaceXXL)
                            .padding(.bottom, Metrics.spaceXXL)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in current.append(value.location) }
                        .onEnded { _ in
                            if !current.isEmpty { strokes.append(current) }
                            current = []
                        }
                )
                .onAppear { canvasSize = geometry.size }
                .onChange(of: geometry.size) { _, newValue in canvasSize = newValue }
            }

            Hairline()

            Button {
                capture()
            } label: {
                Text("Use this signature")
                    .font(.bodyFieldMedium)
                    .frame(maxWidth: .infinity, minHeight: Metrics.tapTargetRepeated)
                    .foregroundStyle(Color.paper)
                    .background(Color.ink)
            }
            .buttonStyle(.plain)
            .disabled(strokes.isEmpty)
            .opacity(strokes.isEmpty ? 0.4 : 1)
            .padding(Metrics.gutter)
        }
        .background(Color.paper)
    }

    private func capture() {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        let normalised = SignatureStrokes(strokes: strokes.map { stroke in
            stroke.map {
                SignatureStrokes.Point(
                    x: Double($0.x / canvasSize.width),
                    y: Double($0.y / canvasSize.height))
            }
        })
        guard let json = try? CanonicalJSON.encode(normalised) else { return }
        onCapture(json)
        dismiss()
    }
}
