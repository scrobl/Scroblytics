import SwiftUI
import SwiftData
import Observation

enum DetailNavigationOrigin: String {
    case overview = "Overview"
    case library = "Library"
    case topCharts = "Top Charts"
    case timeline = "Timeline"
    case milestones = "Milestones"
    case query = "Query"
    case trends = "Trends"
    case tools = "Tools"
}

/// Where a drill-down came from in ANOTHER tab (a Trends chart that opened a Query), so the breadcrumb can
/// read "Trends › Query › Artist › Album › Track" and every crumb — including the first — goes back.
struct DetailPredecessor: Sendable {
    /// The tab's name ("Trends").
    let source: String
    /// What was clicked, shown in the crumb's tooltip and the Query header ("Scrobbles · Mar 4 – Mar 10, 2026").
    let detail: String
    /// Switches back to that tab.
    let onReturn: @MainActor @Sendable () -> Void
}

@MainActor
@Observable
final class DetailNavigationCoordinator {
    private(set) var origin: DetailNavigationOrigin
    /// Overrides the origin crumb's text — a tool names itself ("Loved Status Audit") rather than the whole
    /// "Tools" tab, because the tool is the page a drill-down returns to.
    private(set) var originLabel: String?
    var path = NavigationPath()
    private var originDepth = 0
    /// Set when this stack was opened from another tab's chart; cleared once the user returns or dismisses it.
    var predecessor: DetailPredecessor?

    init(origin: DetailNavigationOrigin) {
        self.origin = origin
    }

    func setOrigin(_ origin: DetailNavigationOrigin, label: String? = nil) {
        self.origin = origin
        originLabel = label
        originDepth = path.count
    }

    var originTitle: String { originLabel ?? origin.rawValue }

    func goBack() {
        guard path.count > originDepth else { return }
        path.removeLast()
    }

    func goToOrigin() {
        guard path.count > originDepth else { return }
        path.removeLast(path.count - originDepth)
    }

    /// Back to the tab that opened this one. Clear the cross-tab stack so a later handoff starts cleanly.
    func returnToPredecessor() {
        guard let predecessor else { return }
        self.predecessor = nil
        path = NavigationPath()
        originDepth = 0
        predecessor.onReturn()
    }

    func goToArtist(_ artist: ArtistIdentity) {
        goToOrigin()
        path.append(artist)
    }

    func goToAlbum(_ album: AlbumIdentity) {
        goToOrigin()
        path.append(ArtistIdentity(name: album.artist))
        path.append(album)
    }

    func goToTrack(_ track: TrackIdentity) {
        goToOrigin()
        path.append(ArtistIdentity(name: track.artist))
        if let album = track.album {
            path.append(AlbumIdentity(artist: track.artist, name: album))
        }
        path.append(track)
    }
}

struct DetailBreadcrumbBar: View {
    let navigation: DetailNavigationCoordinator
    let artist: ArtistIdentity?
    let album: AlbumIdentity?
    let current: String

    var body: some View {
        HStack(spacing: 8) {
            Button(action: navigation.goBack) {
                Image(systemName: "chevron.left")
                    .font(AppTypography.navigationIcon)
                    .frame(width: 34, height: 34)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().stroke(.separator.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Back")

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if let predecessor = navigation.predecessor {
                        breadcrumbButton(predecessor.source) { navigation.returnToPredecessor() }
                            .help("Back to \(predecessor.detail)")
                        separator
                    }
                    breadcrumbButton(navigation.originTitle, action: navigation.goToOrigin)
                    if let artist {
                        separator
                        breadcrumbButton(artist.name) { navigation.goToArtist(artist) }
                    }
                    if let album {
                        separator
                        breadcrumbButton(album.name) { navigation.goToAlbum(album) }
                    }
                    separator
                    Text(current)
                        .font(AppTypography.compactTitle)
                        .lineLimit(1)
                }
            }
            .scrollIndicators(.hidden)
        }
        .accessibilityElement(children: .contain)
    }

    private var separator: some View {
        Image(systemName: "chevron.right")
            .font(AppTypography.denseBadge)
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    private func breadcrumbButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(.plain)
            .font(AppTypography.metadata)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// Shared artwork/identity/stats-grid block used by all three detail pages
/// (Artist/Album/Track) — factored out so the header only needs extending
/// once (Play frequency, mini-trend sparkline, Milestones, Chart positions
/// are all still to come) rather than three times in step with each other.
struct EntityStatsHeaderSection: View {
    @Environment(\.modelContext) private var modelContext
    @State private var effectiveImageURL: String?
    @State private var artworkRefreshID = UUID()
    let entity: TopChartsEntity
    let name: String
    /// Artist name, shown under `name` — nil only for an artist page itself.
    let subtitle: String?
    /// Album name, shown under `subtitle` — track pages only, and only when
    /// the track was reached by drilling through a specific album.
    let tertiary: String?
    let imageURL: String?
    let stats: EntityStats?
    let errorMessage: String?
    let metric: TopChartsMetric
    /// Non-nil only for album pages — adds "Fix album match…" to the artwork's
    /// right-click menu, always available (not gated on match status).
    var onFixAlbumMatch: (() -> Void)? = nil
    /// Resolved separately from `stats` (network on a cold Deezer cache) —
    /// nil while unresolved/loading, shown as its own tile once available.
    /// Not gated behind a Metric toggle here: unlike Top Charts/Overview
    /// totals (a list/single-number the toggle switches wholesale), a single
    /// entity's own page showing both Plays and Time Listened side by side
    /// is more useful than picking one.
    var timeListenedSeconds: Int? = nil
    /// This entity's rank among its kind in each past calendar year it
    /// charted top-25 — empty until `TopChartsEngine.fetchYearlyTopRanks`
    /// resolves (a separate, heavier fetch than `stats`, so it arrives on
    /// its own timeline rather than blocking the rest of the header).
    var yearlyTopRanks: [TopChartsEngine.YearlyRank] = []
    /// Non-nil only for track pages — shows the loved heart next to the
    /// title and makes it interactive. `stats.loved` (read from the locally
    /// synced set, always available with no extra network call) drives the
    /// icon's filled/outline state; artist/album pages never pass this,
    /// since Last.fm loves are track-scoped only.
    var onToggleLoved: (() -> Void)? = nil
    var isTogglingLoved: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            if let stats {
                statsGrid(stats)
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            if !yearlyTopRanks.isEmpty {
                yearlyTopRanksRow
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ColorWashView(
                imageURLs: [effectiveImageURL ?? imageURL].compactMap { $0 },
                strength: 0.78
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
        .task(id: imageTarget) { reloadImage() }
        .onReceive(NotificationCenter.default.publisher(for: .imageDidChange)) { notification in
            guard let changedTarget = notification.object as? ImageTarget,
                  changedTarget == imageTarget || imageTarget.kind == .track else { return }
            reloadImage()
        }
    }

    private var yearlyTopRanksRow: some View {
        TagFlowLayout(spacing: 6) {
            ForEach(yearlyTopRanks) { entry in
                HStack(spacing: 4) {
                    Image(systemName: "medal.fill").font(AppTypography.supportingDense)
                    Text("#\(entry.rank)").font(AppTypography.badge)
                    Text("· \(String(entry.year))").font(AppTypography.supportingDense).opacity(0.7)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .foregroundStyle(Color.purple)
                .background(Color.purple.opacity(0.15), in: Capsule())
            }
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                artwork
                identity
            }
            VStack(alignment: .leading, spacing: 12) {
                artwork
                identity
            }
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(name).font(AppTypography.entityTitle)
                PopularityMarker(entity: entity, name: name, artist: subtitle, font: .system(size: 13))
                if let onToggleLoved, let stats {
                    lovedHeartButton(loved: stats.loved, action: onToggleLoved)
                }
                if entity == .track {
                    TrackFlaggedIndicator(
                        artist: subtitle ?? "",
                        track: name,
                        font: AppTypography.entitySubtitle
                    )
                    TrackLibraryGapBadge(artist: subtitle ?? "", track: name, font: AppTypography.entitySubtitle)
                }
            }
            if let subtitle {
                Text(subtitle).font(AppTypography.entitySubtitle).foregroundStyle(.secondary)
            }
            if let tertiary {
                Text(tertiary).font(AppTypography.entityTertiary).foregroundStyle(.tertiary)
            }
        }
    }

    private func lovedHeartButton(loved: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: loved ? "heart.fill" : "heart")
                .font(AppTypography.entitySubtitle)
                .foregroundStyle(loved ? Color.red : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(isTogglingLoved || Connectivity.shared.isOffline)
        .help(Connectivity.shared.isOffline ? "Offline mode is on" : (loved ? "Unlove track" : "Love track"))
        .contextMenu {
            Button(loved ? "Unlove track" : "Love track", action: action)
        }
    }

    private var artwork: some View {
        ArtworkImage(urlString: effectiveImageURL ?? imageURL, contentMode: .fill) {
            Color.clear
                .overlay {
                    Image(systemName: imageTarget.kind == .artist ? "person.fill" : "music.note")
                        .font(.system(size: 44))
                        .foregroundStyle(.tertiary)
                }
        }
        .id(artworkRefreshID)
        .frame(width: AppArtworkSizing.tileMaximum, height: AppArtworkSizing.tileMaximum)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .entityContextMenu(
            target: imageTarget,
            currentImageURL: effectiveImageURL ?? imageURL,
            onFixAlbumMatch: onFixAlbumMatch,
            onImageRefreshed: { refreshedURL in
                effectiveImageURL = refreshedURL
                artworkRefreshID = UUID()
            }
        )
    }

    private func reloadImage() {
        effectiveImageURL = try? ImageResolutionEngine.effectiveImageURL(
            for: imageTarget,
            context: modelContext,
            fallbackURL: imageURL
        )
    }

    private var imageTarget: ImageTarget {
        switch entity {
        case .artist:
            return ImageTarget(kind: .artist, artist: name, album: nil, track: nil)
        case .album:
            return ImageTarget(kind: .album, artist: subtitle ?? "", album: name, track: nil)
        case .track:
            return ImageTarget(kind: .track, artist: subtitle ?? "", album: tertiary, track: name)
        }
    }

    private func statsGrid(_ stats: EntityStats) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                GridRow {
                    statTile(
                        label: metric == .scrobbles ? "Scrobbles" : "Time Listened",
                        value: metric == .scrobbles
                            ? stats.plays.formatted()
                            : timeListenedSeconds.map(DurationEngine.formatTimeListened) ?? "—"
                    )
                    statTile(label: "First scrobble", value: formatted(stats.firstScrobble))
                    statTile(label: "Last scrobble", value: formatted(stats.lastScrobble))
                    statTile(label: "Play frequency", value: formatPlayFrequency(stats.averageDaysBetweenPlays))
                }
            }
            if !stats.trend.isEmpty {
                TrendSparkline(buckets: stats.trend)
                    .frame(height: 40)
            }
            milestonesSection(stats.milestones)
        }
    }

    @ViewBuilder
    private func milestonesSection(_ milestones: MilestonesEngine.EntityMilestones) -> some View {
        if !milestones.achieved.isEmpty || milestones.upcoming != nil {
            VStack(alignment: .leading, spacing: 6) {
                if !milestones.achieved.isEmpty {
                    TagFlowLayout(spacing: 6) {
                        ForEach(Array(milestones.achieved.enumerated()), id: \.offset) { _, m in
                            milestoneBadge(m)
                        }
                    }
                }
                if let upcoming = milestones.upcoming {
                    HStack(spacing: 6) {
                        Text("\(upcoming.remaining) to \(MilestoneFormatting.formatMilestone(upcoming.next))")
                            .font(AppTypography.supporting).foregroundStyle(.secondary)
                        if let etaLabel = MilestoneFormatting.formatEtaDays(upcoming.etaDays) {
                            Text("· \(etaLabel)").font(AppTypography.supportingDense).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private func milestoneBadge(_ m: (milestone: Int, achievedAt: Date, firstAt: Date)) -> some View {
        let color = MilestoneFormatting.milestoneColor(m.milestone)
        let elapsedDays = m.achievedAt.timeIntervalSince(m.firstAt) / 86400
        return HStack(spacing: 4) {
            Image(systemName: "trophy.fill").font(AppTypography.supportingDense)
            Text(MilestoneFormatting.formatMilestone(m.milestone)).font(AppTypography.badge)
            Text("· \(formatted(m.achievedAt)) (\(MilestoneFormatting.formatElapsedDays(elapsedDays)))").font(AppTypography.supportingDense).opacity(0.7)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .foregroundStyle(color)
        .background(color.opacity(0.15), in: Capsule())
        .overlay(Capsule().stroke(MilestoneFormatting.isPrestigeMilestone(m.milestone) ? Color.accentColor : .clear, lineWidth: 1))
    }

    private func statTile(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(AppTypography.statLabel).foregroundStyle(.secondary)
            Text(value).font(AppTypography.statValue)
        }
    }

    private func formatted(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Formats an average gap between plays.
    private func formatPlayFrequency(_ avgDays: Double?) -> String {
        guard let avgDays else { return "—" }
        if avgDays < 1 { return "multiple times a day" }
        let days = avgDays < 10 ? String(format: "%.1f", avgDays) : "\(Int(avgDays.rounded()))"
        return "every \(days) days"
    }

}

/// Milestone formatting (`formatMilestone`/`milestoneTier`/
/// `isPrestigeMilestone`/`formatElapsedDays`/`formatEtaDays`) — shared by entity
/// headers, Timeline's month badges, and the Milestones page.
enum MilestoneFormatting {
    private static let milestoneThresholds = [100, 250, 500, 1000, 2500, 5000, 10000, 25000, 50000, 100000]
    private static let milestoneTierColors: [Color] = [.purple, .blue, .green, .yellow, .orange, .red, .pink]

    static func milestoneColor(_ milestone: Int) -> Color {
        if let index = milestoneThresholds.firstIndex(of: milestone), index < milestoneTierColors.count {
            return milestoneTierColors[index]
        }
        return .accentColor
    }

    static func isPrestigeMilestone(_ milestone: Int) -> Bool {
        guard let index = milestoneThresholds.firstIndex(of: milestone) else { return true }
        return index >= milestoneTierColors.count
    }

    static func formatMilestone(_ n: Int) -> String {
        if n >= 1000, n % 1000 == 0 { return "\(n / 1000)K" }
        return n.formatted()
    }

    static func formatElapsedDays(_ days: Double) -> String {
        let whole = max(0, Int(days.rounded(.down)))
        if whole < 14 { return "\(whole)d" }
        if whole < 60 { return "\(Int((Double(whole) / 7).rounded()))w" }
        if whole < 365 { return "\(Int((Double(whole) / 30).rounded()))mo" }
        let years = whole / 365
        let remMonths = Int((Double(whole - years * 365) / 30).rounded())
        if remMonths == 0 || years >= 3 { return "\(years)y" }
        return "\(years)y \(remMonths)mo"
    }

    static func formatEtaDays(_ days: Int?) -> String? {
        guard let days else { return nil }
        if days <= 0 { return "Any day now" }
        if days == 1 { return "~1 day to go" }
        return "~\(days.formatted()) days to go"
    }
}
