import AppKit
import SwiftData
import SwiftUI

#if DEBUG
/// `SCROBLYTICS_LAYOUT_SNAPSHOT_DETAIL=<folder>` (with `SCROBLYTICS_STORE_PATH` on a scratch path): renders the new detail pages'
/// header card offscreen, with made-up data, at several window widths in dark and light, so the layout can be looked at without
/// driving the app. Nothing is shown on screen and nothing is read from or written to the real data.
enum DetailSnapshots {
    static func sampleStats(loved: Bool = true) -> EntityStats {
        let now = Date()
        let trend = (0..<30).map { TrendBucket(start: now.addingTimeInterval(Double($0 - 30) * 86400), count: [2, 1, 4, 3, 6, 5, 9, 4, 3, 8][$0 % 10]) }
        let first = now.addingTimeInterval(-86400 * 900)
        let milestones = MilestonesEngine.EntityMilestones(
            achieved: [(milestone: 100, achievedAt: now.addingTimeInterval(-86400 * 300), firstAt: first)],
            upcoming: (next: 250, remaining: 108, etaDays: 190)
        )
        return EntityStats(plays: 142, firstScrobble: first, lastScrobble: now.addingTimeInterval(-86400 * 3), imageURL: nil, loved: loved, trend: trend, milestones: milestones)
    }

    @MainActor
    static func trackCard(stats: EntityStats?, facts: [DetailFact]) -> some View {
        DetailHeaderCard(
            entity: .track, name: "Track Title", subtitle: "Artist A", tertiary: "Album Name", imageURL: nil, stats: stats,
            errorMessage: nil, metric: .scrobbles, timeListenedSeconds: 142 * 224,
            yearlyTopRanks: [TopChartsEngine.YearlyRank(year: 2024, rank: 3), TopChartsEngine.YearlyRank(year: 2022, rank: 9)],
            onToggleLoved: {}, facts: facts
        ) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Community tags").font(AppTypography.statLabel).foregroundStyle(.secondary)
                Text("dream pop · shoegaze · 2010s").font(AppTypography.metadata)
            }
        }
    }

    static func sampleObservedTurnover() -> AlbumTurnoverEngine.AlbumTurnover {
        AlbumTurnoverEngine.AlbumTurnover(
            artist: "Artist A", album: "Album Name", applicable: true, basis: .observed, ambiguous: false, noCanonicalMatch: true,
            resolved: false, rateDays: nil, cyclesCompleted: 0, lastTurnoverDate: nil, trackCount: 3, observedDistinct: 3,
            inProgressHeard: 1, inProgressTotal: 3, inProgressMissing: [], tracks: [.init(title: "A", heardThisCycle: true)], isCompilation: false, groupKey: "k", imageURL: nil
        )
    }

    static func sampleTurnover(
        ambiguous: Bool = false, cycles: Int = 7, heard: Int = 8, total: Int = 11, tracks: [AlbumTurnoverEngine.TrackCycleState] = []
    ) -> AlbumTurnoverEngine.AlbumTurnover {
        AlbumTurnoverEngine.AlbumTurnover(
            artist: "Artist A", album: "Album Name", applicable: true, basis: .canonical, ambiguous: ambiguous, noCanonicalMatch: false,
            resolved: false, rateDays: 38, cyclesCompleted: cycles, lastTurnoverDate: nil, trackCount: total, observedDistinct: total,
            inProgressHeard: heard, inProgressTotal: total, inProgressMissing: [], tracks: tracks, isCompilation: false, groupKey: "k", imageURL: nil
        )
    }

    @MainActor
    static func albumCard(stats: EntityStats?, turnover: AlbumTurnoverState, title: String = "Album Name") -> some View {
        let released = DetailFact(id: "released", label: "Released", value: .text("Sep 12, 2018"), systemImage: "calendar", onEdit: {})
        return DetailHeaderCard(
            entity: .album, name: title, subtitle: "Artist A", tertiary: nil, imageURL: nil, stats: stats,
            errorMessage: nil, metric: .scrobbles, timeListenedSeconds: 78 * 3600,
            yearlyTopRanks: [TopChartsEngine.YearlyRank(year: 2024, rank: 2)],
            onFixAlbumMatch: {}, facts: [released] + AlbumDetailModel.turnoverFacts(turnover, onFixAlbumMatch: {})
        ) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Community tags").font(AppTypography.statLabel).foregroundStyle(.secondary)
                Text("dream pop · shoegaze · 2010s").font(AppTypography.metadata)
            }
        }
    }


    @MainActor
    static func table(compact: Bool = false, longAlbum: Bool = false) -> some View {
        let now = Date()
        func entry(_ name: String, plays: Int, daysAgo: Double) -> TopChartEntry {
            TopChartEntry(
                rank: 1, name: name, artist: "Artist A", album: "Album Name", playcount: plays, timeListenedSeconds: nil, imageURL: nil,
                hasCompareRange: false, previousRank: nil, peakRank: 1, lastPlayedAt: now.addingTimeInterval(-daysAgo * 86400), loved: plays > 40,
                releaseDateResolution: .unknown
            )
        }
        let count = longAlbum ? 64 : 11
        let heard = (0..<count).map { $0 % 4 != 3 }
        let listed: [AlbumTurnoverEngine.TrackCycleState] = (0..<count).map { .init(title: "Song \($0 + 1)", heardThisCycle: heard[$0]) }
        var played: [TopChartEntry] = []
        for index in 0..<count where index % 5 != 4 {
            played.append(entry("Song \(index + 1)", plays: max(1, 60 - index * 4 + (index % 3) * 7), daysAgo: Double(1 + index * 3)))
        }
        played.append(entry("Bonus Track", plays: 3, daysAgo: 20))
        return NavigationStack {
            ScrollView {
                AlbumTrackTable(
                    artist: "Artist A", album: "Album Name",
                    range: DateRange(from: now.addingTimeInterval(-365 * 86400), to: now), compareRange: nil, metric: .scrobbles,
                    turnover: .ready(sampleTurnover(total: count, tracks: listed)), seedEntries: played
                )
            }
        }
        .frame(height: longAlbum ? 900 : 560)
    }

    @MainActor
    static func render<Content: View>(_ content: Content, width: CGFloat, dark: Bool, container: ModelContainer, to url: URL) async {
        let view = content
            .padding(16)
            .frame(width: width)
            .modelContainer(container)
            .environment(PopularityStore())
            .environment(LovedTracksStore())
            .environment(FlaggedTracksStore())
            .environment(LibraryGapBadgeStore())
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setContentSize(NSSize(width: width, height: 600))
        for _ in 0..<5 { try? await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded() }
        let fitting = host.fittingSize
        window.setContentSize(NSSize(width: width, height: max(200, fitting.height)))
        for _ in 0..<3 { try? await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded() }
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
        }
    }

    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        guard let folder = ProcessInfo.processInfo.environment["SCROBLYTICS_LAYOUT_SNAPSHOT_DETAIL"] else { return }
        Task { @MainActor in
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let loaded = [
                DetailFact(id: "released", label: "Released", value: .text("Sep 12, 2018"), systemImage: "calendar", onEdit: {}),
                DetailFact(id: "length", label: "Length", value: .text("3:44"), corrected: true, systemImage: "clock", onEdit: {}),
                DetailFact(id: "tempo", label: "Tempo", value: .text("118 BPM"), detail: "4/4 · A minor", systemImage: "metronome", onEdit: {}),
            ]
            let waiting = [
                DetailFact(id: "released", label: "Released", value: .loading, systemImage: "calendar", onEdit: {}),
                DetailFact(id: "length", label: "Length", value: .unknown, systemImage: "clock", onEdit: {}),
                DetailFact(id: "tempo", label: "Tempo", value: .loading, systemImage: "metronome", onEdit: {}),
            ]
            let base = URL(fileURLWithPath: folder)
            for width in [1200, 900, 700, 560, 440] as [CGFloat] {
                for dark in [true, false] {
                    let mode = dark ? "dark" : "light"
                    await render(trackCard(stats: sampleStats(), facts: loaded), width: width, dark: dark, container: container, to: base.appending(path: "track-loaded-\(Int(width))-\(mode).png"))
                    await render(trackCard(stats: nil, facts: waiting), width: width, dark: dark, container: container, to: base.appending(path: "track-waiting-\(Int(width))-\(mode).png"))
                    await render(albumCard(stats: sampleStats(loved: false), turnover: .ready(sampleTurnover())), width: width, dark: dark, container: container, to: base.appending(path: "album-ready-\(Int(width))-\(mode).png"))
                    await render(albumCard(stats: sampleStats(loved: false), turnover: .ready(sampleTurnover(ambiguous: true))), width: width, dark: dark, container: container, to: base.appending(path: "album-uncertain-\(Int(width))-\(mode).png"))
                    await render(albumCard(stats: nil, turnover: .loading), width: width, dark: dark, container: container, to: base.appending(path: "album-loading-\(Int(width))-\(mode).png"))
                }
            }
            let longTitle = "The Idler Wheel Is Wiser Than the Driver of the Screw and Whipping Cords Will Serve You More Than Ropes Will Ever Do (Deluxe Version)"
            for width in [1600, 1000, 700] as [CGFloat] {
                await render(albumCard(stats: sampleStats(loved: false), turnover: .ready(sampleTurnover()), title: longTitle), width: width, dark: true, container: container, to: base.appending(path: "album-longtitle-\(width)-dark.png".replacingOccurrences(of: ".0", with: "")))
            }
            for width in [1600, 1000, 700, 520] as [CGFloat] {
                for dark in [true, false] {
                    let mode = dark ? "dark" : "light"
                    await render(table(), width: width, dark: dark, container: container, to: base.appending(path: "table-\(Int(width))-\(mode).png"))
                }
            }
            await render(table(longAlbum: true), width: 900, dark: true, container: container, to: base.appending(path: "table-long-900-dark.png"))
            exit(0)
        }
    }
}
#endif
