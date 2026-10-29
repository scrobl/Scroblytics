import AppKit
import SwiftData
import SwiftUI

#if DEBUG
/// `SCROBLYTICS_LAYOUT_SNAPSHOT=<folder>` (with `SCROBLYTICS_STORE_PATH` on a scratch path): renders a screen's controls offscreen at
/// several window widths into PNG files, so a responsive layout can be looked at without driving the app. Nothing is shown on
/// screen and nothing is read from or written to the real data.
enum LayoutSnapshots {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        if let folder = ProcessInfo.processInfo.environment["SCROBLYTICS_LAYOUT_SNAPSHOT_ASKENGINE"] {
            snapshotAskEngine(into: folder)
            return
        }
        if let folder = ProcessInfo.processInfo.environment["SCROBLYTICS_LAYOUT_SNAPSHOT_UPDATES"] {
            snapshotUpdates(into: folder)
            return
        }
        if let folder = ProcessInfo.processInfo.environment["SCROBLYTICS_LAYOUT_SNAPSHOT_GOALS"] {
            snapshotGoals(into: folder, container: container)
            return
        }
        if let folder = ProcessInfo.processInfo.environment["SCROBLYTICS_LAYOUT_SNAPSHOT_NEWMUSIC"] {
            snapshotNewMusicTable(into: folder)
            return
        }
        if let folder = ProcessInfo.processInfo.environment["SCROBLYTICS_LAYOUT_SNAPSHOT_RABBITHOLE"] {
            snapshotRabbitHole(into: folder, container: container)
            return
        }
        if let folder = ProcessInfo.processInfo.environment["SCROBLYTICS_LAYOUT_SNAPSHOT_DIAGNOSTICS"] {
            snapshotDiagnostics(into: folder, container: container)
            return
        }
        if let folder = ProcessInfo.processInfo.environment["SCROBLYTICS_LAYOUT_SNAPSHOT_ALMOST"] {
            snapshotAlmostThere(into: folder, container: container)
            return
        }
        if let folder = ProcessInfo.processInfo.environment["SCROBLYTICS_LAYOUT_SNAPSHOT_EDITION"] {
            snapshotEditionSheet(into: folder, container: container)
            return
        }
        if let folder = ProcessInfo.processInfo.environment["SCROBLYTICS_LAYOUT_SNAPSHOT_KEYCHAIN"] {
            snapshotKeychain(into: folder)
            return
        }
        if let folder = ProcessInfo.processInfo.environment["SCROBLYTICS_LAYOUT_SNAPSHOT_PRIVACY"] {
            snapshotPrivacy(into: folder)
            return
        }
        guard let folder = ProcessInfo.processInfo.environment["SCROBLYTICS_LAYOUT_SNAPSHOT"] else { return }
        Task { @MainActor in
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            for width in [1600, 1300, 1150, 1000, 860, 700, 520] as [CGFloat] {
                let view = NavigationStack {
                    LovedStatusAuditView(modelContainer: container, navigation: DetailNavigationCoordinator(origin: .tools))
                }
                .environment(LovedTracksStore())
                .modelContainer(container)
                .environment(\.colorScheme, .dark)
                // Real AppKit controls (segmented pickers, scroll views) only draw inside a window, so the view is hosted in an
                // off-screen one and its contents are copied out.
                let host = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .darkAqua)
                window.contentView = host
                window.setContentSize(NSSize(width: width, height: 300))
                for _ in 0..<6 { try? await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded() }
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: folder).appending(path: "audit-\(Int(width)).png"))
                    }
                }
            }
            // Rows with the new controls: an uncertain pair (same / different), a favorite that isn't in the library (remove), and
            // one that is both uncertain and a leftover, at narrower widths too.
            @MainActor func rowsView() -> some View {
                let ghost = AppleFavoriteNotInLibrary(origin: .leftover, databaseID: 1, name: "Sunhouse", artist: "Artist A")
                let catalogue = AppleFavoriteNotInLibrary(origin: .catalogue, databaseID: 2, name: "Streamed Song With A Rather Long Title", artist: "Artist B & Artist C")
                return VStack(alignment: .leading, spacing: 1) {
                    AuditRow(
                        row: LovedAuditRow(id: "1", artist: "Artist A", track: "Sunhouse", album: nil, lastfm: .loved, appleMusic: .loved,
                                           uncertainty: LovedAuditUncertainty(side: .appleMusic, artist: "Artist A", track: "Sun House"), lastfmHasScrobbles: false),
                        onDecide: { _ in }, onRemoveFromFavorites: nil, onOpen: {})
                    AuditRow(
                        row: LovedAuditRow(id: "2", artist: "Artist B & Artist C", track: "Streamed Song With A Rather Long Title", album: nil, lastfm: .notPresent, appleMusic: .loved,
                                           uncertainty: nil, appleNotInLibrary: catalogue),
                        onDecide: { _ in }, onRemoveFromFavorites: {}, onOpen: {})
                    AuditRow(
                        row: LovedAuditRow(id: "3", artist: "Artist A", track: "Sunhouse", album: nil, lastfm: .notPresent, appleMusic: .loved,
                                           uncertainty: LovedAuditUncertainty(side: .lastfm, artist: "Artist A", track: "Sun House (Live)"), appleNotInLibrary: ghost),
                        onDecide: { _ in }, onRemoveFromFavorites: {}, onOpen: {})
                }
                .padding(.horizontal, 10)
                .background(Color(white: 0.16))
            }
            for width in [1300, 900, 640, 440] as [CGFloat] {
                let host = NSHostingView(rootView: rowsView().environment(\.colorScheme, .dark).frame(width: width))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .darkAqua)
                window.contentView = host
                window.setContentSize(NSSize(width: width, height: 800))
                for _ in 0..<6 { try? await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded() }
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: folder).appending(path: "rows-\(Int(width)).png"))
                    }
                }
            }
            exit(0)
        }
    }

    /// `SCROBLYTICS_LAYOUT_SNAPSHOT_UPDATES=<folder>`: the "update available" strip at several widths and the Settings › Updates section.
    @MainActor
    private static func snapshotUpdates(into folder: String) {
        Task { @MainActor in
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let release = ReleaseInfo(version: AppVersion("0.9.1")!, tag: "v0.9.1", pageURL: URL(string: "https://github.com/scrobl/Scroblytics/releases/tag/v0.9.1")!, isPrerelease: true)
            @MainActor func render<V: View>(_ view: V, width: CGFloat, scheme: String, name: String) async {
                let appearance = scheme == "dark" ? NSAppearance.Name.darkAqua : .aqua
                let host = NSHostingView(rootView: view.frame(width: width).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme == "dark" ? .dark : .light))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                window.setContentSize(NSSize(width: width, height: 200))
                for _ in 0..<4 { try? await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded() }
                window.setContentSize(NSSize(width: width, height: max(host.fittingSize.height, 24)))
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appending(path: "\(name)-\(scheme)-\(Int(width)).png"))
                }
            }
            for scheme in ["dark", "light"] {
                for width in [900, 560, 380] as [CGFloat] {
                    await render(UpdateStripLine(current: AppVersion("0.9.0")!, release: release, onView: {}, onSkip: {}, onDismiss: {}), width: width, scheme: scheme, name: "strip")
                }
                await render(Form { UpdateSettingsSection() }.formStyle(.grouped), width: 560, scheme: scheme, name: "settings")
            }
            exit(0)
        }
    }

    /// `SCROBLYTICS_LAYOUT_SNAPSHOT_GOALS=<folder>`: the Goals page for a made-up goal (about half done, some loves added along the way),
    /// light and dark at a few widths, and a goal that is already complete.
    @MainActor
    private static func snapshotGoals(into folder: String, container: ModelContainer) {
        Task { @MainActor in
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 12))!
            func at(_ day: Int) -> Date { calendar.date(byAdding: .day, value: day, to: calendar.startOfDay(for: now))! }
            var generator = SeededRandom(seed: 99)
            // 220 loved tracks: each has its own appetite, so a few are played often and many hardly ever.
            var loves: [GoalLove] = []
            var appetite: [Double] = []
            for i in 0..<220 {
                let artist = "Artist \(i % 40)", track = "Loved Song Number \(i)"
                loves.append(GoalLove(key: TextNormalization.lovedKey(artist: artist, track: track), artist: artist, track: track, lovedAt: i % 6 == 0 ? at(-Int.random(in: 1..<250, using: &generator)) : nil))
                appetite.append(pow(Double.random(in: 0..<1, using: &generator), 3) * 0.12)
            }
            var plays: [ScrobbleSnapshot] = []
            for day in stride(from: -300, through: -1, by: 1) {
                for (i, love) in loves.enumerated() where Double.random(in: 0..<1, using: &generator) < appetite[i] {
                    plays.append(ScrobbleSnapshot(artistName: love.artist, albumName: "", trackName: love.track, imageURL: nil, playedAt: at(day).addingTimeInterval(36_000)))
                }
                for _ in 0..<24 {
                    plays.append(ScrobbleSnapshot(artistName: "Elsewhere", albumName: "", trackName: "Other \(Int.random(in: 0..<500, using: &generator))", imageURL: nil, playedAt: at(day).addingTimeInterval(40_000)))
                }
            }
            plays.sort { $0.playedAt < $1.playedAt }
            var goal = ListeningGoal(title: "Hear all my loved tracks", start: at(-300), deadline: at(63), lookbackDays: 90)
            goal.dedicatedShare = 0.15
            goal.setAside = [loves[3], loves[9]].map { GoalSetAside(key: $0.key, artist: $0.artist, track: $0.track) }
            let done = ListeningGoal(title: "Already done", start: at(-300), deadline: at(63), lookbackDays: 90)
            let busy = GoalCompute.run(goal: goal, loves: loves, plays: plays, now: now, calendar: calendar)
            // The finished goal: every loved track played once.
            let finishedPlays = (plays + loves.map { ScrobbleSnapshot(artistName: $0.artist, albumName: "", trackName: $0.track, imageURL: nil, playedAt: at(-2)) }).sorted { $0.playedAt < $1.playedAt }
            let finished = GoalCompute.run(goal: done, loves: loves, plays: finishedPlays, now: now, calendar: calendar)
            // A goal for next year: it hasn't started, so nothing is heard and the expected loves before it begins are counted.
            let later = ListeningGoal(title: "Next year", start: at(63), deadline: at(63 + 364), lookbackDays: 90)
            let upcoming = GoalCompute.run(goal: later, loves: loves, plays: plays, now: now, calendar: calendar)
            print("goals snapshot: remaining \(busy.analysis.remainingNow) of \(busy.analysis.membersNow), needed \(String(describing: busy.neededPerDay))")
            for (name, preview) in [("busy", (goal, busy)), ("done", (done, finished)), ("future", (later, upcoming))] {
                for (scheme, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                    for width in [1200, 700] as [CGFloat] {
                        let view = NavigationStack {
                            GoalsView(modelContainer: container, navigation: DetailNavigationCoordinator(origin: .tools), preview: preview)
                        }
                        .environment(LovedTracksStore())
                        .environment(FlaggedTracksStore())
                        .modelContainer(container)
                        .environment(\.colorScheme, scheme == "dark" ? .dark : .light)
                        let host = NSHostingView(rootView: view.frame(width: width, height: 1700))
                        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1700), styleMask: [.titled], backing: .buffered, defer: false)
                        window.appearance = NSAppearance(named: appearance)
                        window.contentView = host
                        window.setContentSize(NSSize(width: width, height: 1700))
                        for _ in 0..<8 { try? await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded() }
                        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                            host.cacheDisplay(in: host.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appending(path: "goals-\(name)-\(scheme)-\(Int(width)).png"))
                        }
                    }
                }
            }
            // The cards a goal's Share button makes (the detail page's, with forecasts, and the landing page's, without).
            for (name, g, r) in [("busy", goal, busy), ("done", done, finished), ("future", later, upcoming)] as [(String, ListeningGoal, GoalResult)] {
                guard let card = GoalShareCards.card(goal: g, analysis: r.analysis, result: r, calendar: calendar, now: now) else { continue }
                for size in [ShareSize.wide, .square] {
                    var o = card.defaultOptions; o.size = size
                    if name == "busy" { o.flags["bands"] = true }
                    if let png = ShareRenderer.png(card: card, options: o, identity: .anonymous, images: [:], scale: 1) {
                        try? png.write(to: URL(fileURLWithPath: folder).appending(path: "goals-share-\(name)-\(size.rawValue).png"))
                    }
                }
            }
            // The landing page with every goal: in progress, finished and not started yet, at a few widths.
            let behind = ListeningGoal(title: "Hear the lot by spring", start: at(-120), deadline: at(30), lookbackDays: 90)
            let missed = ListeningGoal(title: "Last quarter's goal", start: at(-200), deadline: at(-5), lookbackDays: 90)
            let landingGoals = [goal, done, later, behind, missed]
            let landingAnalyses = landingGoals.map { g in
                (g, GoalCompute.analysis(goal: g, loves: loves, plays: g.id == done.id ? finishedPlays : plays, now: now, calendar: calendar))
            }
            for (scheme, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                for width in [1200, 700, 420] as [CGFloat] {
                    let view = NavigationStack {
                        GoalsView(modelContainer: container, navigation: DetailNavigationCoordinator(origin: .tools), landingPreview: landingAnalyses.map { (goal: $0.0, analysis: $0.1) })
                    }
                    .environment(LovedTracksStore()).environment(FlaggedTracksStore()).modelContainer(container)
                    .environment(\.colorScheme, scheme == "dark" ? .dark : .light)
                    let host = NSHostingView(rootView: view.frame(width: width, height: 1100))
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1100), styleMask: [.titled], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: appearance)
                    window.contentView = host
                    window.setContentSize(NSSize(width: width, height: 1100))
                    for _ in 0..<8 { try? await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded() }
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appending(path: "goals-landing-\(scheme)-\(Int(width)).png"))
                    }
                }
            }
            // The chart's zoom (the choice is a stored preference, put back afterwards) and the goal editor.
            let savedRange = UserDefaults.standard.object(forKey: "goals.chart.range")
            for range in [GoalChartRange.back90, .back7, .ahead] {
                UserDefaults.standard.set(range.rawValue, forKey: "goals.chart.range")
                let view = NavigationStack { GoalsView(modelContainer: container, navigation: DetailNavigationCoordinator(origin: .tools), preview: (goal, busy)) }
                    .environment(LovedTracksStore()).environment(FlaggedTracksStore()).modelContainer(container)
                    .environment(\.colorScheme, .light)
                let host = NSHostingView(rootView: view.frame(width: 1200, height: 900))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .aqua)
                window.contentView = host
                window.setContentSize(NSSize(width: 1200, height: 900))
                for _ in 0..<8 { try? await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded() }
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appending(path: "goals-zoom-\(range.rawValue).png"))
                }
            }
            if let savedRange { UserDefaults.standard.set(savedRange, forKey: "goals.chart.range") } else { UserDefaults.standard.removeObject(forKey: "goals.chart.range") }
            do {
                let editor = GoalEditor(request: .new, calendar: calendar, onSave: { _ in }).environment(\.colorScheme, .light)
                let host = NSHostingView(rootView: editor)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 380), styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .aqua)
                window.contentView = host
                window.setContentSize(NSSize(width: 520, height: 380))
                for _ in 0..<6 { try? await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded() }
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appending(path: "goals-editor.png"))
                }
            }
            exit(0)
        }
    }

    /// `SCROBLYTICS_LAYOUT_SNAPSHOT_NEWMUSIC=<folder>`: the Similar Sounds table with new tracks among the library's, light and dark.
    private static func snapshotNewMusicTable(into folder: String) {
        Task { @MainActor in
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            let library = [("Dreaming of a Rather Long Track Title Here", "Artist A", 90), ("Second Song", "Artist B", 70), ("Third", "Artist C", 50)]
            let candidates = library.map { RecommendedCandidate(track: $0.0, artist: $0.1, album: "Album", totalPlaycount: 5, lastPlayed: t0, matchScore: $0.2, sources: ["Seed Song — Artist Z"], topSource: "Seed Song — Artist Z", imageURL: nil) }
            let scrobbles = library.map { ScrobbleSnapshot(artistName: $0.1, albumName: "Album", trackName: $0.0, imageURL: nil, playedAt: t0) }
            let fresh = [
                NewMusicCandidate(artist: "A Band You Have Never Played", track: "Fresh Idea", matchScore: 80, sources: ["Seed Song — Artist Z"], topSource: "Seed Song — Artist Z"),
                NewMusicCandidate(artist: "Another", track: "A New Track With A Very Long Title That Must Truncate Cleanly", matchScore: 40, sources: ["Seed Song — Artist Z"], topSource: "Seed Song — Artist Z"),
            ]
            let pool = SimilarSoundsTool.pool(candidates: candidates, seedResults: [], newMusic: fresh, searchedNewMusic: true)
            guard let result = try? SimilarSoundsTool.evaluate(pool: pool, groups: [], columns: SimilarSoundsTool.defaultColumns, scrobbles: scrobbles, snapshots: QuerySnapshots(), now: t0.addingTimeInterval(86400)) else { exit(1) }
            let rows = SimilarSoundsBlend.blend(
                library: QueryDisplayRow.make(from: result, imageLookup: [:]), result: result, newMusic: fresh, scores: pool.snapshot,
                hasConditions: false, arrangement: SimilarSoundsArrangement(), imageLookup: [:]
            ).rows
            for (scheme, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                let view = QueryResultsTable(rows: rows, columns: result.columns, identityTitle: "Track", onMoveColumn: { _, _ in }, onOpen: { _ in })
                    .environment(LovedTracksStore())
                    .environment(FlaggedTracksStore())
                    .environment(PopularityStore())
                    .environment(TagStore())
                    .environment(LibraryGapBadgeStore())
                    .environment(\.colorScheme, scheme == "dark" ? .dark : .light)
                let host = NSHostingView(rootView: view.frame(width: 1100, height: 330))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 330), styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                window.setContentSize(NSSize(width: 1100, height: 330))
                for _ in 0..<6 { try? await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded() }
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appending(path: "newmusic-table-\(scheme).png"))
                }
            }
            exit(0)
        }
    }

    /// `SCROBLYTICS_LAYOUT_SNAPSHOT_RABBITHOLE=<folder>`: the Rabbit Hole page with a made-up path, its suggestions and their reasons,
    /// the new controls and the "why these three" list, at a few widths (scratch store only).
    @MainActor
    private static func snapshotRabbitHole(into folder: String, container: ModelContainer) {
        Task { @MainActor in
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            func track(_ name: String, _ artist: String, score: Int = 0, reasons: [RabbitHoleReason]? = nil) -> RabbitHoleTrack {
                RabbitHoleTrack(artist: artist, track: name, album: "Album", imageURL: nil, playCount: 12, lastPlayed: nil, matchScore: score, source: "Last.fm similar", reasons: reasons)
            }
            let rootID = UUID(), childID = UUID()
            let suggestions = [
                track("Apocalypse", "Cigarettes After Sex", score: 61, reasons: [RabbitHoleReason(kind: .playedNext, text: "You often play it right after Seed Song (4 times)"), RabbitHoleReason(kind: .sharedTags, text: "Shares tags: dream pop, slowcore"), RabbitHoleReason(kind: .loved, text: "One of your loved tracks")]),
                track("Alison", "Slowdive", score: 70, reasons: [RabbitHoleReason(kind: .similar, text: "Last.fm: similar to Second Song"), RabbitHoleReason(kind: .forgotten, text: "A favourite you haven't played for 2 years")]),
                {
                    var fresh = track("Nothing Sweet", "The Sundays", score: 55, reasons: [RabbitHoleReason(kind: .similar, text: "Last.fm: similar to Second Song"), RabbitHoleReason(kind: .newToYou, text: "New to you: you haven't played it")])
                    fresh.isNew = true
                    return fresh
                }(),
            ]
            var options = RabbitHoleView.Options()
            options.showStyle = true
            options.tree = RabbitHoleTree(
                rootID: rootID,
                nodes: [
                    rootID: RabbitHoleNode(id: rootID, track: track("Seed Song", "Artist A"), parentID: nil, candidates: nil, childIDs: [childID]),
                    childID: RabbitHoleNode(id: childID, track: track("Second Song", "Artist B", score: 80), parentID: rootID, candidates: suggestions, childIDs: []),
                ],
                currentID: childID
            )
            ToolFilterSettingsStore.save(options, toolId: "rabbitHole", context: container.mainContext)
            for (scheme, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                for width in [1100, 760] as [CGFloat] {
                    let view = NavigationStack {
                        RabbitHoleView(modelContainer: container, navigation: DetailNavigationCoordinator(origin: .tools))
                    }
                    .environment(LovedTracksStore())
                    .environment(FlaggedTracksStore())
                    .environment(PopularityStore())
                    .environment(TagStore())
                    .environment(LibraryGapBadgeStore())
                    .modelContainer(container)
                    .environment(\.colorScheme, scheme == "dark" ? .dark : .light)
                    let host = NSHostingView(rootView: view.frame(width: width, height: 1250))
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1250), styleMask: [.titled], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: appearance)
                    window.contentView = host
                    window.setContentSize(NSSize(width: width, height: 1250))
                    for _ in 0..<10 { try? await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded() }
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appending(path: "rabbithole-\(scheme)-\(Int(width)).png"))
                    }
                }
            }
            exit(0)
        }
    }

    /// `SCROBLYTICS_LAYOUT_SNAPSHOT_DIAGNOSTICS=<folder>`: the "quit unexpectedly" strip at several widths, the Settings › Support section
    /// and the Report a Problem window.
    @MainActor
    private static func snapshotDiagnostics(into folder: String, container: ModelContainer) {
        Task { @MainActor in
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            @MainActor func render<V: View>(_ view: V, width: CGFloat, height: CGFloat? = nil, scheme: String, name: String) async {
                let appearance = scheme == "dark" ? NSAppearance.Name.darkAqua : .aqua
                let host = NSHostingView(rootView: view.frame(width: width).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme == "dark" ? .dark : .light))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height ?? 200), styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                window.setContentSize(NSSize(width: width, height: height ?? 200))
                for _ in 0..<(height == nil ? 4 : 10) { try? await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded() }
                if height == nil { window.setContentSize(NSSize(width: width, height: max(host.fittingSize.height, 24))) }
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appending(path: "\(name)-\(scheme)-\(Int(width)).png"))
                }
            }
            ActivityLog.shared.record(.sync, "Sync started (the first import)")
            ActivityLog.shared.record(.network, "Last.fm rate limit (error 29): waiting 30 s (wait 1)")
            for scheme in ["dark", "light"] {
                for width in [900, 560, 380] as [CGFloat] {
                    await render(CrashNoticeLine(onReport: {}, onDismiss: {}), width: width, scheme: scheme, name: "strip")
                }
                await render(Form { SupportSettingsSection() }.formStyle(.grouped), width: 560, scheme: scheme, name: "support")
                await render(ReportProblemView(modelContainer: container), width: 580, height: 680, scheme: scheme, name: "window")
            }
            exit(0)
        }
    }

    /// `SCROBLYTICS_LAYOUT_SNAPSHOT_PRIVACY=<folder>`: the Settings › General privacy section at the Settings window's width and wider.
    @MainActor
    private static func snapshotPrivacy(into folder: String) {
        Task { @MainActor in
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            for (scheme, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                for width in [560, 760] as [CGFloat] {
                    let view = Form { PrivacySettingsSection() }.formStyle(.grouped)
                        .frame(width: width).environment(\.colorScheme, scheme == "dark" ? .dark : .light)
                    let host = NSHostingView(rootView: view)
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 220), styleMask: [.titled], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: appearance)
                    window.contentView = host
                    window.setContentSize(NSSize(width: width, height: 220))
                    for _ in 0..<4 { try? await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded() }
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appending(path: "privacy-\(scheme)-\(Int(width)).png"))
                    }
                }
            }
            exit(0)
        }
    }

    /// `SCROBLYTICS_LAYOUT_SNAPSHOT_ASKENGINE=<folder>`: the Ask engine indicator for the on-device model and a cloud engine, at
    /// the popover's width and narrower, in dark and light.
    @MainActor
    private static func snapshotAskEngine(into folder: String) {
        Task { @MainActor in
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            var cloud = AskSettings()
            cloud.selected = .anthropic
            var local = AskSettings()
            local.selected = .ollama
            local.set(AskProviderConfig(model: "model-x:14b", baseURL: "http://localhost:11434"), for: .ollama)
            for (name, settings) in [("ondevice", AskSettings()), ("cloud", cloud), ("ollama", local)] {
                for (scheme, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                    for width in [540, 420, 320] as [CGFloat] {
                        let view = AskEngineIndicatorLine(settings: settings)
                            .padding(16).frame(width: width)
                            .background(Color(nsColor: .windowBackgroundColor))
                            .environment(\.colorScheme, scheme == "dark" ? .dark : .light)
                        let host = NSHostingView(rootView: view)
                        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
                        window.appearance = NSAppearance(named: appearance)
                        window.contentView = host
                        window.setContentSize(NSSize(width: width, height: host.fittingSize.height))
                        for _ in 0..<4 { try? await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded() }
                        window.setContentSize(NSSize(width: width, height: host.fittingSize.height))
                        host.layoutSubtreeIfNeeded()
                        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                            host.cacheDisplay(in: host.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appending(path: "\(name)-\(scheme)-\(Int(width)).png"))
                        }
                    }
                }
            }
            exit(0)
        }
    }

    /// The can't-read-your-account screen and the strip, for three kinds of problem, light and dark, at a few widths.
    @MainActor
    private static func snapshotKeychain(into folder: String) {
        Task { @MainActor in
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let problems: [(String, OSStatus)] = [("locked", errSecInteractionNotAllowed), ("denied", errSecAuthFailed), ("other", -99999)]
            for (name, status) in problems {
                for width in [1100, 700, 440] as [CGFloat] {
                    for dark in [true, false] {
                        let scheme: ColorScheme = dark ? .dark : .light
                        let screen = CredentialsUnreadableView(status: status, onTryAgain: {}, onSetUpAgain: {}, onContinue: {})
                            .frame(width: width, height: 460)
                        let strip = CredentialsProblemBar(status: status, onTryAgain: {}).frame(width: width)
                        for (kind, view) in [("screen", AnyView(screen)), ("strip", AnyView(strip))] {
                            let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
                            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 460), styleMask: [.titled], backing: .buffered, defer: false)
                            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                            window.contentView = host
                            window.setContentSize(NSSize(width: width, height: kind == "screen" ? 460 : max(40, host.fittingSize.height)))
                            for _ in 0..<5 { try? await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded() }
                            if kind == "strip" { window.setContentSize(NSSize(width: width, height: max(36, host.fittingSize.height))); host.layoutSubtreeIfNeeded() }
                            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                                host.cacheDisplay(in: host.bounds, to: rep)
                                if let png = rep.representation(using: .png, properties: [:]) {
                                    try? png.write(to: URL(fileURLWithPath: folder).appending(path: "\(kind)-\(name)-\(Int(width))-\(dark ? "dark" : "light").png"))
                                }
                            }
                        }
                    }
                }
            }
            exit(0)
        }
    }

    /// `SCROBLYTICS_LAYOUT_SNAPSHOT_EDITION=<folder>`: the Fix album match sheet with its "Count this edition on its own" choice, for an
    /// album with two edition names and for an edition already counted on its own, in light and dark.
    @MainActor
    private static func snapshotEditionSheet(into folder: String, container: ModelContainer) {
        Task { @MainActor in
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            let standard = "Album Name", deluxe = "Album Name (25th Anniversary Edition)"
            let plays = (0..<6).map { i in ScrobbleSnapshot(artistName: "Artist A", albumName: i < 3 ? standard : deluxe, trackName: "Track \(i)", imageURL: nil, playedAt: base.addingTimeInterval(Double(i) * 60)) }
            let merged = AlbumTurnoverEngine.buildAlbumGroups(from: plays)[0]
            let separate = AlbumTurnoverEngine.buildAlbumGroups(from: plays, separateEditions: [TextNormalization.editionIdentityKey(artist: "Artist A", album: deluxe)]).first { $0.editionKey != nil }!
            for width in [900, 560, 420] as [CGFloat] {
                for dark in [true, false] {
                    let view = MissingDataRowPreview.view(name: deluxe, detail: "17 played tracks aren’t on the album’s tracklist · counted with 1 other edition name", pending: width == 420)
                        .frame(width: width).environment(\.colorScheme, dark ? .dark : .light)
                    let host = NSHostingView(rootView: view)
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = host
                    window.setContentSize(NSSize(width: width, height: 90))
                    for _ in 0..<5 { try? await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded() }
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        if let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: folder).appending(path: "row-\(Int(width))-\(dark ? "dark" : "light").png"))
                        }
                    }
                }
            }
            for (name, group, opened) in [("merged", merged, deluxe), ("separate", separate, deluxe), ("plain", AlbumTurnoverEngine.buildAlbumGroups(from: Array(plays.prefix(3)))[0], standard)] {
                for dark in [true, false] {
                    let view = AlbumMatchFixView(group: group, openedFrom: opened, modelContext: container.mainContext, client: nil, onResolved: {})
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let host = NSHostingView(rootView: view)
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = host
                    window.setContentSize(NSSize(width: 560, height: 640))
                    for _ in 0..<8 { try? await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded() }
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        if let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: folder).appending(path: "sheet-\(name)-\(dark ? "dark" : "light").png"))
                        }
                    }
                }
            }
            exit(0)
        }
    }

    /// Overview's "Almost there" cards: eight candidates, drawn at three window widths in light and dark (at most two rows each).
    @MainActor
    private static func snapshotAlmostThere(into folder: String, container: ModelContainer) {
        Task { @MainActor in
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let items: [MilestoneUpcoming] = [
                MilestoneUpcoming(entity: .artist, artist: nil, name: "Artist A", album: nil, imageURL: nil, current: 249, next: 250, remaining: 1, etaDays: 2),
                MilestoneUpcoming(entity: .album, artist: "Artist B & Artist C", name: "A Rather Long Album Title", album: nil, imageURL: nil, current: 99, next: 100, remaining: 1, etaDays: 3),
                MilestoneUpcoming(entity: .track, artist: "Artist D", name: "Track One", album: "Album", imageURL: nil, current: 499, next: 500, remaining: 1, etaDays: 4),
                MilestoneUpcoming(entity: .track, artist: "Artist E", name: "Track Two", album: "Album", imageURL: nil, current: 99, next: 100, remaining: 1, etaDays: 6),
                MilestoneUpcoming(entity: .album, artist: "Artist F", name: "Album Two", album: nil, imageURL: nil, current: 999, next: 1000, remaining: 1, etaDays: 9),
                MilestoneUpcoming(entity: .track, artist: "Artist G", name: "Track Three", album: "Album", imageURL: nil, current: 249, next: 250, remaining: 1, etaDays: 12),
                MilestoneUpcoming(entity: .track, artist: "Artist H", name: "Track Four", album: "Album", imageURL: nil, current: 99, next: 100, remaining: 1, etaDays: 20),
                MilestoneUpcoming(entity: .artist, artist: nil, name: "Artist I", album: nil, imageURL: nil, current: 99, next: 100, remaining: 1, etaDays: nil),
            ]
            let almost = MilestonesEngine.almostThere(from: items)
            for width in [1100, 800, 500] as [CGFloat] {
                for dark in [true, false] {
                    let section = NavigationStack {
                        AlmostMilestonesSection(milestones: almost, columnCount: AlmostMilestonesSection.columnCount(forWidth: width))
                            .padding(16)
                    }
                    await DetailSnapshots.render(
                        section, width: width, dark: dark, container: container,
                        to: URL(fileURLWithPath: folder).appending(path: "almost-\(Int(width))-\(dark ? "dark" : "light").png")
                    )
                }
            }
            exit(0)
        }
    }
}
#endif
