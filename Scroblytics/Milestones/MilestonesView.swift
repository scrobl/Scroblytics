import SwiftUI
import SwiftData

private enum MilestoneCategoryID: String, CaseIterable, Identifiable {
    case total, artists, albums, tracks
    var id: String { rawValue }
    var label: String {
        switch self {
        case .total: return "Total"
        case .artists: return "Artists"
        case .albums: return "Albums"
        case .tracks: return "Tracks"
        }
    }
}

/// Tier filter: one chip per colored threshold (100 through 10K),
/// plus a combined "25K+" prestige chip.
private enum MilestoneTierFilter: Hashable {
    case all
    case threshold(Int)
    case prestige

    static let options: [MilestoneTierFilter] =
        [100, 250, 500, 1000, 2500, 5000, 10000].map { .threshold($0) } + [.prestige]

    func matches(_ milestone: Int) -> Bool {
        switch self {
        case .all: return true
        case .prestige: return MilestoneFormatting.isPrestigeMilestone(milestone)
        case .threshold(let t): return milestone == t
        }
    }

    var label: String {
        switch self {
        case .all: return "All"
        case .prestige: return "25K+"
        case .threshold(let t): return MilestoneFormatting.formatMilestone(t)
        }
    }

    var dotColor: Color {
        switch self {
        case .all, .prestige: return .accentColor
        case .threshold(let t): return MilestoneFormatting.milestoneColor(t)
        }
    }
}

/// Scrobble-count milestones for total plays
/// and every artist/album/track, split into Upcoming (progress toward the next
/// threshold, capped at 60 per category) and Achieved (one row per threshold
/// crossed). Pure listing UI over `MilestonesEngine.fetch` — the same engine
/// Overview's card and the detail headers already use.
struct MilestonesView: View {
    let modelContainer: ModelContainer
    let settings: ChartDateSettings
    let isActive: Bool

    @Environment(\.modelContext) private var modelContext
    @State private var navigation = DetailNavigationCoordinator(origin: .milestones)
    @State private var result: MilestonesResult?
    @State private var errorMessage: String?
    @State private var category: MilestoneCategoryID = .total
    @State private var tierFilter: MilestoneTierFilter = .all
    @State private var hasLoaded = false
    @State private var needsReload = false
    @State private var latestRequestID = UUID()

    // Keep milestone cards broad enough for the artwork, title, progress, and
    // status metadata to read as one horizontal unit.
    private static let gridColumns = [
        GridItem(.adaptive(minimum: 380), spacing: 16)
    ]

    var body: some View {
        NavigationStack(path: Binding(
            get: { navigation.path },
            set: { navigation.path = $0 }
        )) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Milestones")
                        .font(AppTypography.pageTitle)
                    content
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Milestones")
            .navigationDestination(for: ArtistIdentity.self) { ArtistDetailView(identity: $0, settings: settings, navigation: navigation) }
            .navigationDestination(for: AlbumIdentity.self) { AlbumDetailView(identity: $0, settings: settings, navigation: navigation) }
            .navigationDestination(for: TrackIdentity.self) { TrackDetailView(identity: $0, settings: settings, navigation: navigation) }
        }
        .task(id: isActive) { await loadIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in requestReload() }
        .onReceive(NotificationCenter.default.publisher(for: .imageDidChange)) { _ in requestReload() }
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage, result == nil {
            ContentUnavailableView("Failed to load milestones", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
        } else if let result {
            if result.total.current == 0 {
                HistoryEmptyState {
                    ContentUnavailableView(
                        "No listening history yet", systemImage: "trophy",
                        description: Text("Sync your Last.fm history to start tracking milestones.")
                    )
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Category", selection: $category) {
                        ForEach(MilestoneCategoryID.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    tierFilterBar(result)
                    categoryBody(result)
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    // MARK: - Tier filter

    /// Every milestone value in the current category (upcoming `next` +
    /// achieved), before filtering — drives the chip counts.
    private func tierValues(_ result: MilestonesResult) -> [Int] {
        switch category {
        case .total:
            return (result.total.upcoming.map { [$0.next] } ?? []) + result.total.achieved.map(\.milestone)
        case .artists, .albums, .tracks:
            let data = entityCategory(result)
            return data.upcoming.map(\.next) + data.achieved.map(\.milestone)
        }
    }

    private func tierFilterBar(_ result: MilestonesResult) -> some View {
        let values = tierValues(result)
        return TagFlowLayout(spacing: 4) {
            tierChip(.all, count: values.count)
            Rectangle().fill(.separator).frame(width: 1, height: 16).padding(.horizontal, 4)
            ForEach(MilestoneTierFilter.options, id: \.self) { option in
                tierChip(option, count: values.filter(option.matches).count)
            }
        }
    }

    private func tierChip(_ option: MilestoneTierFilter, count: Int) -> some View {
        let selected = tierFilter == option
        return Button {
            tierFilter = option
        } label: {
            HStack(spacing: 5) {
                if option != .all {
                    Circle().fill(option.dotColor).frame(width: 7, height: 7)
                }
                Text(option.label).font(AppTypography.compactTitle)
                Text(count.formatted())
                    .font(AppTypography.denseBadge.monospacedDigit())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(selected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05), in: Capsule())
            .overlay(Capsule().stroke(selected ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
            .contentShape(Capsule())
            // The flow layout proposes a squeezed width; keep each chip at its
            // natural size so the counts never truncate.
            .fixedSize()
        }
        .buttonStyle(.plain)
    }

    // MARK: - Category bodies

    private func entityCategory(_ result: MilestonesResult) -> MilestoneCategory {
        switch category {
        case .artists: return result.artists
        case .albums: return result.albums
        case .tracks, .total: return result.tracks
        }
    }

    private var entity: TopChartsEntity {
        switch category {
        case .artists: return .artist
        case .albums: return .album
        case .tracks, .total: return .track
        }
    }

    @ViewBuilder
    private func categoryBody(_ result: MilestonesResult) -> some View {
        let filtered = tierFilter != .all
        if category == .total {
            let upcoming = result.total.upcoming.flatMap { tierFilter.matches($0.next) ? $0 : nil }
            let achieved = result.total.achieved.filter { tierFilter.matches($0.milestone) }
            section("Upcoming", count: upcoming == nil ? 0 : 1,
                    empty: filtered ? "No upcoming milestone matches this filter." : "No upcoming milestone.") {
                if let upcoming {
                    TotalUpcomingCard(current: result.total.current, next: upcoming.next, remaining: upcoming.remaining, etaDays: upcoming.etaDays)
                }
            }
            section("Achieved", count: achieved.count,
                    empty: filtered ? "No achieved milestones match this filter." : "No milestones reached yet — keep listening!") {
                LazyVGrid(columns: Self.gridColumns, alignment: .leading, spacing: 16) {
                    ForEach(achieved, id: \.milestone) { m in
                        TotalAchievedCard(milestone: m.milestone, achievedAt: m.achievedAt, firstAt: m.firstAt)
                    }
                }
            }
        } else {
            let data = entityCategory(result)
            let upcoming = data.upcoming.filter { tierFilter.matches($0.next) }
            let achieved = data.achieved.filter { tierFilter.matches($0.milestone) }
            section("Upcoming", count: upcoming.count,
                    empty: filtered ? "No upcoming milestones match this filter." : "No upcoming milestones to show.") {
                LazyVGrid(columns: Self.gridColumns, alignment: .leading, spacing: 16) {
                    ForEach(upcoming) { item in
                        MilestoneEntityLink(entity: entity, name: item.name, artist: item.artist, album: item.album, imageURL: item.imageURL) {
                            UpcomingMilestoneCard(item: item, entity: entity)
                        }
                    }
                }
            }
            section("Achieved", count: achieved.count,
                    empty: filtered ? "No achieved milestones match this filter." : "No milestones reached yet — keep listening!") {
                LazyVGrid(columns: Self.gridColumns, alignment: .leading, spacing: 16) {
                    ForEach(achieved) { item in
                        MilestoneEntityLink(entity: entity, name: item.name, artist: item.artist, album: item.album, imageURL: item.imageURL) {
                            AchievedMilestoneCard(item: item, entity: entity)
                        }
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, count: Int, empty: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(title.uppercased()) (\(count.formatted()))")
                .font(AppTypography.supporting.weight(.medium))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            if count == 0 {
                Text(empty).font(AppTypography.supporting).foregroundStyle(.tertiary)
            } else {
                content()
            }
        }
    }

    // MARK: - Loading

    private func loadIfNeeded() async {
        guard isActive, !hasLoaded || needsReload else { return }
        needsReload = false
        await reload()
        hasLoaded = true
    }

    private func requestReload() {
        guard isActive else {
            needsReload = true
            return
        }
        Task { await reload() }
    }

    private func reload() async {
        let requestID = UUID()
        latestRequestID = requestID
        do {
            let container = modelContainer
            let scrobbles = try await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)
            guard latestRequestID == requestID else { return }
            let computed = await Task.detached(priority: .utility) {
                MilestonesEngine.fetch(scrobbles: scrobbles)
            }.value
            guard latestRequestID == requestID else { return }
            // Custom/resolved art wins over the sampled scrobble image, as in every
            // other entity list.
            let imageLookup = try ImageResolutionEngine.imageLookup(context: modelContext)
            result = Self.applyingImages(computed, lookup: imageLookup)
            errorMessage = nil
        } catch {
            guard latestRequestID == requestID else { return }
            errorMessage = "\(error)"
        }
    }

    private static func applyingImages(_ result: MilestonesResult, lookup: [String: String]) -> MilestonesResult {
        func image(_ entity: TopChartsEntity, name: String, artist: String?, album: String?, fallback: String?) -> String? {
            let target: ImageTarget
            switch entity {
            case .artist: target = ImageTarget(kind: .artist, artist: name, album: nil, track: nil)
            case .album: target = ImageTarget(kind: .album, artist: artist ?? "", album: name, track: nil)
            case .track: target = ImageTarget(kind: .track, artist: artist ?? "", album: album, track: name)
            }
            return ImageResolutionEngine.effectiveImageURL(for: target, lookup: lookup, fallbackURL: fallback)
        }
        func category(_ c: MilestoneCategory, _ entity: TopChartsEntity) -> MilestoneCategory {
            MilestoneCategory(
                upcoming: c.upcoming.map {
                    MilestoneUpcoming(
                        entity: $0.entity, artist: $0.artist, name: $0.name, album: $0.album,
                        imageURL: image(entity, name: $0.name, artist: $0.artist, album: $0.album, fallback: $0.imageURL),
                        current: $0.current, next: $0.next, remaining: $0.remaining, etaDays: $0.etaDays
                    )
                },
                achieved: c.achieved.map {
                    MilestoneAchieved(
                        artist: $0.artist, name: $0.name, album: $0.album,
                        imageURL: image(entity, name: $0.name, artist: $0.artist, album: $0.album, fallback: $0.imageURL),
                        current: $0.current, milestone: $0.milestone, achievedAt: $0.achievedAt, firstAt: $0.firstAt
                    )
                }
            )
        }
        return MilestonesResult(
            total: result.total,
            artists: category(result.artists, .artist),
            albums: category(result.albums, .album),
            tracks: category(result.tracks, .track)
        )
    }
}

// MARK: - Cards

struct MilestoneEntityLink<Content: View>: View {
    let entity: TopChartsEntity
    let name: String
    let artist: String?
    let album: String?
    let imageURL: String?
    @ViewBuilder let content: Content

    var body: some View {
        Group {
            switch entity {
            case .artist:
                NavigationLink(value: ArtistIdentity(name: name, imageURL: imageURL)) { content }
                    .entityContextMenu(target: ImageTarget(kind: .artist, artist: name, album: nil, track: nil), currentImageURL: imageURL)
            case .album:
                NavigationLink(value: AlbumIdentity(artist: artist ?? "", name: name, imageURL: imageURL)) { content }
                    .entityContextMenu(target: ImageTarget(kind: .album, artist: artist ?? "", album: name, track: nil), currentImageURL: imageURL)
            case .track:
                NavigationLink(value: TrackIdentity(artist: artist ?? "", name: name, album: album, imageURL: imageURL)) { content }
                    .entityContextMenu(target: ImageTarget(kind: .track, artist: artist ?? "", album: album, track: name), currentImageURL: imageURL)
            }
        }
        .drillDownHighlight()
    }
}

private struct MilestoneCardTitle: View {
    let entity: TopChartsEntity
    let name: String
    let artist: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(name).font(AppTypography.contentTitle).lineLimit(1)
                TrackLovedIndicator(
                    artist: artist ?? "", track: name, initialValue: false,
                    font: AppTypography.supporting, enabled: entity == .track
                )
            }
            if let artist, entity != .artist {
                Text(artist).font(AppTypography.supporting).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

private struct MilestoneProgressBar: View {
    let current: Int
    let next: Int

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(MilestoneFormatting.milestoneColor(next))
                    .frame(width: geometry.size.width * min(1, next > 0 ? Double(current) / Double(next) : 0))
            }
        }
        .frame(height: 4)
    }
}

private struct MilestoneCountBadge: View {
    let text: String
    let milestone: Int

    var body: some View {
        let color = MilestoneFormatting.milestoneColor(milestone)
        Text(text)
            .font(AppTypography.badge.monospacedDigit())
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

private struct MilestoneTrophyBadge: View {
    let milestone: Int

    var body: some View {
        let color = MilestoneFormatting.milestoneColor(milestone)
        HStack(spacing: 4) {
            Image(systemName: "trophy.fill").font(AppTypography.supportingDense)
            Text(MilestoneFormatting.formatMilestone(milestone)).font(AppTypography.badge.monospacedDigit())
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.15), in: Capsule())
        .overlay(Capsule().stroke(MilestoneFormatting.isPrestigeMilestone(milestone) ? Color.accentColor : .clear, lineWidth: 1))
    }
}

private func achievedLine(achievedAt: Date, firstAt: Date) -> String {
    let days = achievedAt.timeIntervalSince(firstAt) / 86400
    let span = days >= 0 ? " (\(MilestoneFormatting.formatElapsedDays(days)))" : ""
    return "Achieved \(achievedAt.formatted(date: .abbreviated, time: .omitted))\(span)"
}

private struct MilestoneCardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct UpcomingMilestoneCard: View {
    let item: MilestoneUpcoming
    let entity: TopChartsEntity

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                EntityThumbnail(url: item.imageURL, entity: entity)
                    .frame(width: AppArtworkSizing.thumbnail, height: AppArtworkSizing.thumbnail)
                VStack(alignment: .leading, spacing: 2) {
                    MilestoneCardTitle(entity: entity, name: item.name, artist: item.artist)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("Next:").font(AppTypography.supporting).foregroundStyle(.tertiary)
                        Text(MilestoneFormatting.formatMilestone(item.next)).font(AppTypography.contentTitle.weight(.semibold).monospacedDigit())
                    }
                }
                Spacer(minLength: 0)
            }
            MilestoneProgressBar(current: item.current, next: item.next)
            HStack {
                Text("\(item.current.formatted()) scrobbles").font(AppTypography.supporting.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                MilestoneCountBadge(text: "\(item.remaining.formatted()) to go", milestone: item.next)
            }
            if let eta = MilestoneFormatting.formatEtaDays(item.etaDays) {
                Text(eta).font(AppTypography.supporting).foregroundStyle(.tertiary)
            }
        }
        .modifier(MilestoneCardBackground())
    }
}

private struct AchievedMilestoneCard: View {
    let item: MilestoneAchieved
    let entity: TopChartsEntity

    var body: some View {
        HStack(spacing: 12) {
            EntityThumbnail(url: item.imageURL, entity: entity)
                .frame(width: AppArtworkSizing.thumbnail, height: AppArtworkSizing.thumbnail)
            VStack(alignment: .leading, spacing: 2) {
                MilestoneCardTitle(entity: entity, name: item.name, artist: item.artist)
                Text(achievedLine(achievedAt: item.achievedAt, firstAt: item.firstAt))
                    .font(AppTypography.supporting).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            MilestoneTrophyBadge(milestone: item.milestone)
        }
        .modifier(MilestoneCardBackground())
    }
}

private struct MilestoneIconTile: View {
    let systemImage: String
    let milestone: Int

    var body: some View {
        let color = MilestoneFormatting.isPrestigeMilestone(milestone) ? Color.accentColor : MilestoneFormatting.milestoneColor(milestone)
        Image(systemName: systemImage)
            .font(.title2)
            .foregroundStyle(color)
            .frame(width: AppArtworkSizing.thumbnail, height: AppArtworkSizing.thumbnail)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct TotalUpcomingCard: View {
    let current: Int
    let next: Int
    let remaining: Int
    let etaDays: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                MilestoneIconTile(systemImage: "target", milestone: next)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Next milestone").font(AppTypography.supporting).foregroundStyle(.secondary)
                    Text("\(next.formatted()) scrobbles").font(AppTypography.entitySubtitle.weight(.semibold).monospacedDigit())
                }
            }
            MilestoneProgressBar(current: current, next: next)
            HStack {
                Text("\(current.formatted()) scrobbles so far").font(AppTypography.supporting.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                MilestoneCountBadge(text: "\(remaining.formatted()) to go", milestone: next)
            }
            if let eta = MilestoneFormatting.formatEtaDays(etaDays) {
                Text(eta).font(AppTypography.supporting).foregroundStyle(.tertiary)
            }
        }
        .padding(4)
        .modifier(MilestoneCardBackground())
    }
}

private struct TotalAchievedCard: View {
    let milestone: Int
    let achievedAt: Date
    let firstAt: Date

    var body: some View {
        HStack(spacing: 12) {
            MilestoneIconTile(systemImage: "trophy.fill", milestone: milestone)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(milestone.formatted()) scrobbles").font(AppTypography.contentTitle.weight(.semibold).monospacedDigit())
                Text(achievedLine(achievedAt: achievedAt, firstAt: firstAt))
                    .font(AppTypography.supporting).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .modifier(MilestoneCardBackground())
    }
}
