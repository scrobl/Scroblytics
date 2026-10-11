import SwiftUI
import SwiftData

/// The confirmation step for `StaleRecordReconciler`: nothing changes until Apply is pressed.
struct StaleRecordReviewView: View {
    @Bindable var model: StaleRecordReviewModel
    let modelContainer: ModelContainer
    let onClose: () -> Void

    private var approvedCount: Int { model.plan.items.filter(\.approved).count }
    private var hasAnythingToApply: Bool {
        approvedCount > 0 || (model.removeUnused && !model.plan.unusedLabels.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review Stale Records").font(AppTypography.sectionTitle)
                Text("When a scrobble is corrected on Last.fm, the corrected scrobbles sync but anything you saved against the old album or track — a match decision, a release date, a duration, an image — stays behind on a record nothing plays under anymore. Nothing changes until you press Apply.")
                    .font(AppTypography.supporting).foregroundStyle(.secondary)
            }

            if model.isRefreshing && !model.hasLoaded {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            } else if let error = model.errorMessage {
                Text(error).font(AppTypography.supporting).foregroundStyle(.red)
            } else if model.plan.isEmpty && model.plan.leftAlone.isEmpty {
                ContentUnavailableView("Nothing to review", systemImage: "checkmark.circle",
                                       description: Text("Every album and track record has scrobbles behind it."))
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !model.plan.items.isEmpty { movesSection }
                        if !model.plan.unusedLabels.isEmpty { unusedSection }
                        if !model.plan.leftAlone.isEmpty { leftAloneSection }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 220, maxHeight: 420)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.markDismissed(); onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    model.apply(container: modelContainer)
                    if model.errorMessage == nil { onClose() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasAnythingToApply)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
    }

    private var movesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Move saved data to the record that replaced it").font(AppTypography.contentTitle)
            ForEach($model.plan.items) { $item in
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $item.approved) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(item.kind == .album ? "Album" : "Track"): \(item.staleArtist) — \(item.staleTitle)")
                                .font(AppTypography.metadata.weight(.semibold))
                            Text("Holds: \(item.holds.joined(separator: ", ")). Has no plays.")
                                .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                        }
                    }
                    if item.candidates.count > 1 {
                        Picker("Move to", selection: $item.chosen) {
                            ForEach(Array(item.candidates.enumerated()), id: \.element.id) { index, candidate in
                                Text("\(candidate.artist) — \(candidate.title) (\(candidate.plays) plays)").tag(index)
                            }
                        }
                        .disabled(!item.approved)
                        .padding(.leading, 20)
                    }
                    if let candidate = item.candidates[safe: item.chosen] {
                        VStack(alignment: .leading, spacing: 1) {
                            if item.candidates.count == 1 {
                                Text("→ \(candidate.artist) — \(candidate.title) (\(candidate.plays) plays)")
                            }
                            if !candidate.moves.isEmpty { Text("Moves: \(candidate.moves.joined(separator: ", "))") }
                            if !candidate.superseded.isEmpty {
                                Text("Already set on the new record, so the old \(candidate.superseded.joined(separator: ", ")) is dropped")
                            }
                            Text("The old record is then removed.")
                        }
                        .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                        .padding(.leading, 20)
                        .opacity(item.approved ? 1 : 0.45)
                    }
                }
            }
        }
    }

    private var unusedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $model.removeUnused) {
                Text("Also remove \(model.plan.unusedLabels.count) unused record\(model.plan.unusedLabels.count == 1 ? "" : "s") that hold nothing saved")
                    .font(AppTypography.contentTitle)
            }
            Text("No scrobbles and no overrides, match decisions or images — they only show up as duplicates in search.")
                .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            DisclosureGroup("Show records") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.plan.unusedLabels.prefix(50), id: \.self) { Text($0).font(AppTypography.compactMetadata) }
                    if model.plan.unusedLabels.count > 50 {
                        Text("…and \(model.plan.unusedLabels.count - 50) more").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(AppTypography.compactMetadata)
        }
    }

    private var leftAloneSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Saved data with no likely replacement (left as is)").font(AppTypography.contentTitle)
            ForEach(model.plan.leftAlone, id: \.self) { Text($0).font(AppTypography.compactMetadata).foregroundStyle(.secondary) }
        }
    }
}
