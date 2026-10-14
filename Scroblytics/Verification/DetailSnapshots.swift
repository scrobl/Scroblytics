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
            for (name, stats, facts) in [("loaded", Optional(sampleStats()), loaded), ("waiting", nil, waiting)] {
                for width in [1200, 900, 700, 560, 440] as [CGFloat] {
                    for dark in [true, false] {
                        let scheme: ColorScheme = dark ? .dark : .light
                        let view = trackCard(stats: stats, facts: facts)
                            .padding(16)
                            .frame(width: width)
                            .modelContainer(container)
                            .environment(PopularityStore())
                            .environment(LovedTracksStore())
                            .environment(FlaggedTracksStore())
                            .environment(LibraryGapBadgeStore())
                            .environment(\.colorScheme, scheme)
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
                            if let png = rep.representation(using: .png, properties: [:]) {
                                try? png.write(to: URL(fileURLWithPath: folder).appending(path: "track-\(name)-\(Int(width))-\(dark ? "dark" : "light").png"))
                            }
                        }
                    }
                }
            }
            exit(0)
        }
    }
}
#endif
