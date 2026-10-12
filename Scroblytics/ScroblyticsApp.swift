import SwiftUI
import SwiftData
import Observation

@MainActor
@Observable
final class WindowCommandState {
    enum Destination: Hashable {
        case overview, library, topCharts, trends, milestones, timeline, tools
    }

    enum Command {
        case search, ask, sync, fullResync, staleRecordReview
        case navigate(Destination)
    }

    private(set) var request = 0
    private(set) var command = Command.search
    private(set) var isSyncing = false

    func requestSearch() { perform(.search) }
    func requestAsk() { perform(.ask) }
    func requestSync() { perform(.sync) }
    func requestFullResync() { perform(.fullResync) }
    func requestStaleRecordReview() { perform(.staleRecordReview) }
    func setSyncing(_ isSyncing: Bool) { self.isSyncing = isSyncing }

    func navigate(to destination: Destination) {
        perform(.navigate(destination))
    }

    private func perform(_ command: Command) {
        self.command = command
        request += 1
    }
}

extension FocusedValues {
    @Entry var windowCommands: WindowCommandState?
}

enum DataManagementAction {
    case backup, restore, exportHistory
}

@MainActor
@Observable
final class DataManagementCommandState {
    private(set) var request = 0
    private(set) var action = DataManagementAction.backup

    func perform(_ action: DataManagementAction) {
        self.action = action
        request += 1
    }
}

/// DEBUG-only switches for verification runs; always false in release builds.
enum DebugFlags {
    /// Lets the tag sweep run in an otherwise-offline verification run.
    static var tagSweep: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["SCROBLYTICS_TAG_SWEEP"] != nil
        #else
        false
        #endif
    }

    /// Lets the release-date sweep run in an otherwise-offline verification run.
    static var releaseSweep: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["SCROBLYTICS_RELEASE_SWEEP"] != nil
        #else
        false
        #endif
    }

    static var offline: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["SCROBLYTICS_OFFLINE"] != nil
        #else
        false
        #endif
    }
}

enum AppearancePreference: String, CaseIterable, Identifiable {
    static let storageKey = "appearancePreference"

    case light
    case dark

    var id: Self { self }

    var colorScheme: ColorScheme {
        switch self {
        case .light: .light
        case .dark: .dark
        }
    }
}

@main
struct ScroblyticsApp: App {
    @State private var nowPlayingStore = NowPlayingStore()
    @State private var dataManagementCommands = DataManagementCommandState()
    @AppStorage(AppearancePreference.storageKey) private var appearance = AppearancePreference.dark
    @AppStorage(NowPlayingPreference.showsShelfKey) private var showsNowPlayingShelf = true

    /// The database, or an in-memory stand-in plus the reason when it couldn't be opened (`StoreStartup`).
    private static let opened: (container: ModelContainer, failure: StoreStartupFailure?) = {
        let schema = Schema([
            Scrobble.self, Artist.self, Album.self, Track.self, SyncState.self,
            FlaggedTrack.self, SavedQuery.self, LinerNote.self, ToolFilterSetting.self, AppSettings.self,
            AlbumTracklistCacheEntry.self, ReverbPoolCache.self, AlbumTurnoverCompletionCache.self,
            TrackDurationCacheEntry.self,
            TrackBPMCacheEntry.self,
            LovedTrackEntry.self,
            EntityCommunityTagCacheEntry.self,
            UserEntityTagCacheEntry.self,
            PersonalTagSyncState.self,
            TrackReleaseDateCacheEntry.self,
            PopularityCacheEntry.self,
            SavedConditionSet.self,
            AlbumImageOverride.self,
            LibraryPresenceEntry.self,
            LibraryPresenceCheck.self,
            LibraryGapDismissal.self,
            LovedAuditDecision.self,
            TagPlaylistRule.self,
        ])
        #if DEBUG
        // Lets a verification run use a COPY of the store (and, with
        // SCROBLYTICS_OFFLINE, skip all network work) so it can run beside a
        // real session without touching or double-syncing the live data.
        // Under a test profile (scripts/first-run-profile.sh) the store lives in the profile's own home folder, and
        // the app stops before opening anything unless preferences, store and Keychain items are all isolated.
        let storePath = ProcessInfo.processInfo.environment["SCROBLYTICS_STORE_PATH"]
            ?? (TestProfile.name != nil ? TestProfile.storeURL.path : nil)
        TestProfile.enforce(storePath: storePath ?? TestProfile.storeURL.path)
        if TestProfile.name != nil, let storePath {
            try? FileManager.default.createDirectory(at: URL(fileURLWithPath: storePath).deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let configuration = storePath
            .map { ModelConfiguration(schema: schema, url: URL(fileURLWithPath: $0)) }
            ?? ModelConfiguration(schema: schema)
        #else
        let configuration = ModelConfiguration(schema: schema)
        #endif
        #if DEBUG
        return StoreStartup.open(schema: schema, configuration: configuration, storePath: storePath)
        #else
        return StoreStartup.open(schema: schema, configuration: configuration, storePath: nil)
        #endif
    }()

    var modelContainer: ModelContainer { Self.opened.container }

    init() {
        #if DEBUG
        TestProfileChecks.runHeadlessIfRequested()
        TestProfileLauncherChecks.runHeadlessIfRequested(container: modelContainer)
        FirstRunChecks.runHeadlessIfRequested()
        AppleMusicLinkChecks.runHeadlessIfRequested()
        LayoutSnapshots.runHeadlessIfRequested(container: modelContainer)
        LovedAuditChecks.runHeadlessIfRequested(container: modelContainer)
        QueryCapChecks.runHeadlessIfRequested()
        RateLimitChecks.runHeadlessIfRequested()
        UpdateChecks.runHeadlessIfRequested()
        DiagnosticsChecks.runHeadlessIfRequested(container: modelContainer)
        PerfChecks.runHeadlessIfRequested(container: modelContainer)
        Task { @MainActor in ProgressSimulator.startIfRequested() }
        TestProfile.seedAccountIfRequested()
        TestProfile.seedRealLastfmAccountIfRequested()
        Task { @MainActor in
            TestProfile.autoConnectIfRequested()
            TestProfile.stopAfterIfRequested()
            TestProfile.retryAfterIfRequested()
        }
        TestProfileLauncher.optionHeldAtLaunch = NSEvent.modifierFlags.contains(.option)
        HelpChecks.runHeadlessIfRequested()
        HelpClaimChecks.runHeadlessIfRequested()
        BPMChecks.runHeadlessIfRequested()
        BPMChecks.runSeedDumpIfRequested(container: modelContainer)
        HelpClaimChecks.runStoreCheckIfRequested(container: modelContainer)
        ConsistencyChecks.runHeadlessIfRequested(container: modelContainer)
        OfflineChecks.runHeadlessIfRequested(container: modelContainer)
        TimelineDebugDump.runHeadlessIfRequested(container: modelContainer)
        AlbumTurnoverDebugDump.runHeadlessIfRequested(container: modelContainer)
        AskDebugEval.runHeadlessIfRequested(container: modelContainer)
        MostRecentMostOftenDebugEval.runHeadlessIfRequested(container: modelContainer)
        TheClimbDebugEval.runHeadlessIfRequested(container: modelContainer)
        FadingFavoritesDebugEval.runHeadlessIfRequested(container: modelContainer)
        MissingDataDebugEval.runHeadlessIfRequested(container: modelContainer)
        StaleRecordDebugEval.runHeadlessIfRequested(container: modelContainer)
        SimilarSoundsDebugEval.runHeadlessIfRequested(container: modelContainer)
        LovedAuditDebugEval.runHeadlessIfRequested(container: modelContainer)
        LovedSyncDebugCheck.runHeadlessIfRequested(container: modelContainer)
        LibraryGapsDebugEval.runHeadlessIfRequested(container: modelContainer)
        TagPlanDebugEval.runHeadlessIfRequested(container: modelContainer)
        #endif
        // The small activity log behind Help › Report a Problem. It stays on this Mac.
        Task { @MainActor in ActivityEvents.start() }
    }

    var body: some Scene {
        WindowGroup {
            if let failure = Self.opened.failure {
                StoreErrorView(failure: failure)
                    .preferredColorScheme(appearance.colorScheme)
            } else {
                ContentView(
                    modelContainer: modelContainer,
                    nowPlayingStore: nowPlayingStore
                )
                    .preferredColorScheme(appearance.colorScheme)
            }
        }
        .modelContainer(modelContainer)
        // The first time the main window opens (no saved window position yet) it fills the screen's usable area, below the
        // menu bar and clear of the Dock. After that macOS remembers whatever size you leave it at.
        .defaultWindowPlacement { _, context in
            WindowPlacement(.center, size: context.defaultDisplay.visibleRect.size)
        }
        .commands {
            FileCommands(dataManagementCommands: dataManagementCommands)
            AppViewCommands(showsNowPlayingShelf: $showsNowPlayingShelf)
            LibraryCommands()
            UpdateCommands()
            HelpCommands()
            #if DEBUG
            DebugCommands()
            #endif
        }

        Window("Scroblytics Help", id: "help") {
            HelpView()
                .preferredColorScheme(appearance.colorScheme)
        }
        .defaultSize(width: 980, height: 700)

        Window("Report a Problem", id: "report-problem") {
            ReportProblemView(modelContainer: modelContainer)
                .preferredColorScheme(appearance.colorScheme)
        }
        .defaultSize(width: 580, height: 660)

        Window("Data Management", id: "data-management") {
            VStack(spacing: 0) {
                #if DEBUG
                TestProfileStrip()
                #endif
                BackupImportView(modelContainer: modelContainer, commandState: dataManagementCommands)
            }
                .modelContainer(modelContainer)
                .preferredColorScheme(appearance.colorScheme)
        }
        .defaultSize(width: 620, height: 540)

        #if DEBUG
        Window("Test Profiles", id: "test-profiles") {
            TestProfilesView()
                .preferredColorScheme(appearance.colorScheme)
        }
        .defaultSize(width: 520, height: 520)
        #endif

        #if os(macOS)
            Settings {
                AppSettingsView(modelContainer: modelContainer)
                    .modelContainer(modelContainer)
                    .preferredColorScheme(appearance.colorScheme)
            }
        #endif
    }
}

private struct FileCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let dataManagementCommands: DataManagementCommandState

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Back Up Scroblytics Data…") { open(.backup) }
            Button("Restore Backup…") { open(.restore) }
            Divider()
            Button("Export Listening History…") { open(.exportHistory) }
        }
    }

    private func open(_ action: DataManagementAction) {
        dataManagementCommands.perform(action)
        openWindow(id: "data-management")
    }
}

private struct AppViewCommands: Commands {
    @FocusedValue(\.windowCommands) private var windowCommands
    @Binding var showsNowPlayingShelf: Bool

    var body: some Commands {
        CommandGroup(before: .sidebar) {
            Button("Overview") { windowCommands?.navigate(to: .overview) }
                .keyboardShortcut("1")
                .disabled(windowCommands == nil)
            Button("Library") { windowCommands?.navigate(to: .library) }
                .keyboardShortcut("2")
                .disabled(windowCommands == nil)
            Button("Top Charts") { windowCommands?.navigate(to: .topCharts) }
                .keyboardShortcut("3")
                .disabled(windowCommands == nil)
            Button("Trends") { windowCommands?.navigate(to: .trends) }
                .keyboardShortcut("4")
                .disabled(windowCommands == nil)
            Button("Milestones") { windowCommands?.navigate(to: .milestones) }
                .keyboardShortcut("5")
                .disabled(windowCommands == nil)
            Button("Timeline") { windowCommands?.navigate(to: .timeline) }
                .keyboardShortcut("6")
                .disabled(windowCommands == nil)
            Button("Tools") { windowCommands?.navigate(to: .tools) }
                .keyboardShortcut("7")
                .disabled(windowCommands == nil)
            Divider()
            Toggle("Show Now Playing", isOn: $showsNowPlayingShelf)
        }
        CommandGroup(after: .pasteboard) {
            Button("Search Library…") { windowCommands?.requestSearch() }
                .keyboardShortcut("f")
                .disabled(windowCommands == nil)
        }
    }
}

private struct LibraryCommands: Commands {
    @FocusedValue(\.windowCommands) private var windowCommands

    var body: some Commands {
        CommandMenu("Library") {
            Toggle("Offline Mode", isOn: Binding(get: { Connectivity.shared.isOffline }, set: { Connectivity.shared.setOffline($0) }))
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Sync Now") { windowCommands?.requestSync() }
                .disabled(windowCommands?.isSyncing != false || Connectivity.shared.isOffline)
            Button("Full Resync") { windowCommands?.requestFullResync() }
                .disabled(windowCommands?.isSyncing != false || Connectivity.shared.isOffline)
            Button("Review Stale Records…") { windowCommands?.requestStaleRecordReview() }
                .disabled(windowCommands == nil)
            Divider()
            Button("Ask Library…") { windowCommands?.requestAsk() }
                .disabled(windowCommands == nil)
        }
    }
}

/// "Check for Updates…" under the app's About item.
private struct UpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Task { await UpdateStore.shared.checkNowAndTell() } }
        }
    }
}

/// Replaces the Help menu's default item with the app's own Help window.
private struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Scroblytics Help") { openWindow(id: "help") }
                .keyboardShortcut("?", modifiers: .command)
            Button("Privacy Policy") { openURL(AppIdentity.privacyPolicyURL) }
            Divider()
            Button("Report a Problem…") { openWindow(id: "report-problem") }
        }
    }
}

private struct AppSettingsView: View {
    let modelContainer: ModelContainer
    @AppStorage(AppearancePreference.storageKey) private var appearance = AppearancePreference.dark
    /// The tab the Settings window is on; a link elsewhere in the app (Ask's "Change in Settings") sets it before opening.
    @AppStorage(SettingsTab.storageKey) private var selectedTab = SettingsTab.general.rawValue

    var body: some View {
        VStack(spacing: 0) {
            #if DEBUG
            TestProfileStrip()
            #endif
            settingsTabs
        }
    }

    private var settingsTabs: some View {
        TabView(selection: $selectedTab) {
            AppearanceSettingsView(appearance: $appearance)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsTab.general.rawValue)

            SyncSetupView()
                .tabItem {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .tag(SettingsTab.sync.rawValue)

            TempoSettingsView()
                .tabItem {
                    Label("Tempo", systemImage: "metronome")
                }
                .tag(SettingsTab.tempo.rawValue)

            AskSettingsView()
                .tabItem {
                    Label("Ask", systemImage: "sparkles")
                }
                .tag(SettingsTab.ask.rawValue)

        }
        .frame(minWidth: 560, minHeight: 540)
    }
}

/// The tabs of the Settings window.
enum SettingsTab: String {
    case general, sync, tempo, ask
    static let storageKey = "settings.selectedTab"
}

/// Settings › General › Privacy: where the privacy policy is, and the Help article on what leaves the Mac.
struct PrivacySettingsSection: View {
    var body: some View {
        Section("Privacy") {
            Text("Scroblytics has no accounts, analytics or tracking. The policy lists what stays on your Mac and every service the app contacts.")
                .font(AppTypography.supporting)
                .foregroundStyle(.secondary)
            Link("Privacy Policy", destination: AppIdentity.privacyPolicyURL)
                .font(AppTypography.supporting)
                .help("Opens the privacy policy in your web browser.")
            HelpLinkButton(articleID: "what-leaves-your-mac", title: "What leaves your Mac")
        }
    }
}

private struct AppearanceSettingsView: View {
    @Binding var appearance: AppearancePreference
    @AppStorage(AppCalendars.weekStartKey) private var weekStartDay = WeekStart.monday.rawValue

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Color scheme", selection: $appearance) {
                    Label("Light", systemImage: "sun.max.fill")
                        .tag(AppearancePreference.light)
                    Label("Dark", systemImage: "moon.stars.fill")
                        .tag(AppearancePreference.dark)
                }
                .pickerStyle(.segmented)

                Text("Choose how Scroblytics appears across all windows.")
                    .font(AppTypography.supporting)
                    .foregroundStyle(.secondary)
            }

            Section("Network") {
                Toggle("Offline mode", isOn: Binding(get: { Connectivity.shared.isOffline }, set: { Connectivity.shared.setOffline($0) }))

                Text("Stops syncing and every online lookup (Last.fm, Deezer, MusicBrainz, artwork, cloud Ask engines), and keeps everything already on your Mac working. Remembered when you quit. If a connection fails, Scroblytics offers to switch it on for you.")
                    .font(AppTypography.supporting)
                    .foregroundStyle(.secondary)
                HelpLinkButton(articleID: "offline-mode", title: "What Offline mode does")
            }

            PrivacySettingsSection()
            SupportSettingsSection()

            UpdateSettingsSection()

            Section("Dates") {
                Picker("Week starts on", selection: $weekStartDay) {
                    ForEach(WeekStart.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .onChange(of: weekStartDay) { NotificationCenter.default.post(name: .weekStartDidChange, object: nil) }

                Text("Used wherever the app groups plays into weeks: Timeline, Trends, Active weeks, “this week” in Query and Ask, and Time Machine. Last.fm’s own weeks start on Friday. Changing it never alters your data.")
                    .font(AppTypography.supporting)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
