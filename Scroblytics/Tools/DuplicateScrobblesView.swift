import SwiftUI
import SwiftData

/// "Duplicate Scrobbles": runs of plays of one song that started closer together than the song could last (see
/// `DuplicateScrobblesEngine`). Read-only: Last.fm's API can't delete a play, so each row opens the song's history on Last.fm, where the
/// extra plays can be deleted, and the usual right-click › Resync This Track then brings the app up to date.
struct DuplicateScrobblesView: View {
    let modelContainer: ModelContainer
    let navigation: DetailNavigationCoordinator
    /// Opens Query on `spec`; `detail` is the breadcrumb tooltip, the third value defaults the Save As sheet's name.
    let openQuery: (QuerySpec, String, String?) -> Void

    enum Show: String, Codable, CaseIterable, Identifiable {
        case all, certain, possible
        var id: Self { self }
        var label: String {
            switch self {
            case .all: "All"
            case .certain: "Certain"
            case .possible: "Possible"
            }
        }
    }

    enum Sort: String, Codable, CaseIterable, Identifiable {
        case mostRecent, mostExtras, smallestGap, artist
        var id: Self { self }
        var label: String {
            switch self {
            case .mostRecent: "Most Recent"
            case .mostExtras: "Most Extra Plays"
            case .smallestGap: "Smallest Gap"
            case .artist: "Artist"
            }
        }
    }

    /// Which runs the list shows: the ones still to look at, or the ones marked as reviewed.
    enum Listing: String, Codable, CaseIterable, Identifiable {
        case review, ignored
        var id: Self { self }
        var label: String { self == .review ? "To Review" : "Ignored" }
    }

    struct Options: Codable, Equatable {
        var listing = Listing.review
        var musicFilter = DuplicateScrobblesEngine.MusicFilter.all
        /// Set after Music has been read once (permission is then granted), so a later visit reads it again on open when Music is running.
        var readMusic = false
        /// Only runs whose last play is within this many days; 0 is all time.
        var windowDays = 0
        var show = Show.all
        var fallbackGapSeconds = 60
        var sort = Sort.mostRecent
    }

    private static let toolId = "duplicatescrobbles"
    private static let windowChoices = [0, 30, 90, 365]
    private static let fallbackChoices = [15, 30, 60, 90, 120]

    @Environment(\.modelContext) private var modelContext
    @State private var options = Options()
    @State private var result: DuplicateScrobblesEngine.Result?
    @State private var imageLookup: [String: String] = [:]
    @State private var username: String?
    @State private var ignoredRuns = DuplicateScrobblesEngine.IgnoredRuns()
    @State private var confirmingBulk = false
    @State private var musicTotals: [String: DuplicateScrobblesEngine.MusicTotals]?
    @State private var isReadingMusic = false
    @State private var musicError: String?
    @State private var isLoading = true
    @State private var errorMessage: String?

    /// The runs that pass the List, Period, Apple Music and Show choices.
    private var shownRuns: [DuplicateScrobblesEngine.Cluster] {
        guard let result else { return [] }
        let cutoff = options.windowDays > 0 ? Date().addingTimeInterval(-Double(options.windowDays) * 86_400) : nil
        return DuplicateScrobblesEngine.visible(result.clusters, ignoredRuns: ignoredRuns, ignored: options.listing == .ignored).filter { cluster in
            if let cutoff, cluster.last < cutoff { return false }
            if let musicTotals, options.musicFilter != .all,
               !options.musicFilter.includes(DuplicateScrobblesEngine.compare(scrobbles: cluster.totalScrobbles, music: musicTotals[cluster.key])) { return false }
            switch options.show {
            case .all: return true
            case .certain: return cluster.confidence == .certain
            case .possible: return cluster.confidence == .possible
            }
        }
    }

    /// The runs grouped by song, in the chosen order.
    private var songs: [DuplicateScrobblesEngine.SongGroup] {
        var groups = DuplicateScrobblesEngine.groups(shownRuns)
        switch options.sort {
        case .mostRecent: break
        case .mostExtras: groups.sort { ($0.extraPlays, $0.last) > ($1.extraPlays, $1.last) }
        case .smallestGap: groups.sort { ($0.smallestGap, $1.last) < ($1.smallestGap, $0.last) }
        case .artist: groups.sort { ($0.artist.lowercased(), $0.track.lowercased()) < ($1.artist.lowercased(), $1.track.lowercased()) }
        }
        return groups
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageSettingsHeader("Duplicate Scrobbles") {
                    ToolControlsFlow { controls }
                }
                summaryRow
                if let musicError {
                    Text(musicError).font(AppTypography.compactMetadata).foregroundStyle(.orange)
                }
                if !songs.isEmpty {
                    Text("Last.fm doesn’t let apps delete plays. Open a song on Last.fm to delete the extra plays there, then right-click it here and choose Resync This Track. The first play of each run is the one to keep.")
                        .font(AppTypography.compactMetadata)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    list
                } else if isLoading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 240)
                } else if let errorMessage {
                    ContentUnavailableView("Couldn’t load", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else if options.listing == .ignored {
                    ContentUnavailableView(
                        "Nothing ignored", systemImage: "eye.slash",
                        description: Text("Runs you mark as reviewed with the eye button are listed here, and can be put back.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    ContentUnavailableView(
                        "No duplicate plays to review", systemImage: "checkmark.circle",
                        description: Text(reviewedCount > 0
                            ? "Everything found has been marked as reviewed (\(reviewedCount.formatted()) in Ignored)."
                            : "No song was played again sooner than it could have finished. Try a wider period, or a longer gap for songs whose length isn’t known.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(16)
        }
        .navigationTitle("Duplicate Scrobbles")
        .task {
            options = ToolFilterSettingsStore.load(Options.self, toolId: Self.toolId, context: modelContext, default: Options())
            ignoredRuns = ToolFilterSettingsStore.load(DuplicateScrobblesEngine.IgnoredRuns.self, toolId: DuplicateScrobblesEngine.ignoredToolId, context: modelContext, default: .init())
            username = LastfmCredentialsStore.load()?.username
            await recompute()
            if options.readMusic { await readMusic(quietly: true) }
        }
        .onChange(of: options) { old, new in
            ToolFilterSettingsStore.save(new, toolId: Self.toolId, context: modelContext)
            // Only the fixed gap changes what is found; the rest just re-filters what is held.
            if old.fallbackGapSeconds != new.fallbackGapSeconds { Task { await recompute() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in Task { await recompute() } }
        .onReceive(NotificationCenter.default.publisher(for: .targetedSyncDidFinish)) { _ in Task { await recompute() } }
    }

    @ViewBuilder
    private var controls: some View {
        Picker("List", selection: $options.listing) {
            ForEach(Listing.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        .help("To Review: runs you haven’t marked. Ignored: runs you marked as reviewed, needing no action.")
        Picker("Period", selection: $options.windowDays) {
            ForEach(Self.windowChoices, id: \.self) { Text($0 == 0 ? "All time" : "Last \($0) days").tag($0) }
        }
        .fixedSize()
        Picker("Show", selection: $options.show) {
            ForEach(Show.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        .help("Certain: closer together than Last.fm lets two plays of a song be (half its length, or 4 minutes). Possible: closer than 90% of its length, or, when no length is known, under the fixed gap.")
        if musicTotals != nil {
            Picker("Apple Music", selection: $options.musicFilter) {
                ForEach(DuplicateScrobblesEngine.MusicFilter.allCases) { Text($0 == .all ? "Apple Music: all" : $0.label).tag($0) }
            }
            .fixedSize()
            .help("Compare each song’s total scrobbles with its Apple Music play count. Counts that agree suggest the song really was played that many times; more scrobbles than plays is what a double submit looks like.")
        }
        Picker("Gap when length unknown", selection: $options.fallbackGapSeconds) {
            ForEach(Self.fallbackChoices, id: \.self) { Text("Unknown length: under \($0) s").tag($0) }
        }
        .fixedSize()
        Picker("Sort", selection: $options.sort) {
            ForEach(Sort.allCases) { Text($0.label).tag($0) }
        }
        .fixedSize()
    }

    /// How many of the runs found are marked as reviewed (whatever the Period and Show choices are).
    private var reviewedCount: Int {
        guard let result else { return 0 }
        return DuplicateScrobblesEngine.visible(result.clusters, ignoredRuns: ignoredRuns, ignored: true).count
    }

    private var summaryRow: some View {
        let shown = shownRuns
        let groups = DuplicateScrobblesEngine.groups(shown)
        let extras = shown.reduce(0) { $0 + $1.extraPlays }
        let reviewing = options.listing == .review
        return HStack {
            if result != nil {
                Text(DuplicateScrobblesEngine.summaryLine(extras: extras, songs: groups.count, runs: shown.count, certainRuns: shown.filter { $0.confidence == .certain }.count)
                     + (reviewing && reviewedCount > 0 ? " · \(reviewedCount.formatted()) ignored" : ""))
                    .font(AppTypography.metadata.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isReadingMusic { ProgressView().controlSize(.small) }
            Button {
                Task { await readMusic() }
            } label: {
                Label(musicTotals == nil ? "Compare with Apple Music" : "Read Music again", systemImage: "music.note")
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(isReadingMusic)
            .help("Reads your Music library (about a second) and shows each song’s Apple Music play count next to its total scrobbles. Music must be open, and the first read asks for permission to control it. Nothing is changed.")
            if !shown.isEmpty {
                Button(reviewing ? "Ignore All Shown…" : "Stop Ignoring All Shown…") { confirmingBulk = true }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help(reviewing ? "Mark every run in this list as reviewed, needing no action." : "Put every run in this list back in To Review.")
                    .confirmationDialog(
                        reviewing ? "Ignore \(shown.count.formatted()) \(shown.count == 1 ? "run" : "runs")?" : "Put \(shown.count.formatted()) \(shown.count == 1 ? "run" : "runs") back?",
                        isPresented: $confirmingBulk, titleVisibility: .visible
                    ) {
                        Button(reviewing ? "Ignore" : "Put Back") { setIgnored(shown, reviewing) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(reviewing
                             ? "They move to Ignored, where each can be put back. Nothing changes on Last.fm or in your history. A run that gains another play comes back for review."
                             : "They move back to To Review.")
                    }
            }
        }
    }

    private func setIgnored(_ clusters: [DuplicateScrobblesEngine.Cluster], _ ignored: Bool) {
        if ignored { ignoredRuns.ignore(clusters) } else { ignoredRuns.stopIgnoring(clusters) }
        ToolFilterSettingsStore.save(ignoredRuns, toolId: DuplicateScrobblesEngine.ignoredToolId, context: modelContext)
    }

    private var list: some View {
        LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(songs) { group in
                let album = group.album.isEmpty ? nil : group.album
                let target = ImageTarget(kind: .track, artist: group.artist, album: album, track: group.track)
                let image = ImageResolutionEngine.effectiveImageURL(for: target, lookup: imageLookup, fallbackURL: group.imageURL)
                DuplicateScrobbleRow(
                    group: group, imageURL: image, fallbackGapSeconds: options.fallbackGapSeconds, canOpenLastfm: username != nil,
                    musicRead: musicTotals != nil, music: musicTotals?[group.key],
                    isIgnored: options.listing == .ignored,
                    onToggleIgnored: { setIgnored(group.runs, options.listing == .review) },
                    onOpen: { navigation.goToTrack(TrackIdentity(artist: group.artist, name: group.track, album: album, imageURL: image)) },
                    onLastfm: { openLastfm(group) },
                    onQuery: {
                        openQuery(
                            DuplicateScrobblesEngine.spec(for: group),
                            "Duplicate Scrobbles · \(group.track) by \(group.artist)",
                            "Duplicate plays of \(group.track)"
                        )
                    }
                )
            }
        }
        .padding(.horizontal, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.4), lineWidth: 1) }
    }

    private func openLastfm(_ group: DuplicateScrobblesEngine.SongGroup) {
        guard let username, let url = LastfmUserLinks.songHistoryURL(username: username, artist: group.artist, track: group.track) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Reads Music's play counts (Music must be running; it is never launched). `quietly` is the automatic read on open: it says nothing
    /// when Music isn't open or doesn't answer.
    private func readMusic(quietly: Bool = false) async {
        guard !isReadingMusic else { return }
        isReadingMusic = true
        if !quietly { musicError = nil }
        defer { isReadingMusic = false }
        do {
            let snapshot = try await AppleMusicFavoritesReader.read(includePlayed: true)
            let library = snapshot.library
            musicTotals = await Task.detached(priority: .utility) { DuplicateScrobblesEngine.musicTotals(library: library) }.value
            musicError = nil
            options.readMusic = true
        } catch {
            if !quietly { musicError = error.localizedDescription }
        }
    }

    private func recompute() async {
        isLoading = true
        errorMessage = nil
        do {
            let plays = try await ScrobbleHistoryCache.shared.canonicalSnapshots(container: modelContainer)
            let lengths = DurationEngine.loadSnapshot(context: modelContext).secondsLookup
            let search = DuplicateScrobblesEngine.Options(fallbackGapSeconds: options.fallbackGapSeconds)
            result = await Task.detached(priority: .utility) {
                DuplicateScrobblesEngine.find(scrobbles: plays, lengths: lengths, options: search)
            }.value
            imageLookup = (try? ImageResolutionEngine.imageLookup(context: modelContext)) ?? [:]
        } catch {
            errorMessage = "\(error)"
        }
        isLoading = false
    }
}

struct DuplicateScrobbleRow: View {
    let group: DuplicateScrobblesEngine.SongGroup
    let imageURL: String?
    let fallbackGapSeconds: Int
    let canOpenLastfm: Bool
    /// Whether Music has been read, and then Music's totals for the song (nil when it isn't in the library).
    var musicRead = false
    var music: DuplicateScrobblesEngine.MusicTotals?
    let isIgnored: Bool
    let onToggleIgnored: () -> Void
    let onOpen: () -> Void
    let onLastfm: () -> Void
    let onQuery: () -> Void

    private var timeStyle: Date.FormatStyle {
        let calendar = AppCalendars.listening
        return Date.FormatStyle(date: .abbreviated, time: .standard, calendar: calendar, timeZone: calendar.timeZone)
    }

    private func color(_ run: DuplicateScrobblesEngine.Cluster) -> Color { run.confidence == .certain ? .green : .orange }

    /// One run under the song: how it reads, how sure it is, and every play with its time.
    private func runView(_ run: DuplicateScrobblesEngine.Cluster) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(run.confidence == .certain ? "Certain" : "Possible")
                    .font(AppTypography.compactMetadata.weight(.semibold))
                    .foregroundStyle(color(run))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(color(run).opacity(0.15), in: Capsule())
                Text(DuplicateScrobblesEngine.summary(run))
                    .font(AppTypography.metadata.weight(.semibold))
            }
            .padding(.bottom, 1)
            ForEach(Array(run.times.prefix(6).enumerated()), id: \.offset) { index, time in
                Text("\(index == 0 ? "Keep" : "Extra")  \(time.formatted(timeStyle))")
                    .font(AppTypography.compactMetadata.monospacedDigit())
                    .foregroundStyle(index == 0 ? .secondary : .primary)
            }
            if run.times.count > 6 {
                Text("and \(run.times.count - 6) more").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 12) {
                    EntityThumbnail(url: imageURL, entity: .track)
                        .frame(width: AppArtworkSizing.thumbnail, height: AppArtworkSizing.thumbnail)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text(group.track).font(AppTypography.contentTitle).lineLimit(1)
                            TrackLovedIndicator(artist: group.artist, track: group.track, initialValue: false, font: AppTypography.metadata)
                        }
                        Text(group.album.isEmpty ? group.artist : "\(group.artist) · \(group.album)")
                            .font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(1)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(group.runs) { runView($0) }
                        }
                        .padding(.top, 2)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            VStack(alignment: .trailing, spacing: 6) {
                Text(DuplicateScrobblesEngine.lengthText(group, fallbackGapSeconds: fallbackGapSeconds))
                    .font(AppTypography.compactMetadata.monospacedDigit()).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                if musicRead {
                    let text = DuplicateScrobblesEngine.comparisonText(scrobbles: group.totalScrobbles, music: music)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(text.counts)
                        Text(text.note).fontWeight(.semibold)
                    }
                    .font(AppTypography.compactMetadata.monospacedDigit()).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                }
                HStack(spacing: 6) {
                    Button("Query", action: onQuery)
                        .help("Open this song’s plays between its first and last run in Query.")
                    if canOpenLastfm {
                        Button("Last.fm", action: onLastfm)
                            .help("Open this song’s history on Last.fm, where plays can be deleted.")
                    }
                    Button(action: onToggleIgnored) {
                        Image(systemName: isIgnored ? "eye" : "eye.slash")
                    }
                    .help(isIgnored
                          ? "Put the runs shown here back in To Review."
                          : "I’ve reviewed the runs shown here and no action is needed: move them to Ignored. A run that gains another play, or a new run, comes back.")
                    .accessibilityLabel(isIgnored ? "Stop ignoring these runs" : "Ignore these runs")
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 4)
        .entityContextMenu(
            target: ImageTarget(kind: .track, artist: group.artist, album: group.album.isEmpty ? nil : group.album, track: group.track),
            currentImageURL: imageURL, onOpen: onOpen
        )
        Divider()
    }
}
