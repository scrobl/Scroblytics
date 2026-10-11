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
            for (name, settings) in [("ondevice", AskSettings()), ("cloud", cloud)] {
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
}
#endif
