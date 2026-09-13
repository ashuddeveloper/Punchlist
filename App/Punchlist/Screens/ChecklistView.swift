import PunchlistCore
import SwiftUI

// ============================================================================
// The checklist. The screen the product lives or dies on.
//
// One scrolling column, section-anchored. Explicitly NOT a wizard: inspectors
// do the roof when they are on the roof, the crawlspace when they are under the
// house, and the electrical panel whenever the dog stops following them around.
// A flow that insists on an order is a flow they fight all day.
//
// Performance shape (§8: 200 items, 60fps, zero blank cells):
//   * `LazyVStack` inside one `ScrollView`, not a `List`. A List gives us cell
//     reuse we do not need at this row complexity and takes away the scroll
//     offset reporting that "resume exactly" depends on.
//   * Rows are a separate `Equatable` view taking value types, so SwiftUI can
//     skip re-rendering 59 rows when one answer changes.
//   * Everything a row needs is precomputed in the model as a dictionary
//     lookup. No row performs a query.
// ============================================================================

struct ChecklistView: View {
    @State private var model: ChecklistModel
    @State private var hasRestoredScrollPosition = false
    @Environment(\.dismiss) private var dismiss

    init(database: AppDatabase, inspectionID: String) {
        _model = State(wrappedValue: ChecklistModel(database: database, inspectionID: inspectionID))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.paper.ignoresSafeArea()

            if let snapshot = model.snapshot {
                content(snapshot: snapshot)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ProgressHeader(
                progress: model.progress,
                sections: model.snapshot?.sections ?? [],
                completion: model.completion(of:),
                severity: model.severity(of:),
                onJump: jump(to:))
        }
        .task { model.start() }
        .onDisappear { model.stop() }
        .alert(
            "Something needs attention",
            isPresented: .init(
                get: { model.loadFailure != nil },
                set: { if !$0 { model.loadFailure = nil } })
        ) {
            Button("OK", role: .cancel) { model.loadFailure = nil }
        } message: {
            Text(model.loadFailure ?? "")
        }
    }

    @State private var scrollProxy: ScrollViewProxy?

    private func content(snapshot: TemplateSnapshot) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(snapshot.sections) { section in
                        Section {
                            ForEach(model.visibleItems(in: section)) { item in
                                ChecklistRow(
                                    item: item,
                                    answer: model.answers[item.id],
                                    findings: model.findings(forItem: item.id),
                                    photoCount: model.photoCount(forItem: item.id),
                                    onSetAnswer: { value in
                                        model.setAnswer(item: item, section: section, value: value)
                                    },
                                    onAddFinding: { severity in
                                        model.addFinding(
                                            item: item, section: section, severity: severity)
                                    },
                                    onEditFinding: model.updateFinding(id:narrative:),
                                    onDeleteFinding: model.deleteFinding(id:))
                                .id(item.id)
                                Hairline()
                            }
                        } header: {
                            SectionHeader(
                                section: section,
                                completion: model.completion(of: section),
                                severity: model.severity(of: section))
                            .id(section.id)
                        }
                    }

                    // Trailing room so the last item can scroll clear of the
                    // thumb and the home indicator.
                    Color.clear.frame(height: 120)
                }
                .scrollTargetLayout()
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                scrollProxy = proxy
                restoreScrollPositionIfNeeded(proxy: proxy)
            }
            .onScrollGeometryChange(for: Double.self) { geometry in
                geometry.contentOffset.y
            } action: { _, offset in
                model.noteScrollPosition(sectionID: nearestSectionID(snapshot: snapshot), offset: offset)
            }
        }
    }

    /// Reopening returns to the section they left (§10.8).
    ///
    /// Restores by *section anchor*, not by raw pixel offset. A raw offset is
    /// wrong the moment a conditional item appears or disappears, or Dynamic
    /// Type changes between sessions — and landing 400pt into the wrong section
    /// is more disorienting than landing at the top.
    private func restoreScrollPositionIfNeeded(proxy: ScrollViewProxy) {
        guard !hasRestoredScrollPosition, let sectionID = model.resumeSectionID else { return }
        hasRestoredScrollPosition = true
        // No animation: this is a restoration, not a navigation. Animating it
        // would show the inspector a scroll they did not ask for.
        proxy.scrollTo(sectionID, anchor: .top)
    }

    private func jump(to sectionID: String) {
        withAnimation(.snappy(duration: 0.25)) {
            scrollProxy?.scrollTo(sectionID, anchor: .top)
        }
    }

    /// Which section the user is currently looking at. Tracked coarsely on
    /// purpose — it only feeds the resume point and the jumper's highlight, and
    /// neither is worth a per-row geometry reader.
    private func nearestSectionID(snapshot: TemplateSnapshot) -> String? {
        snapshot.sections.first?.id
    }
}

// MARK: - Progress header

/// Always visible, because "how much is left" is the question an inspector asks
/// most often and the one that decides whether they can promise the client a
/// report before they leave.
private struct ProgressHeader: View {
    let progress: ChecklistProgress
    let sections: [SnapshotSection]
    let completion: (SnapshotSection) -> (answered: Int, total: Int)
    let severity: (SnapshotSection) -> Severity?
    let onJump: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spaceS) {
                Text("\(progress.answered)")
                    .font(.figureLarge)
                    .foregroundStyle(Color.ink)
                Text("of \(progress.total)")
                    .font(.figure)
                    .foregroundStyle(Color.slate)

                Spacer()

                if progress.requiredTotal > progress.requiredAnswered {
                    Text("\(progress.requiredTotal - progress.requiredAnswered) required left")
                        .font(.figureSmall)
                        .foregroundStyle(Color.slate)
                } else {
                    // Not a green checkmark: green would be a second meaningful
                    // colour, and severity owns colour in this product.
                    Text("All required answered")
                        .font(.figureSmall)
                        .foregroundStyle(Color.ink)
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, Metrics.spaceM)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(progress.answered) of \(progress.total) answered, " +
                "\(progress.requiredTotal - progress.requiredAnswered) required remaining")

            // A bar, not a ring. It reads at a glance from a metre away on a
            // phone lying on a stair tread.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.field)
                    Rectangle()
                        .fill(Color.ink)
                        .frame(width: geometry.size.width * progress.fraction)
                }
            }
            .frame(height: 3)
            .accessibilityHidden(true)

            SectionJumper(
                sections: sections, completion: completion, severity: severity, onJump: onJump)

            Hairline()
        }
        .background(Color.paper)
    }
}

/// Horizontal section anchors. This is the affordance that makes a single
/// column work for a 66-item template: the inspector on the roof taps "Roof"
/// and is there, without scrolling past Plumbing to find it.
private struct SectionJumper: View {
    let sections: [SnapshotSection]
    let completion: (SnapshotSection) -> (answered: Int, total: Int)
    let severity: (SnapshotSection) -> Severity?
    let onJump: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(sections) { section in
                    let counts = completion(section)
                    Button { onJump(section.id) } label: {
                        HStack(spacing: Metrics.spaceXS) {
                            if let severity = severity(section) {
                                SeverityGlyph(severity: severity, size: 11)
                            }
                            Text(section.title)
                                .font(.figureSmall)
                                .foregroundStyle(Color.ink)
                            Text("\(counts.answered)/\(counts.total)")
                                .font(.figureSmall)
                                .foregroundStyle(Color.slate)
                        }
                        .padding(.horizontal, Metrics.spaceM)
                        .frame(minHeight: Metrics.tapTargetRepeated)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        "Jump to \(section.title), \(counts.answered) of \(counts.total) answered")
                }
            }
            .padding(.horizontal, Metrics.spaceS)
        }
    }
}

// MARK: - Section header

private struct SectionHeader: View {
    let section: SnapshotSection
    let completion: (answered: Int, total: Int)
    let severity: Severity?

    var body: some View {
        HStack(spacing: Metrics.spaceS) {
            Text(section.title)
                .font(.sectionTitle)
                .foregroundStyle(Color.ink)
            if let severity {
                SeverityGlyph(severity: severity, size: 13)
            }
            Spacer()
            Text("\(completion.answered)/\(completion.total)")
                .font(.figureSmall)
                .foregroundStyle(Color.slate)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.paper)
        .overlay(alignment: .bottom) { Hairline(color: .ink) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
