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
