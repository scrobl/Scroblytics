import SwiftUI
import SwiftData
import AppKit

/// "Library Gaps": songs you've scrobbled that aren't in your Apple Music library — never were, or were and
/// aren't any more. Read-only against Music; the last result is saved (`LibraryPresenceEntry`), so opening the tool
/// shows it instantly and never touches Music. "Check library" re-reads Music (about a second) and updates the
/// saved status.
struct LibraryGapsView: View {
    let modelContainer: ModelContainer
    let navigation: DetailNavigationCoordinator

    enum Filter: String, Codable, CaseIterable, Identifiable {
        case all, removed, neverInLibrary, unavailable, uncertain
        var id: Self { self }
        var label: String {
            switch self {
            case .all: "All"
            case .removed: "Removed"
            case .neverInLibrary: "Never in library"
            case .unavailable: "Unavailable"
            case .uncertain: "Uncertain"
            }
        }
        func matches(_ status: LibraryGapStatus) -> Bool {
            switch self {
            case .all: status.isGap
            case .removed: status == .removed
            case .neverInLibrary: status == .neverInLibrary
            case .unavailable: status == .unavailable
            case .uncertain: status == .uncertain
            }
        }
    }

    enum Sort: String, Codable, CaseIterable, Identifiable {
        case plays, lastPlayed, artist
        var id: Self { self }
        var label: String {
            switch self {
            case .plays: "Most played"
            case .lastPlayed: "Last played"
            case .artist: "Artist"
            }
        }
    }

    struct Options: Codable, Equatable {
        var filter = Filter.all
        var sort = Sort.plays
        var groupByArtist = false
        /// Set after a successful check — Automation permission has then been granted, so a later visit may
        /// refresh without asking.
        var hasRun = false

        init() {}

        private enum CodingKeys: String, CodingKey { case filter, sort, groupByArtist, hasRun }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(filter, forKey: .filter)
            try values.encode(sort, forKey: .sort)
            try values.encode(groupByArtist, forKey: .groupByArtist)
            try values.encode(hasRun, forKey: .hasRun)
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            filter = try values.decodeIfPresent(Filter.self, forKey: .filter) ?? .all
            sort = try values.decodeIfPresent(Sort.self, forKey: .sort) ?? .plays
            groupByArtist = try values.decodeIfPresent(Bool.self, forKey: .groupByArtist) ?? false
            hasRun = try values.decodeIfPresent(Bool.self, forKey: .hasRun) ?? false
        }
    }

    private static let toolId = "libraryGaps"
    /// A refresh on open is skipped if the saved check is newer than this.
    private static let autoRefreshAfter: TimeInterval = 3600

    @Environment(\.modelContext) private var modelContext
    @Environment(LibraryGapBadgeStore.self) private var gapBadges
    @State private var options = Options()
    @State private var didLoad = false
    @State private var records: [String: LibraryPresenceRecord] = [:]
    @State private var usage: [String: LibraryTrackUsage] = [:]
    /// False from a sync until the scrobbled tracks have been read again. The list waits for it: before then the app can't
    /// tell which saved statuses still belong to a scrobbled track, and would briefly show ones that no longer do.
    @State private var usageLoaded = false
    /// `LibraryGapsEngine.key`s of the tracks the user has confirmed.
    @State private var confirmedKeys: Set<String> = []
    @State private var lastCheck: (checkedAt: Date, libraryTrackCount: Int, trackedCount: Int)?
    @State private var isLoading = true
    @State private var isChecking = false
    @State private var errorMessage: String?
    /// Artists whose group is open. Every group starts collapsed, including each time grouping is switched on.
    @State private var expandedArtists: Set<String> = []

    /// Every gap row the saved data holds, before the view's filters.
    private var gapRows: [LibraryGapRow] {
        records.values.compactMap { record in
            guard record.status.isGap else { return nil }
            let u = usage[record.matchKey]
            // A status whose track has no scrobbles any more (corrected or removed on Last.fm) isn't a gap in anything
            // you've played; the next check deletes it.
            if u == nil, usageLoaded { return nil }
            return LibraryGapRow(record: record, plays: u?.plays ?? 0, lastPlayed: u?.lastPlayed, isConfirmed: confirmedKeys.contains(record.matchKey))
        }
    }

    private var visibleRows: [LibraryGapRow] {
        let rows = gapRows.filter { options.filter.matches($0.record.status) }
        switch options.sort {
        case .plays: return rows.sorted { ($0.plays, $1.record.artist, $1.record.track) > ($1.plays, $0.record.artist, $0.record.track) }
        case .lastPlayed: return rows.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        case .artist: return rows.sorted { ($0.record.artist.lowercased(), $0.record.track.lowercased()) < ($1.record.artist.lowercased(), $1.record.track.lowercased()) }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                PageSettingsHeader("Library Gaps") { controls }
                if lastCheck != nil, !usageLoaded {
                    ProgressView("Loading…").frame(maxWidth: .infinity, minHeight: 240)
                } else if lastCheck != nil {
                    headline
                    summaryRow
                    list
                } else if isLoading || isChecking {
                    ProgressView(isChecking ? "Reading Music…" : "Loading…").frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    startCard
                }
            }
            .padding(16)
        }
        .navigationTitle("Library Gaps")
        .task {
            guard !didLoad else { return }
            options = ToolFilterSettingsStore.load(Options.self, toolId: Self.toolId, context: modelContext, default: Options())
            didLoad = true
            await reload()
            // Refresh on open only when it can't surprise: Music already open, checked before, and not just now.
            let stale = lastCheck.map { Date().timeIntervalSince($0.checkedAt) > Self.autoRefreshAfter } ?? true
            if options.hasRun, stale, AppleMusicFavoritesReader.isMusicRunning { await check() }
        }
        .onChange(of: options) { _, new in
            guard didLoad else { return }
            ToolFilterSettingsStore.save(new, toolId: Self.toolId, context: modelContext)
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in
            usage = [:]
            usageLoaded = false
            Task { await reload() }
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
        Picker("Show", selection: $options.filter) {
            ForEach(Filter.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        .disabled(lastCheck == nil)
        Picker("Sort", selection: $options.sort) {
            ForEach(Sort.allCases) { Text($0.label).tag($0) }
        }
        .fixedSize()
        .disabled(lastCheck == nil)
        Toggle("Group by artist", isOn: $options.groupByArtist).toggleStyle(.checkbox)
            .disabled(lastCheck == nil)
            .onChange(of: options.groupByArtist) { expandedArtists = [] }
        Spacer(minLength: 0)
        if isChecking { ProgressView().controlSize(.small) }
        Button {
            Task { await check() }
        } label: {
            Label(lastCheck == nil ? "Check library" : "Check again", systemImage: "arrow.clockwise")
        }
        .disabled(isChecking)
        .help("Reads your Music library (about a second) and compares it with everything you’ve scrobbled.")
    }

    // MARK: Start / headline

    @ViewBuilder
    private var startCard: some View {
        if let errorMessage {
            ContentUnavailableView {
                Label("Couldn’t check the library", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try again") { Task { await check() } }
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            ContentUnavailableView {
                Label("Find songs missing from Apple Music", systemImage: "music.note.list")
            } description: {
                Text("Compares everything you’ve scrobbled with your Apple Music library, and remembers the result so you can see what’s been removed. It reads Music once, which takes about a second, and changes nothing. The first run asks for permission to control Music.")
            } actions: {
                Button("Check library") { Task { await check() } }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        }
    }

    private var headline: some View {
        let rows = gapRows
        let count = { (status: LibraryGapStatus) in rows.filter { $0.record.status == status }.count }
        let plays = rows.reduce(0) { $0 + $1.plays }
        return ToolHeadlineCard("APPLE MUSIC LIBRARY") {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(rows.count.formatted()) scrobbled \(rows.count == 1 ? "track isn’t" : "tracks aren’t") in your library")
                HStack(spacing: 14) {
                    Label("\(count(.removed).formatted()) removed", systemImage: "minus.circle")
                    Label("\(count(.neverInLibrary).formatted()) never in library", systemImage: "circle.dashed")
                    Label("\(count(.unavailable).formatted()) unavailable", systemImage: "icloud.slash")
                    Label("\(count(.uncertain).formatted()) uncertain", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(AppTypography.contentTitle)
                if let lastCheck {
                    Text("\(plays.formatted()) plays between them · checked \(lastCheck.checkedAt.formatted(.relative(presentation: .named))) against \(lastCheck.libraryTrackCount.formatted()) library tracks")
                        .font(AppTypography.compactMetadata).fontWeight(.regular).foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Text(errorMessage).font(AppTypography.compactMetadata).fontWeight(.regular).foregroundStyle(.orange)
                }
            }
        }
    }

    private var summaryRow: some View {
        Text("\(visibleRows.count.formatted()) \(visibleRows.count == 1 ? "track" : "tracks")")
            .font(AppTypography.metadata.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        let rows = visibleRows
        if rows.isEmpty {
            ContentUnavailableView(
                options.filter == .all ? "No gaps" : "Nothing here",
                systemImage: "checkmark.circle",
                description: Text(options.filter == .all
                    ? "Everything you’ve scrobbled is in your Apple Music library."
                    : "No tracks match this view.")
            )
            .frame(maxWidth: .infinity, minHeight: 200)
        } else if options.groupByArtist {
            groupedList(rows)
        } else {
            card {
                ForEach(rows) { row in gapRow(row, showArtist: true) }
            }
        }
    }

    private func groupedList(_ rows: [LibraryGapRow]) -> some View {
        let groups = Dictionary(grouping: rows, by: \.record.artist)
        let ordered = groups.map { (artist: $0.key, rows: $0.value, plays: $0.value.reduce(0) { $0 + $1.plays }) }
            .sorted { options.sort == .artist ? $0.artist.lowercased() < $1.artist.lowercased() : ($0.plays, $1.artist) > ($1.plays, $0.artist) }
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(ordered, id: \.artist) { group in
                card {
                    Button {
                        if !expandedArtists.insert(group.artist).inserted { expandedArtists.remove(group.artist) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: expandedArtists.contains(group.artist) ? "chevron.down" : "chevron.right")
                                .font(AppTypography.denseBadge).foregroundStyle(.secondary).frame(width: 12)
                            Text(group.artist).font(AppTypography.contentTitle).lineLimit(1)
                            Spacer()
                            Text("\(group.rows.count.formatted()) \(group.rows.count == 1 ? "track" : "tracks") · \(group.plays.formatted()) plays")
                                .font(AppTypography.metadata.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 10).padding(.horizontal, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                    if expandedArtists.contains(group.artist) {
                        ForEach(group.rows) { row in gapRow(row, showArtist: false) }
                    }
                }
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVStack(alignment: .leading, spacing: 1) { content() }
            .padding(.horizontal, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.4), lineWidth: 1) }
    }

    private func gapRow(_ row: LibraryGapRow, showArtist: Bool) -> some View {
        GapRowView(
            row: row, showArtist: showArtist,
            onOpen: {
                navigation.goToTrack(TrackIdentity(artist: row.record.artist, name: row.record.track, album: nil, imageURL: nil))
            },
            onToggleConfirmed: { Task { await setConfirmed(!row.isConfirmed, row: row) } }
        )
    }

    // MARK: Data

    /// The saved status plus current play counts — never touches Music.
    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        let store = LibraryPresenceStore(modelContainer: modelContainer)
        do {
            records = try await store.records()
            confirmedKeys = try await store.confirmedKeys()
            lastCheck = try await store.lastCheck()
            if !usageLoaded, lastCheck != nil {
                let loaded = try await LibraryGapsRunner.scrobbledUsage(container: modelContainer)
                usage = Dictionary(uniqueKeysWithValues: loaded.map { ($0.matchKey, $0) })
                usageLoaded = true
            }
        } catch {
            errorMessage = error.localizedDescription
            usageLoaded = true
        }
    }

    private func check() async {
        guard !isChecking else { return }
        isChecking = true
        errorMessage = nil
        defer { isChecking = false }
        do {
            _ = try await LibraryGapsRunner.run(container: modelContainer)
            options.hasRun = true
            await reload()
            await gapBadges.load(container: modelContainer, force: true)
        } catch {
            // Keep whatever was saved on screen; the message sits in the headline (or the start card).
            errorMessage = error.localizedDescription
        }
    }

    private func setConfirmed(_ confirmed: Bool, row: LibraryGapRow) async {
        let store = LibraryPresenceStore(modelContainer: modelContainer)
        _ = try? await store.setConfirmed(confirmed, artist: row.record.artist, track: row.record.track)
        await reload()
        await gapBadges.load(container: modelContainer, force: true)
    }
}

// MARK: - Row

private struct GapRowView: View {
    let row: LibraryGapRow
    let showArtist: Bool
    let onOpen: () -> Void
    let onToggleConfirmed: () -> Void

    private var record: LibraryPresenceRecord { row.record }
    /// Only an Uncertain track can be confirmed; a confirmed one (now Never in library or Removed) can be undone.
    private var canConfirm: Bool { record.status == .uncertain }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: onOpen) { content }
                .buttonStyle(.plain)
                .drillDownHighlight()
            Button(action: searchInAppleMusic) {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Search for this track in Apple Music")
            if row.isConfirmed || canConfirm {
                Button(action: onToggleConfirmed) {
                    Image(systemName: row.isConfirmed ? "arrow.uturn.backward" : "checkmark.circle")
                }
                .buttonStyle(.borderless)
                .help(row.isConfirmed
                    ? "Undo — list this track as Uncertain again"
                    : "Confirm — I’ve checked: this track isn’t in my library. It moves to Never in library (or Removed) and gets the “not in library” mark.")
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 4)
        .entityContextMenu(
            target: ImageTarget(kind: .track, artist: record.artist, album: nil, track: record.track),
            onOpen: onOpen
        )
        Divider()
    }

    private var content: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.track).font(AppTypography.contentTitle).lineLimit(1)
                if showArtist {
                    Text(record.artist).font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(1)
                }
                if let nearMatch = record.nearMatch {
                    HStack(spacing: 6) {
                        Label("Uncertain match", systemImage: "exclamationmark.triangle.fill")
                            .font(AppTypography.supportingDense)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.orange.opacity(0.15), in: Capsule())
                        Text("Possibly the same as \(nearMatch) in your library")
                            .font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .help("Possibly the same as \(nearMatch) in your library — not counted as a confirmed gap.")
                }
            }
            Spacer(minLength: 8)
            statusLabel
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(row.plays.formatted()) \(row.plays == 1 ? "play" : "plays")")
                    .font(AppTypography.metadata.monospacedDigit())
                if let last = row.lastPlayed {
                    Text("last \(last.formatted(.dateTime.month(.abbreviated).year()))")
                        .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 80, alignment: .trailing)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch record.status {
        case .removed:
            Label {
                Text(record.lastSeenAt.map { "Removed · last seen \($0.formatted(.dateTime.month(.abbreviated).day().year()))" } ?? "Removed")
            } icon: { Image(systemName: "minus.circle") }
                .font(AppTypography.compactMetadata).foregroundStyle(.red)
        case .neverInLibrary:
            Label("Not in library", systemImage: "circle.dashed")
                .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
        case .unavailable:
            Label("No longer available", systemImage: "icloud.slash")
                .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                .help("Still listed in Music, but greyed out — Apple Music says it’s no longer available.")
        case .uncertain, .present:
            EmptyView()
        }
    }

    private func searchInAppleMusic() {
        let record = record
        Task { await AppleMusicLinks.open(kind: .track, artist: record.artist, album: nil, track: record.track) }
    }
}
