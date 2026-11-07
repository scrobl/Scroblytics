import SwiftUI
import SwiftData
import AppKit

/// "Unscrobbled Plays": songs Music has played more recently than their latest scrobble. Read-only: it reads the scrobble
/// history and, on request, the Music library (about a second), and changes nothing in either.
struct UnscrobbledPlaysView: View {
    let modelContainer: ModelContainer
    let navigation: DetailNavigationCoordinator

    typealias Engine = UnscrobbledPlaysEngine

    enum Group: String, Codable, CaseIterable, Identifiable {
        case notScrobbled, timeDiffers
        var id: Self { self }
        var label: String { self == .notScrobbled ? "Not scrobbled" : "Time differs" }
    }

    enum Filter: String, Codable, CaseIterable, Identifiable {
        case all, never, afterLast
        var id: Self { self }
        var label: String {
            switch self {
            case .all: "All"
            case .never: "Never scrobbled"
            case .afterLast: "Played after its last scrobble"
            }
        }
        func matches(_ row: Engine.Row) -> Bool {
            switch self {
            case .all: true
            case .never: row.kind == .neverScrobbled
            case .afterLast: row.kind == .playedAfterLastScrobble
            }
        }
    }

    /// How far back Music's last play may be.
    enum Period: String, Codable, CaseIterable, Identifiable {
        case anyTime, year, quarter, month, fortnight
        var id: Self { self }
        var label: String {
            switch self {
            case .anyTime: "Any time"
            case .year: "Last 12 months"
            case .quarter: "Last 90 days"
            case .month: "Last 30 days"
            case .fortnight: "Last 14 days"
            }
        }
        var days: Int? {
            switch self {
            case .anyTime: nil
            case .year: 365
            case .quarter: 90
            case .month: 30
            case .fortnight: 14
            }
        }
    }

    enum Sort: String, Codable, CaseIterable, Identifiable {
        case lastPlayed, gap, artist
        var id: Self { self }
        var label: String {
            switch self {
            case .lastPlayed: "Last played in Music"
            case .gap: "Largest gap"
            case .artist: "Artist"
            }
        }
    }

    struct Options: Codable, Equatable {
        var group = Group.notScrobbled
        var filter = Filter.all
        var period = Period.anyTime
        var sort = Sort.lastPlayed
        /// Treat differently written titles ("(feat. …)", "(Acoustic)") as the same song, the way the rest of the app matches songs.
        /// Off, only an identical artist and title counts, so a song scrobbled under another spelling shows up.
        var matchVariants = true
        /// Set after Music has been read once (permission is then granted), so a later visit may read it on open.
        var hasRun = false

        init() {}

        private enum CodingKeys: String, CodingKey { case group, filter, period, sort, matchVariants, hasRun }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(group, forKey: .group)
            try values.encode(filter, forKey: .filter)
            try values.encode(period, forKey: .period)
            try values.encode(sort, forKey: .sort)
            try values.encode(matchVariants, forKey: .matchVariants)
            try values.encode(hasRun, forKey: .hasRun)
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            group = (try? values.decodeIfPresent(Group.self, forKey: .group)) ?? .notScrobbled
            filter = (try? values.decodeIfPresent(Filter.self, forKey: .filter)) ?? .all
            period = (try? values.decodeIfPresent(Period.self, forKey: .period)) ?? .anyTime
            sort = (try? values.decodeIfPresent(Sort.self, forKey: .sort)) ?? .lastPlayed
            matchVariants = (try? values.decodeIfPresent(Bool.self, forKey: .matchVariants)) ?? true
            hasRun = (try? values.decodeIfPresent(Bool.self, forKey: .hasRun)) ?? false
        }
    }

    private static let toolId = "unscrobbledPlays"

    @Environment(\.modelContext) private var modelContext
    @State private var options = Options()
    @State private var didLoad = false
    @State private var inputs: Engine.Inputs?
    @State private var result: Engine.Result?
    @State private var isReading = false
    @State private var errorMessage: String?
    @State private var showingScrobble = false

    /// The plays in the current Not scrobbled view that could be submitted to Last.fm now.
    private var scrobblable: [UnscrobbledPlaysScrobbling.Play] {
        options.group == .notScrobbled ? UnscrobbledPlaysScrobbling.eligible(visible) : []
    }

    /// The rows a view lists: the Show filter (Not scrobbled only) and the Played period applied, in the chosen order.
    nonisolated static func listed(
        _ rows: [Engine.Row], group: Group, filter: Filter, period: Period, sort: Sort, now: Date = Date()
    ) -> [Engine.Row] {
        let cutoff = period.days.map { now.addingTimeInterval(-Double($0) * 86_400) }
        let kept = rows.filter { row in
            (group == .timeDiffers || filter.matches(row)) && (cutoff.map { row.musicLastPlayed >= $0 } ?? true)
        }
        switch sort {
        case .lastPlayed: return kept.sorted { $0.musicLastPlayed > $1.musicLastPlayed }
        case .gap: return kept.sorted { ($0.gap ?? .infinity) > ($1.gap ?? .infinity) }
        case .artist: return kept.sorted { ($0.artist.lowercased(), $0.track.lowercased()) < ($1.artist.lowercased(), $1.track.lowercased()) }
        }
    }

    private var visible: [Engine.Row] {
        guard let result else { return [] }
        return Self.listed(
            options.group == .notScrobbled ? result.notScrobbled : result.timeDiffers,
            group: options.group, filter: options.filter, period: options.period, sort: options.sort
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                PageSettingsHeader("Unscrobbled Plays") { controls }
                if let result {
                    headline(result)
                    tooRecentSection(result)
                    list(result)
                } else if isReading {
                    ProgressView("Reading Music…").frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    startCard
                }
            }
            .padding(16)
        }
        .navigationTitle("Unscrobbled Plays")
        .task {
            guard !didLoad else { return }
            options = ToolFilterSettingsStore.load(Options.self, toolId: Self.toolId, context: modelContext, default: Options())
            didLoad = true
            if options.hasRun, AppleMusicFavoritesReader.isMusicRunning { await readMusic() }
        }
        .onChange(of: options) { _, new in
            guard didLoad else { return }
            ToolFilterSettingsStore.save(new, toolId: Self.toolId, context: modelContext)
        }
        .onChange(of: options.matchVariants) { Task { await recompute() } }
        .sheet(isPresented: $showingScrobble) {
            UnscrobbledPlaysScrobbleSheet(plays: scrobblable) { accepted in
                guard !accepted.isEmpty else { return }
                Task {
                    await recompute()
                    // The plays are dated up to two weeks back, so the sync's re-check of recent days is what brings them in.
                    try? await Task.sleep(for: .seconds(2))
                    NotificationCenter.default.post(name: .syncRequested, object: nil)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in
            if inputs != nil, AppleMusicFavoritesReader.isMusicRunning { Task { await readMusic() } }
        }
    }

    // MARK: Controls

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { controlItems }
            VStack(alignment: .leading, spacing: 10) { controlItems }
        }
    }

    @ViewBuilder
    private var controlItems: some View {
        Picker("Group", selection: $options.group) {
            ForEach(Group.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        .fixedSize()
        if options.group == .notScrobbled {
            Picker("Show", selection: $options.filter) {
                ForEach(Filter.allCases) { Text($0.label).tag($0) }
            }
            .fixedSize()
        }
        Picker("Played", selection: $options.period) {
            ForEach(Period.allCases) { Text($0.label).tag($0) }
        }
        .fixedSize()
        .help("When Music last played the song. Last.fm accepts a scrobble only for a play from about the last 14 days, so Last 14 days is the set that could still be added.")
        Picker("Sort", selection: $options.sort) {
            ForEach(Sort.allCases) { Text($0.label).tag($0) }
        }
        .fixedSize()
        Toggle("Match spelling variants", isOn: $options.matchVariants)
            .toggleStyle(.checkbox)
            .help("On: a song scrobbled as “Title (feat. …)”, “Title (Acoustic)” or a year-tagged version counts as the same song, as everywhere else in the app. Off: only the identical artist and title counts, so songs scrobbled under another spelling are listed (with how they were scrobbled), which helps if you want to clean those up.")
        Spacer(minLength: 0)
        if isReading { ProgressView().controlSize(.small) }
        if options.group == .notScrobbled, inputs != nil {
            Button {
                showingScrobble = true
            } label: {
                Label(scrobblable.isEmpty ? "Scrobble…" : "Scrobble \(scrobblable.count.formatted())…", systemImage: "arrow.up.circle")
            }
            .disabled(scrobblable.isEmpty)
            .help(scrobblable.isEmpty
                ? "Nothing in this view can be scrobbled now: Last.fm takes plays from about the last 14 days. Set Played to Last 14 days to see them."
                : "Review these plays and submit them to Last.fm, timestamped with the time Music last played each song. You confirm the exact list first.")
        }
        Button {
            Task { await readMusic() }
        } label: {
            Label(inputs != nil ? "Read Music again" : "Read Music", systemImage: "arrow.clockwise")
        }
        .disabled(isReading)
        .help("Reads your Music library (about a second) and compares each song’s last play with your scrobbles. Nothing is changed.")
    }

    // MARK: Headline

    private func headline(_ result: Engine.Result) -> some View {
        ToolHeadlineCard("UNSCROBBLED PLAYS") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 14) {
                    Label("\(result.notScrobbled.count.formatted()) not scrobbled", systemImage: "exclamationmark.circle")
                    Label("\(result.timeDiffers.count.formatted()) with a time difference", systemImage: "clock.badge.exclamationmark")
                }
                .font(AppTypography.contentTitle)
                Text(summary(result))
                    .font(AppTypography.compactMetadata).fontWeight(.regular).foregroundStyle(.secondary)
                if let clusters = clusterLine(result) {
                    Text(clusters).font(AppTypography.compactMetadata).fontWeight(.regular).foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Text(errorMessage).font(AppTypography.compactMetadata).fontWeight(.regular).foregroundStyle(.orange)
                }
            }
        }
    }

    /// The songs played too recently to judge, collapsed under the headline, with a way to sync so they can be judged.
    @ViewBuilder
    private func tooRecentSection(_ result: Engine.Result) -> some View {
        if !result.tooRecentSongs.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Music played these in the last few minutes before your last sync\(result.judgedBefore.map { " (anything after \($0.formatted(date: .omitted, time: .shortened)))" } ?? ""), so Last.fm’s scrobbles may not be in your history yet. Sync, then Read Music again: once a sync runs about 5 minutes after a play, it is judged.")
                        .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                    ForEach(result.tooRecentSongs.prefix(20)) { song in
                        HStack(alignment: .firstTextBaseline) {
                            Text(song.track).lineLimit(1)
                            Text(song.artist).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 8)
                            Text("Music: " + song.musicLastPlayed.formatted(date: .omitted, time: .shortened)
                                 + (song.lastScrobble.map { " · scrobbled: " + $0.formatted(date: .abbreviated, time: .shortened) } ?? " · never scrobbled"))
                                .font(AppTypography.compactMetadata.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .font(AppTypography.metadata)
                    }
                    if result.tooRecentSongs.count > 20 {
                        Text("and \(result.tooRecentSongs.count - 20) more").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                    }
                    Button("Sync Now") { NotificationCenter.default.post(name: .syncRequested, object: nil) }
                        .controlSize(.small)
                }
                .padding(.top, 6)
            } label: {
                Label("\(result.tooRecentSongs.count.formatted()) \(result.tooRecentSongs.count == 1 ? "song" : "songs") played too recently to judge", systemImage: "hourglass")
                    .font(AppTypography.metadata)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.4), lineWidth: 1) }
        }
    }

    private func summary(_ result: Engine.Result) -> String {
        var parts = ["\(result.compared.formatted()) songs compared", "\(result.upToDate.formatted()) agree"]
        let canScrobble = UnscrobbledPlaysScrobbling.eligible(result.notScrobbled).count
        if canScrobble > 0 { parts.append("\(canScrobble.formatted()) can still be scrobbled (Last.fm takes plays from about the last 14 days)") }
        if result.submittedWaiting > 0 { parts.append("\(result.submittedWaiting.formatted()) just submitted, waiting for the next sync") }
        if result.tooRecent > 0 { parts.append("\(result.tooRecent.formatted()) too recent to judge (listed below)") }
        if result.beforeFirstScrobble > 0 {
            let when = result.firstScrobble.map { " (your first scrobble is \($0.formatted(.dateTime.month(.abbreviated).year())))" } ?? ""
            parts.append("\(result.beforeFirstScrobble.formatted()) last played in Music before you started scrobbling\(when), so not counted")
        }
        parts.append(result.matchVariants ? "spelling variants count as the same song" : "only identical titles count as the same song")
        return parts.joined(separator: " · ")
    }

    /// Where the not-scrobbled songs bunch up (a scrobbler that went quiet leaves a cluster), when there are enough to say.
    private func clusterLine(_ result: Engine.Result) -> String? {
        guard result.notScrobbled.count >= 6 else { return nil }
        let top = Engine.byMonth(result.notScrobbled).filter { $0.count >= 3 }.sorted { ($0.count, $0.month) > ($1.count, $1.month) }.prefix(3)
        guard !top.isEmpty else { return nil }
        return "Last played in Music mostly in " + top.map { "\($0.month.formatted(.dateTime.month(.abbreviated).year())) (\($0.count.formatted()))" }.joined(separator: ", ")
    }

    @ViewBuilder
    private var startCard: some View {
        ContentUnavailableView {
            Label("Find plays that weren’t scrobbled", systemImage: "clock.badge.exclamationmark")
        } description: {
            Text("Reads your Music library once, which takes about a second, and changes nothing. Music remembers when it last played each song; this lists the songs it played after their latest scrobble. Music must be open, and the first read asks for permission to control it.")
            if let errorMessage { Text(errorMessage).foregroundStyle(.orange) }
        } actions: {
            Button("Read Music") { Task { await readMusic() } }
                .buttonStyle(.borderedProminent)
                .disabled(isReading)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    // MARK: List

    @ViewBuilder
    private func list(_ result: Engine.Result) -> some View {
        let rows = visible
        if options.group == .timeDiffers {
            Text("Music’s last play and the song’s latest scrobble are a whole number of hours apart, to within a few minutes. That is the same play recorded with a clock or time-zone difference between the player and the scrobbler, not a missed play.")
                .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
        }
        if options.period == .fortnight, options.group == .notScrobbled {
            Text("These are the plays recent enough for Last.fm to still accept a scrobble (it takes plays from about the last 14 days). Older ones can’t be added.")
                .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
        }
        Text("\(rows.count.formatted()) \(rows.count == 1 ? "song" : "songs")")
            .font(AppTypography.metadata.monospacedDigit()).foregroundStyle(.secondary)
        if rows.isEmpty {
            ContentUnavailableView(
                "Nothing here", systemImage: "checkmark.circle",
                description: Text(options.group == .notScrobbled
                    ? "No song Music played is missing a scrobble in this view."
                    : "No song’s times differ by a whole number of hours in this view.")
            )
            .frame(maxWidth: .infinity, minHeight: 200)
        } else {
            card { ForEach(rows) { row in rowView(row) } }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVStack(alignment: .leading, spacing: 1) { content() }
            .padding(.horizontal, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.4), lineWidth: 1) }
    }

    private func rowView(_ row: Engine.Row) -> some View {
        ToolSongRow(
            title: row.track, subtitle: row.album.isEmpty ? row.artist : "\(row.artist) · \(row.album)",
            trailingText: (
                "Music: " + row.musicLastPlayed.formatted(date: .abbreviated, time: .shortened),
                row.lastScrobble.map { "scrobbled: " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "never scrobbled"
            ),
            searchArtist: row.artist, searchTrack: row.track,
            onOpen: row.scrobbles > 0
                ? { navigation.goToTrack(TrackIdentity(artist: row.historyArtist ?? row.artist, name: row.historyTrack ?? row.track, album: nil, imageURL: nil)) }
                : nil
        ) {
            if let hours = row.shiftHours {
                ToolBadge(text: "Time differs by \(hours) h", systemImage: "clock.badge.exclamationmark", tint: .secondary)
            } else if row.kind == .neverScrobbled {
                ToolBadge(text: "Never scrobbled", systemImage: "exclamationmark.circle", tint: .orange)
            } else if let gap = row.gap {
                ToolBadge(text: "Played \(Self.gapText(gap)) after its last scrobble", systemImage: "exclamationmark.circle", tint: .orange)
            }
            if row.shiftHours == nil, !UnscrobbledPlaysScrobbling.eligible([row]).isEmpty {
                ToolBadge(text: "Can be scrobbled", systemImage: "arrow.up.circle", tint: .green)
            }
            if row.coveredByVariant {
                ToolBadge(text: "Already scrobbled as another spelling", systemImage: "checkmark.circle", tint: .secondary)
            }
            if let variant = row.variantSpelling {
                Text("Scrobbled as \(variant)")
                    .font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1)
                    .help("This song has a scrobble under a differently written title that would count as the same song with Match spelling variants on.")
            }
            Text("\(row.musicPlays.formatted()) \(row.musicPlays == 1 ? "play" : "plays") in Music · \(row.scrobbles.formatted()) \(row.scrobbles == 1 ? "scrobble" : "scrobbles")")
                .font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1)
            if row.cloudStatus == "subscription" || row.cloudStatus == "no longer available" {
                Text(row.cloudStatus == "subscription" ? "Streaming copy" : "No longer available")
                    .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            }
        }
    }

    nonisolated static func gapText(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<3600: "\(Int((seconds / 60).rounded())) min"
        case ..<86_400: "\(Int((seconds / 3600).rounded())) h"
        case ..<(86_400 * 60): "\(Int((seconds / 86_400).rounded())) days"
        default: "\(Int((seconds / (86_400 * 30)).rounded())) months"
        }
    }

    // MARK: Data

    private func readMusic() async {
        guard !isReading else { return }
        isReading = true
        errorMessage = nil
        defer { isReading = false }
        do {
            let read = try await UnscrobbledPlaysRunner.read(container: modelContainer)
            inputs = read
            options.hasRun = true
            await recompute()
        } catch {
            // Keep whatever is on screen; the message sits in the headline (or the start card).
            errorMessage = error.localizedDescription
        }
    }

    private func recompute() async {
        guard let inputs else { return }
        let variants = options.matchVariants
        let submitted = UnscrobbledPlaysLedger.load()
        result = await Task.detached(priority: .userInitiated) { Engine.evaluate(inputs, matchVariants: variants, submitted: submitted) }.value
    }
}
