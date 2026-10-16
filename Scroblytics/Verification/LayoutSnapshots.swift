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
            func rowsView() -> some View {
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
