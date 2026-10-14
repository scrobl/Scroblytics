import SwiftUI

/// Entities one scrobble away from their
/// next milestone, shown at the top of Overview. Hidden when there are none.
struct AlmostMilestonesSection: View {
    let milestones: [MilestoneUpcoming]
    let columnCount: Int

    /// The most cards ever shown: three columns by two rows.
    static let maxCards = 6
    static let maxRows = 2
    private static let threeColumnsFrom: CGFloat = 900
    private static let twoColumnsFrom: CGFloat = 640

    /// Columns for the width Overview has: three when it is wide, two, then one. The rows never go past two, so a narrower window
    /// shows fewer cards (the closest ones) instead of a taller strip.
    static func columnCount(forWidth width: CGFloat) -> Int {
        if width >= threeColumnsFrom { return 3 }
        if width >= twoColumnsFrom { return 2 }
        return 1
    }

    /// How many of the given cards fit in `columns` columns of at most two rows.
    static func visibleCount(of total: Int, columns: Int) -> Int {
        min(total, max(1, columns) * maxRows, maxCards)
    }

    var body: some View {
        let shown = Array(milestones.prefix(Self.visibleCount(of: milestones.count, columns: columnCount)))
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Almost there", systemImage: "target")
                    .font(AppTypography.sectionTitle)
                    .foregroundStyle(.secondary)
                // Every card the same height (a long title can push a badge under it), in a set number of columns.
                EvenGridLayout(minimumWidth: 0, spacing: 12, fixedColumns: columnCount) {
                    ForEach(shown) { item in
                        MilestoneEntityLink(entity: item.entity, name: item.name, artist: item.artist, album: item.album, imageURL: item.imageURL) {
                            card(item)
                        }
                    }
                }
            }
        }
    }

    private static func roleLabel(_ entity: TopChartsEntity) -> String {
        switch entity {
        case .artist: return "Artist"
        case .album: return "Album"
        case .track: return "Track"
        }
    }

    private func card(_ item: MilestoneUpcoming) -> some View {
        HStack(spacing: 12) {
            EntityThumbnail(url: item.imageURL, entity: item.entity)
                .frame(width: AppArtworkSizing.thumbnail, height: AppArtworkSizing.thumbnail)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    cardDetails(item)
                    Spacer(minLength: 0)
                    MilestoneRemainingBadge(remaining: item.remaining, next: item.next)
                }
                VStack(alignment: .leading, spacing: 6) {
                    cardDetails(item)
                    MilestoneRemainingBadge(remaining: item.remaining, next: item.next)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    private func cardDetails(_ item: MilestoneUpcoming) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Self.roleLabel(item.entity)).font(AppTypography.supporting).foregroundStyle(.tertiary)
            HStack(spacing: 4) {
                Text(item.name).font(AppTypography.contentTitle).lineLimit(1)
                TrackLovedIndicator(
                    artist: item.artist ?? "", track: item.name, initialValue: false,
                    font: AppTypography.supporting, enabled: item.entity == .track
                )
            }
            if let artist = item.artist, item.entity != .artist {
                Text(artist).font(AppTypography.supporting).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

}

struct MilestoneRemainingBadge: View {
    let remaining: Int
    let next: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "target").font(AppTypography.supportingDense)
            Text("\(remaining) to \(MilestoneFormatting.formatMilestone(next))")
                .font(AppTypography.badge.monospacedDigit())
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(.white)
        .background(Color.accentColor.opacity(0.7), in: Capsule())
    }
}

/// Dismissible callouts for
/// what recent syncs crossed. Persist until dismissed (see `PendingSyncEventsStore`).
struct PendingSyncEventBanners: View {
    @Environment(PendingSyncEventsStore.self) private var store

    var body: some View {
        if !store.milestones.isEmpty || !store.turnovers.isEmpty {
            VStack(spacing: 8) {
                if !store.milestones.isEmpty {
                    callout(
                        systemImage: "trophy.fill",
                        iconColor: .orange,
                        title: store.milestones.count == 1 ? "Milestone reached!" : "\(store.milestones.count) milestones reached!",
                        lines: store.milestones.map(Self.milestoneLabel),
                        dismissLabel: "Dismiss milestone banner",
                        onDismiss: store.dismissMilestones
                    )
                }
                if !store.turnovers.isEmpty {
                    callout(
                        systemImage: "repeat",
                        iconColor: .green,
                        title: store.turnovers.count == 1 ? "Album turned over!" : "\(store.turnovers.count) albums turned over!",
                        lines: store.turnovers.map { "\($0.artist) — \($0.album) (\(AlbumTurnoverEngine.formatTurnoverRate($0.rateDays)))" },
                        dismissLabel: "Dismiss album turnover banner",
                        onDismiss: store.dismissTurnovers
                    )
                }
            }
        }
    }

    /// One line of banner copy per milestone kind.
    static func milestoneLabel(_ m: NewMilestone) -> String {
        let count = MilestoneFormatting.formatMilestone(m.milestone)
        switch m.kind {
        case .total: return "\(count) total scrobbles"
        case .artist: return "\(m.name) — \(count) scrobbles"
        case .album, .track:
            let subject = m.artist.map { "\($0) — \(m.name)" } ?? m.name
            return "\(subject) — \(count) scrobbles"
        }
    }

    private func callout(
        systemImage: String,
        iconColor: Color,
        title: String,
        lines: [String],
        dismissLabel: String,
        onDismiss: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(iconColor)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(AppTypography.contentTitle)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text("• \(line)").font(AppTypography.supporting).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(AppTypography.supporting.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .help(dismissLabel)
            .accessibilityLabel(dismissLabel)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
    }
}
