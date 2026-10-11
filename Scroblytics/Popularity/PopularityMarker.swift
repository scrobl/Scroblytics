import SwiftUI

/// The popularity indicator — a small filled diamond shown inline next to an
/// entity's name when it clears the top quartile on at least one tier.
///
/// Deliberately a diamond, not a dot: Apple Music's own popular-dot convention
/// is the design inspiration, but this is Last.fm + Deezer data ranked within
/// the user's own library, so an identical dot would misleadingly imply the
/// same signal. (Not a star, flame, trophy/arrow, asterisk or underline either
/// — each already means something else in this app.)
///
/// Two tiers share one shape and differ by color: library-wide (the larger
/// claim, so it wins when both apply) and artist-scoped. Renders nothing while
/// the entity's popularity is unresolved or doesn't qualify — never blocks or
/// reserves space.
struct PopularityMarker: View {
    @Environment(PopularityStore.self) private var store

    let lookup: PopularityLookup?
    var font: Font = .system(size: 9)

    @State private var showsDetail = false
    @State private var hoverTask: Task<Void, Never>?

    init(lookup: PopularityLookup?, font: Font = .system(size: 9)) {
        self.lookup = lookup
        self.font = font
    }

    init(entity: TopChartsEntity, entry: TopChartEntry, font: Font = .system(size: 9)) {
        self.init(lookup: PopularityLookup(entity: entity, entry: entry), font: font)
    }

    /// For the detail-page header, which carries a name and (for album/track
    /// pages) the artist as its subtitle.
    init(entity: TopChartsEntity, name: String, artist: String?, font: Font = .system(size: 9)) {
        switch entity {
        case .artist: self.init(lookup: .artist(name), font: font)
        case .album: self.init(lookup: artist.map { .album(artist: $0, name: name) }, font: font)
        case .track: self.init(lookup: artist.map { .track(artist: $0, name: name) }, font: font)
        }
    }

    static let libraryColor = Color.teal
    static let artistColor = Color.orange

    var body: some View {
        if let lookup, let indicator = store.snapshot.indicator(forKey: lookup.key), indicator.isPopular {
            Image(systemName: "diamond.fill")
                .font(font)
                .foregroundStyle(indicator.libraryPopular ? Self.libraryColor : Self.artistColor)
                .padding(4)
                .contentShape(Rectangle())
                .accessibilityLabel(indicator.libraryPopular ? "Popular in your library" : "Popular for this artist")
                .onHover { hovering in
                    hoverTask?.cancel()
                    if hovering {
                        hoverTask = Task {
                            try? await Task.sleep(for: .milliseconds(350))
                            guard !Task.isCancelled else { return }
                            showsDetail = true
                        }
                    } else {
                        showsDetail = false
                    }
                }
                .popover(isPresented: $showsDetail, arrowEdge: .top) {
                    if let detail = store.snapshot.detail(forKey: lookup.key) {
                        PopularityTooltip(
                            detail: detail, artist: lookup.artist,
                            resolvingCount: store.remaining
                        )
                    }
                }
        }
    }
}

/// The hover breakdown: BOTH tiers always — each tier's actual percentile, not
/// a pass/fail — plus which tier is driving the diamond's color, and the raw
/// signals behind the numbers.
private struct PopularityTooltip: View {
    let detail: PopularityDetail
    let artist: String
    let resolvingCount: Int

    private var kindPlural: String {
        switch detail.kind {
        case .artist: "artists"
        case .album: "albums"
        case .track: "tracks"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(AppTypography.sectionTitle)
                HStack(spacing: 5) {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(detail.libraryPopular ? PopularityMarker.libraryColor : PopularityMarker.artistColor)
                    Text(colorExplanation)
                        .font(AppTypography.compactMetadata)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                tierRow(
                    title: "Library-wide",
                    combined: detail.libraryCombined, cutoff: detail.libraryCutoff,
                    pool: detail.libraryPool, popular: detail.libraryPopular
                )
                if detail.hasArtistTier {
                    if detail.artistPoolIsSufficient {
                        tierRow(
                            title: "Within \(artist)’s catalog",
                            combined: detail.artistCombined, cutoff: detail.artistCutoff,
                            pool: detail.artistPool, popular: detail.artistPopular
                        )
                    } else {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Within \(artist)’s catalog").font(AppTypography.metadata)
                            Text("Not enough of this artist’s catalog to compare (\(detail.artistPool) of \(detail.artistMinPool) \(kindPlural) needed)")
                                .font(AppTypography.compactMetadata)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider()

            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow {
                    Text("Signal").gridColumnAlignment(.leading)
                    Text("Value")
                    Text("Library")
                    if detail.hasArtistTier { Text("Artist") }
                }
                .font(AppTypography.supportingDense)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)

                ForEach(detail.fields, id: \.field) { row in
                    GridRow {
                        Text(row.field.label).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                        Text(row.value.formatted()).fontWeight(.medium)
                        Text(percentText(row.libraryPercentile)).foregroundStyle(.secondary)
                        if detail.hasArtistTier {
                            Text(row.artistPercentile.map(percentText) ?? "—").foregroundStyle(.secondary)
                        }
                    }
                    .font(AppTypography.compactMetadata)
                    .monospacedDigit()
                }
            }

            if resolvingCount > 0 {
                Text("Still resolving \(resolvingCount.formatted()) more items — these percentiles may shift as the rest of your library fills in.")
                    .font(AppTypography.supportingDense)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
    }

    private var headline: String {
        if detail.libraryPopular { return "Popular in your library" }
        if detail.artistPopular { return "Popular for \(artist)" }
        return "Popularity breakdown"
    }

    private var colorExplanation: String {
        if detail.libraryPopular && detail.artistPopular {
            return "Library-wide tier is driving this color (it also qualifies within \(artist)’s catalog)"
        }
        if detail.libraryPopular { return "Library-wide tier is driving this color" }
        return "Artist-scoped tier is driving this color (not popular library-wide)"
    }

    private func tierRow(title: String, combined: Double?, cutoff: Double?, pool: Int, popular: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(title).font(AppTypography.metadata)
                Spacer(minLength: 8)
                Text(combined.map { "\(ordinal($0)) percentile" } ?? "—")
                    .font(AppTypography.metadata.weight(.semibold))
                    .monospacedDigit()
            }
            if let cutoff {
                Text("\(popular ? "Popular" : "Not popular") — popular from the \(ordinal(cutoff)) up, of \(pool.formatted()) \(kindPlural)")
                    .font(AppTypography.compactMetadata)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func percentText(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    /// "94th" — the combined score is the mean of the per-signal percentile
    /// ranks, shown as a percentile as the PRD words it.
    private func ordinal(_ fraction: Double) -> String {
        let n = Int((fraction * 100).rounded())
        let suffix: String
        switch (n % 100, n % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }
}
