import SwiftUI
import TourGuideCore

/// The few different walks the slider holds, side by side (PRD §8.13). Numbers and sights are
/// ours; titles and sentences are Apple Intelligence's when this iPhone has it. Tap to walk it.
struct CompareWalksSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WalkDescriptionStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(store.walks.enumerated()), id: \.element.id) { i, w in
                        Button { model.choose(w); dismiss() } label: { row(w) }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("walk-\(i)")
                    }
                } header: {
                    // At the top, not the bottom: a lazy list never renders a footer below the
                    // fold at the medium detent, and "Describing walk 2 of 4…" belongs up here.
                    if !store.footer.isEmpty {
                        Label(store.footer, systemImage: "sparkles")
                            .font(.caption).foregroundStyle(.secondary).textCase(nil)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("compareFooter")
                    }
                }
            }
            .navigationTitle("Compare walks").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ w: WalkOption) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                if let t = store.title(w) {
                    Text(t).font(.headline)
                    Text(model.readout(for: w)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    // No title (no Apple Intelligence, or it's still writing): the numbers lead.
                    Text(model.readout(for: w)).font(.headline).monospacedDigit()
                    if case .describing = store.status {
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Naming…") }
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let text = store.blurbs[w.id]?.text, !text.isEmpty { Text(text).font(.callout) }
                if !w.tier1.isEmpty {
                    Text(w.tier1.map(\.name).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Spacer(minLength: 0)
            if model.isCurrent(w) {
                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
                    .accessibilityLabel("Current walk")
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}
