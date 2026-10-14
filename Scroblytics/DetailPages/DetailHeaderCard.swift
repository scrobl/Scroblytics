import SwiftData
import SwiftUI

/// The top of the new Artist, Album and Track pages: artwork and identity, the trend line, the headline numbers, the page's own
/// facts, then (when given) tags, all in one card. The pages differ only in what they pass in.
struct DetailHeaderCard<Tags: View>: View {
    @Environment(\.modelContext) private var modelContext
    @State private var effectiveImageURL: String?
    @State private var artworkRefreshID = UUID()
    @State private var isShowingArtwork = false

    let entity: TopChartsEntity
    let name: String
    /// The artist under an album or track title; nil on an artist page.
    let subtitle: String?
    /// The album under a track's artist, when the track was reached through one.
    let tertiary: String?
    let imageURL: String?
    let stats: EntityStats?
    let errorMessage: String?
    let metric: TopChartsMetric
    var timeListenedSeconds: Int? = nil
    var yearlyTopRanks: [TopChartsEngine.YearlyRank] = []
    /// Tracks only: makes the loved heart interactive.
    var onToggleLoved: (() -> Void)? = nil
    var isTogglingLoved = false
    /// Albums only: adds "Fix album match…" to the artwork's right-click menu.
    var onFixAlbumMatch: (() -> Void)? = nil
    /// The page's own facts, under the headline numbers.
    var facts: [DetailFact] = []
    @ViewBuilder var tags: () -> Tags

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            headlineFacts
            if !facts.isEmpty { DetailFactGrid(facts: facts) }
            milestones
            tagsArea
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ColorWashView(imageURLs: [effectiveImageURL ?? imageURL].compactMap { $0 }, strength: 0.78)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.separator.opacity(0.45), lineWidth: 1)
        }
        .sheet(isPresented: $isShowingArtwork) {
            DetailArtworkPreviewSheet(
                name: name, imageURL: effectiveImageURL ?? imageURL,
                placeholderSystemName: imageTarget.kind == .artist ? "person.fill" : "music.note"
            )
        }
        .task(id: imageTarget) { reloadImage() }
        .onReceive(NotificationCenter.default.publisher(for: .imageDidChange)) { notification in
            guard let changedTarget = notification.object as? ImageTarget,
                  changedTarget == imageTarget || imageTarget.kind == .track else { return }
            reloadImage()
        }
    }

    // MARK: - Header

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) {
                artwork
                identity.frame(maxWidth: 460, alignment: .leading)
                // The trend takes the rest of the row, sitting on the artwork's bottom edge.
                sparkline
                    .frame(height: 72)
                    .frame(minWidth: 160, maxWidth: .infinity)
                    .frame(height: Self.artworkSize, alignment: .bottom)
            }
            HStack(alignment: .top, spacing: 14) {
                artwork
                VStack(alignment: .leading, spacing: 10) {
                    identity
                    sparkline.frame(height: 40)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                artwork
                identity
                sparkline.frame(height: 40)
            }
        }
    }

    @ViewBuilder
    private var sparkline: some View {
        if let stats, !stats.trend.isEmpty {
            TrendSparkline(buckets: stats.trend)
        } else {
            Color.clear
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(name).font(AppTypography.entityTitle).lineLimit(3)
                PopularityMarker(entity: entity, name: name, artist: subtitle, font: .system(size: 13))
                if let onToggleLoved, let stats {
                    lovedHeartButton(loved: stats.loved, action: onToggleLoved)
                }
                if entity == .track {
                    TrackFlaggedIndicator(artist: subtitle ?? "", track: name, font: AppTypography.entitySubtitle)
                    TrackLibraryGapBadge(artist: subtitle ?? "", track: name, font: AppTypography.entitySubtitle)
                }
            }
            if let subtitle {
                Text(subtitle).font(AppTypography.entitySubtitle).foregroundStyle(.secondary).lineLimit(2)
            }
            if let tertiary {
                Text(tertiary).font(AppTypography.entityTertiary).foregroundStyle(.tertiary).lineLimit(2)
            }
            if !yearlyTopRanks.isEmpty {
                TagFlowLayout(spacing: 6) {
                    ForEach(yearlyTopRanks) { entry in
                        HStack(spacing: 4) {
                            Image(systemName: "medal.fill").font(AppTypography.supportingDense)
                            Text("#\(entry.rank)").font(AppTypography.badge)
                            Text("· \(String(entry.year))").font(AppTypography.supportingDense).opacity(0.7)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .foregroundStyle(Color.purple)
                        .background(Color.purple.opacity(0.15), in: Capsule())
                    }
                }
                .padding(.top, 4)
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

    // MARK: - Artwork

    private var artwork: some View {
        Group {
            if canShowLargerArtwork {
                Button { isShowingArtwork = true } label: { artworkThumbnail }
                    .buttonStyle(.plain)
                    .help("View larger artwork")
                    .accessibilityLabel("View larger artwork for \(name)")
            } else {
                artworkThumbnail
            }
        }
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

    private var artworkThumbnail: some View {
        ArtworkImage(urlString: effectiveImageURL ?? imageURL, contentMode: .fill) {
            Color.clear.overlay {
                Image(systemName: imageTarget.kind == .artist ? "person.fill" : "music.note")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
            }
        }
        .id(artworkRefreshID)
        .frame(width: Self.artworkSize, height: Self.artworkSize)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    static var artworkSize: CGFloat { 128 }

    private var canShowLargerArtwork: Bool { (effectiveImageURL ?? imageURL) != nil }

    private func reloadImage() {
        effectiveImageURL = try? ImageResolutionEngine.effectiveImageURL(for: imageTarget, context: modelContext, fallbackURL: imageURL)
    }

    private var imageTarget: ImageTarget {
        switch entity {
        case .artist: ImageTarget(kind: .artist, artist: name, album: nil, track: nil)
        case .album: ImageTarget(kind: .album, artist: subtitle ?? "", album: name, track: nil)
        case .track: ImageTarget(kind: .track, artist: subtitle ?? "", album: tertiary, track: name)
        }
    }

    // MARK: - Headline numbers

    /// The numbers every page has. While the stats load, the tiles are there already, so nothing jumps.
    private var headlineFacts: some View {
        Group {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.secondary)
            } else {
                DetailFactGrid(facts: Self.headline(stats: stats, metric: metric, timeListenedSeconds: timeListenedSeconds))
            }
        }
    }

    static func headline(stats: EntityStats?, metric: TopChartsMetric, timeListenedSeconds: Int?) -> [DetailFact] {
        func date(_ value: Date?) -> String {
            value.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—"
        }
        guard let stats else {
            return [
                DetailFact(id: "plays", label: metric == .scrobbles ? "Scrobbles" : "Time Listened", value: .loading, loadingText: "—"),
                DetailFact(id: "first", label: "First scrobble", value: .loading, loadingText: "—"),
                DetailFact(id: "last", label: "Last scrobble", value: .loading, loadingText: "—"),
                DetailFact(id: "every", label: "Play frequency", value: .loading, loadingText: "—"),
            ]
        }
        let primary: DetailFact.Value = metric == .scrobbles
            ? .text(stats.plays.formatted())
            : (timeListenedSeconds.map { .text(DurationEngine.formatTimeListened($0)) } ?? .loading)
        return [
            DetailFact(id: "plays", label: metric == .scrobbles ? "Scrobbles" : "Time Listened", value: primary, loadingText: "—"),
            DetailFact(id: "first", label: "First scrobble", value: .text(date(stats.firstScrobble))),
            DetailFact(id: "last", label: "Last scrobble", value: .text(date(stats.lastScrobble))),
            DetailFact(id: "every", label: "Play frequency", value: .text(playFrequency(stats.averageDaysBetweenPlays))),
        ]
    }

    /// An average gap between plays, in words.
    static func playFrequency(_ averageDays: Double?) -> String {
        guard let averageDays else { return "—" }
        if averageDays < 1 { return "several a day" }
        let days = averageDays < 10 ? String(format: "%.1f", averageDays) : "\(Int(averageDays.rounded()))"
        return "every \(days) days"
    }

    // MARK: - Milestones

    @ViewBuilder
    private var milestones: some View {
        if let stats, !stats.milestones.achieved.isEmpty || stats.milestones.upcoming != nil {
            VStack(alignment: .leading, spacing: 6) {
                if !stats.milestones.achieved.isEmpty {
                    TagFlowLayout(spacing: 6) {
                        ForEach(Array(stats.milestones.achieved.enumerated()), id: \.offset) { _, milestone in
                            milestoneBadge(milestone)
                        }
                    }
                }
                if let upcoming = stats.milestones.upcoming {
                    HStack(spacing: 6) {
                        Text("\(upcoming.remaining) to \(MilestoneFormatting.formatMilestone(upcoming.next))")
                            .font(AppTypography.supporting).foregroundStyle(.secondary)
                        if let eta = MilestoneFormatting.formatEtaDays(upcoming.etaDays) {
                            Text("· \(eta)").font(AppTypography.supportingDense).foregroundStyle(.tertiary)
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
            Text("· \(m.achievedAt.formatted(date: .abbreviated, time: .omitted)) (\(MilestoneFormatting.formatElapsedDays(elapsedDays)))")
                .font(AppTypography.supportingDense).opacity(0.7)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .foregroundStyle(color)
        .background(color.opacity(0.15), in: Capsule())
        .overlay(Capsule().stroke(MilestoneFormatting.isPrestigeMilestone(m.milestone) ? Color.accentColor : .clear, lineWidth: 1))
    }

    // MARK: - Tags

    @ViewBuilder
    private var tagsArea: some View {
        if Tags.self != EmptyView.self {
            Divider().opacity(0.6)
            tags()
        }
    }
}

extension DetailHeaderCard where Tags == EmptyView {
    init(
        entity: TopChartsEntity, name: String, subtitle: String?, tertiary: String?, imageURL: String?, stats: EntityStats?,
        errorMessage: String?, metric: TopChartsMetric, timeListenedSeconds: Int? = nil, yearlyTopRanks: [TopChartsEngine.YearlyRank] = [],
        onToggleLoved: (() -> Void)? = nil, isTogglingLoved: Bool = false, onFixAlbumMatch: (() -> Void)? = nil, facts: [DetailFact] = []
    ) {
        self.init(
            entity: entity, name: name, subtitle: subtitle, tertiary: tertiary, imageURL: imageURL, stats: stats, errorMessage: errorMessage,
            metric: metric, timeListenedSeconds: timeListenedSeconds, yearlyTopRanks: yearlyTopRanks, onToggleLoved: onToggleLoved,
            isTogglingLoved: isTogglingLoved, onFixAlbumMatch: onFixAlbumMatch, facts: facts, tags: { EmptyView() }
        )
    }
}

/// The larger artwork, opened from the header.
struct DetailArtworkPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let name: String
    let imageURL: String?
    let placeholderSystemName: String

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(name).font(.headline).lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ArtworkImage(urlString: imageURL, contentMode: .fit) {
                Color.clear.overlay {
                    Image(systemName: placeholderSystemName).font(.system(size: 72)).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 560, height: 560)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityLabel("Artwork for \(name)")
        }
        .padding(20)
    }
}
