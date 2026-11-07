import SwiftUI
import SwiftData
import AppKit

/// "Songs Without Albums": songs with no album at all, and albums that hold just one song. Read-only: it reads the
/// scrobble history and, on request, the Music library (about a second), and changes nothing in either.
struct SongsWithoutAlbumsView: View {
    let modelContainer: ModelContainer
    let navigation: DetailNavigationCoordinator

    typealias Engine = SongsWithoutAlbumsEngine

    enum Group: String, Codable, CaseIterable, Identifiable {
        case noAlbum, alone
        var id: Self { self }
        var label: String { self == .noAlbum ? "No album" : "Alone on an album" }
    }

    enum NoAlbumFilter: String, Codable, CaseIterable, Identifiable {
        case all, inMusic, inHistory, hasLikelyAlbum
        var id: Self { self }
        var label: String {
            switch self {
            case .all: "All"
            case .inMusic: "In Music"
            case .inHistory: "In scrobbles"
            case .hasLikelyAlbum: "Album known"
            }
        }
        func matches(_ row: Engine.NoAlbumRow) -> Bool {
            switch self {
            case .all: true
            case .inMusic: row.emptyInMusic
            case .inHistory: row.albumlessPlays > 0
            case .hasLikelyAlbum: !row.hints.isEmpty
            }
        }
    }

    enum AloneFilter: String, Codable, CaseIterable, Identifiable {
        case all, singles, onAnotherAlbum, anotherEdition
        var id: Self { self }
        var label: String {
            switch self {
            case .all: "All"
            case .singles: "Singles"
            case .onAnotherAlbum: "Also on another album"
            case .anotherEdition: "Looks like another edition"
            }
        }
        func matches(_ row: Engine.AloneRow) -> Bool {
            switch self {
            case .all: true
            case .singles: row.isSingle
            case .onAnotherAlbum: !row.hints.isEmpty
            case .anotherEdition: !row.siblings.isEmpty
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
        var group = Group.noAlbum
        var noAlbumFilter = NoAlbumFilter.all
        var aloneFilter = AloneFilter.all
        var sort = Sort.plays
        /// Leave out singles (a release known to have one track, or an album named after its song when no tracklist is known), which aren't a problem.
        var hideSingles = true
        /// Set after Music has been read once (permission is then granted), so a later visit may read it on open.
        var hasRun = false

        init() {}

        private enum CodingKeys: String, CodingKey { case group, noAlbumFilter, aloneFilter, sort, hideSingles, hasRun }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(group, forKey: .group)
            try values.encode(noAlbumFilter, forKey: .noAlbumFilter)
            try values.encode(aloneFilter, forKey: .aloneFilter)
            try values.encode(sort, forKey: .sort)
            try values.encode(hideSingles, forKey: .hideSingles)
            try values.encode(hasRun, forKey: .hasRun)
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            group = (try? values.decodeIfPresent(Group.self, forKey: .group)) ?? .noAlbum
            noAlbumFilter = (try? values.decodeIfPresent(NoAlbumFilter.self, forKey: .noAlbumFilter)) ?? .all
            aloneFilter = (try? values.decodeIfPresent(AloneFilter.self, forKey: .aloneFilter)) ?? .all
            sort = (try? values.decodeIfPresent(Sort.self, forKey: .sort)) ?? .plays
            hideSingles = (try? values.decodeIfPresent(Bool.self, forKey: .hideSingles)) ?? true
            hasRun = (try? values.decodeIfPresent(Bool.self, forKey: .hasRun)) ?? false
        }
    }

    private static let toolId = "songsWithoutAlbums"

    @Environment(\.modelContext) private var modelContext
    @State private var options = Options()
    @State private var didLoad = false
    @State private var result: Engine.Result?
    @State private var isLoading = true
    @State private var isReadingMusic = false
    @State private var errorMessage: String?

    private var musicRead: Bool { result?.musicTracks != nil }

    private var visibleNoAlbum: [Engine.NoAlbumRow] {
        let rows = (result?.noAlbum ?? []).filter { options.noAlbumFilter.matches($0) }
        switch options.sort {
        case .plays: return rows.sorted { ($0.totalPlays, $1.artist, $1.track) > ($1.totalPlays, $0.artist, $0.track) }
        case .lastPlayed: return rows.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        case .artist: return rows.sorted { ($0.artist.lowercased(), $0.track.lowercased()) < ($1.artist.lowercased(), $1.track.lowercased()) }
        }
    }

    /// The albums a view lists: those the filter matches, minus the singles when they are hidden. The Singles view is the
    /// singles themselves, so hiding never applies to it.
    nonisolated static func listed(_ rows: [Engine.AloneRow], filter: AloneFilter, hideSingles: Bool) -> [Engine.AloneRow] {
        let hiding = hideSingles && filter != .singles
        return rows.filter { filter.matches($0) && !(hiding && $0.isSingle) }
    }

    private var visibleAlone: [Engine.AloneRow] {
        let rows = Self.listed(result?.alone ?? [], filter: options.aloneFilter, hideSingles: options.hideSingles)
        switch options.sort {
        case .plays: return rows.sorted { ($0.plays, $1.artist, $1.album) > ($1.plays, $0.artist, $0.album) }
        case .lastPlayed: return rows.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        case .artist: return rows.sorted { ($0.artist.lowercased(), $0.album.lowercased()) < ($1.artist.lowercased(), $1.album.lowercased()) }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                PageSettingsHeader("Songs Without Albums") { controls }
                if isLoading, result == nil {
                    ProgressView("Loading…").frame(maxWidth: .infinity, minHeight: 240)
                } else if result != nil {
                    headline
                    if options.group == .noAlbum {
                        if !musicRead { musicNote }
                        noAlbumList
                    } else if musicRead {
                        aloneList
                    } else {
                        startCard
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Songs Without Albums")
        .task {
            guard !didLoad else { return }
            options = ToolFilterSettingsStore.load(Options.self, toolId: Self.toolId, context: modelContext, default: Options())
            didLoad = true
            await loadHistory()
            if options.hasRun, AppleMusicFavoritesReader.isMusicRunning { await readMusic() }
        }
        .onChange(of: options) { _, new in
            guard didLoad else { return }
            ToolFilterSettingsStore.save(new, toolId: Self.toolId, context: modelContext)
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in
            Task { musicRead ? await readMusic() : await loadHistory() }
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
        if options.group == .noAlbum {
            Picker("Show", selection: $options.noAlbumFilter) {
                ForEach(NoAlbumFilter.allCases) { Text($0.label).tag($0) }
            }
            .fixedSize()
        } else {
            Picker("Show", selection: $options.aloneFilter) {
                ForEach(AloneFilter.allCases) { Text($0.label).tag($0) }
            }
            .fixedSize()
            .disabled(!musicRead)
            Toggle("Hide singles", isOn: $options.hideSingles)
                .toggleStyle(.checkbox)
                .disabled(!musicRead || options.aloneFilter == .singles)
                .help("Leave out singles: a release whose tracklist has one track, or, when no tracklist is known, an album named after its song.")
        }
        Picker("Sort", selection: $options.sort) {
            ForEach(Sort.allCases) { Text($0.label).tag($0) }
        }
        .fixedSize()
        Spacer(minLength: 0)
        if isReadingMusic { ProgressView().controlSize(.small) }
        Button {
            Task { await readMusic() }
        } label: {
            Label(musicRead ? "Read Music again" : "Read Music", systemImage: "arrow.clockwise")
        }
        .disabled(isReadingMusic)
        .help("Reads your Music library (about a second) and compares it with everything you’ve scrobbled. Nothing is changed.")
    }

    // MARK: Headline

    private var headline: some View {
        let noAlbum = result?.noAlbum ?? []
        let alone = result?.alone ?? []
        let singles = alone.filter(\.isSingle).count
        let confirmedSingles = alone.filter { $0.singleBasis == .tracklist }.count
        let listed = options.hideSingles ? alone.count - singles : alone.count
        return ToolHeadlineCard("SONGS WITHOUT ALBUMS") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 14) {
                    Label("\(noAlbum.count.formatted()) with no album", systemImage: "questionmark.square.dashed")
                    if musicRead {
                        Label("\(listed.formatted()) alone on an album", systemImage: "square.stack")
                    }
                }
                .font(AppTypography.contentTitle)
                if let result {
                    let inMusic = noAlbum.filter(\.emptyInMusic).count
                    let scrobbled = noAlbum.reduce(0) { $0 + $1.albumlessPlays }
                    if let tracks = result.musicTracks, let albums = result.musicAlbums {
                        Text("\(inMusic.formatted()) in Music with an empty Album · \(scrobbled.formatted()) \(scrobbled == 1 ? "scrobble" : "scrobbles") with no album name · \(alone.count.formatted()) of \(albums.formatted()) library albums hold one song, \(singles.formatted()) of them are singles (\(confirmedSingles.formatted()) confirmed by a tracklist, the rest judged by name)\(options.hideSingles ? " and hidden" : "") · read \(result.checkedAt.formatted(.relative(presentation: .named))) from \(tracks.formatted()) library songs")
                            .font(AppTypography.compactMetadata).fontWeight(.regular).foregroundStyle(.secondary)
                    } else {
                        Text("\(scrobbled.formatted()) \(scrobbled == 1 ? "scrobble" : "scrobbles") with no album name. Read Music to also check your library.")
                            .font(AppTypography.compactMetadata).fontWeight(.regular).foregroundStyle(.secondary)
                    }
                }
                if let errorMessage {
                    Text(errorMessage).font(AppTypography.compactMetadata).fontWeight(.regular).foregroundStyle(.orange)
                }
            }
        }
    }

    private var musicNote: some View {
        Text("Showing scrobbles only. Press Read Music to also look for songs in your library whose Album is empty.")
            .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var startCard: some View {
        ContentUnavailableView {
            Label("Find albums that hold one song", systemImage: "square.stack")
        } description: {
            Text("Reads your Music library once, which takes about a second, and changes nothing. Albums are told apart by their album artist, so the tracks of a compilation aren’t counted as separate albums. The first run asks for permission to control Music.")
        } actions: {
            Button("Read Music") { Task { await readMusic() } }
                .buttonStyle(.borderedProminent)
                .disabled(isReadingMusic)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    // MARK: Lists

    @ViewBuilder
    private var noAlbumList: some View {
        let rows = visibleNoAlbum
        Text("\(rows.count.formatted()) \(rows.count == 1 ? "song" : "songs")")
            .font(AppTypography.metadata.monospacedDigit()).foregroundStyle(.secondary)
        if rows.isEmpty {
            ContentUnavailableView(
                options.noAlbumFilter == .all ? "Every song has an album" : "Nothing here",
                systemImage: "checkmark.circle",
                description: Text(options.noAlbumFilter == .all
                    ? (musicRead ? "No song in Music has an empty Album, and no scrobble is missing its album name." : "No scrobble is missing its album name.")
                    : "No songs match this view.")
            )
            .frame(maxWidth: .infinity, minHeight: 200)
        } else {
            card { ForEach(rows) { row in noAlbumRow(row) } }
        }
    }

    @ViewBuilder
    private var aloneList: some View {
        let rows = visibleAlone
        let hiddenSingles = options.hideSingles && options.aloneFilter != .singles ? (result?.alone ?? []).filter { options.aloneFilter.matches($0) && $0.isSingle }.count : 0
        if options.aloneFilter == .singles {
            Text("Showing only the singles, so Hide singles doesn’t apply here. Choose Show: All to leave them out.")
                .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
        }
        Text("\(rows.count.formatted()) \(rows.count == 1 ? "album" : "albums")\(hiddenSingles > 0 ? " · \(hiddenSingles.formatted()) \(hiddenSingles == 1 ? "single" : "singles") hidden" : "")")
            .font(AppTypography.metadata.monospacedDigit()).foregroundStyle(.secondary)
        if rows.isEmpty {
            ContentUnavailableView(
                options.aloneFilter == .all ? "No one-song albums to look at" : "Nothing here",
                systemImage: "checkmark.circle",
                description: Text(options.aloneFilter == .all
                    ? (hiddenSingles > 0 ? "Every other album in your library holds more than one song. Turn off Hide singles to see the \(hiddenSingles.formatted()) \(hiddenSingles == 1 ? "single" : "singles")." : "Every album in your library holds more than one song.")
                    : "No albums match this view.")
            )
            .frame(maxWidth: .infinity, minHeight: 200)
        } else {
            card { ForEach(rows) { row in aloneRow(row) } }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVStack(alignment: .leading, spacing: 1) { content() }
            .padding(.horizontal, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.4), lineWidth: 1) }
    }

    private func noAlbumRow(_ row: Engine.NoAlbumRow) -> some View {
        SongRow(
            title: row.track, subtitle: row.artist, plays: row.totalPlays, lastPlayed: row.lastPlayed,
            searchArtist: row.artist, searchTrack: row.track,
            onOpen: row.totalPlays > 0 ? { navigation.goToTrack(TrackIdentity(artist: row.artist, name: row.track, album: nil, imageURL: nil)) } : nil
        ) {
            if row.emptyInMusic {
                Badge(text: "Empty Album in Music", systemImage: "music.note", tint: .orange)
            }
            if row.albumlessPlays > 0 {
                Badge(text: "\(row.albumlessPlays.formatted()) \(row.albumlessPlays == 1 ? "play" : "plays") with no album name", systemImage: "questionmark.circle", tint: .secondary)
            }
            if let first = row.hints.first {
                let more = row.hints.count - 1
                Text("Elsewhere on \(first.album)\(more > 0 ? " and \(more) more" : "")\(first.plays > 0 ? " · \(first.plays.formatted()) plays" : "")")
                    .font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1)
                    .help(row.hints.map { "\($0.album)\($0.plays > 0 ? " · \($0.plays) plays" : "")\($0.inMusic ? " · in Music" : "")" }.joined(separator: "\n"))
            }
        }
    }

    private func aloneRow(_ row: Engine.AloneRow) -> some View {
        SongRow(
            title: row.album, subtitle: "\(row.artist) · \(row.track)", plays: row.plays, lastPlayed: row.lastPlayed,
            searchArtist: row.trackArtist, searchTrack: row.track,
            onOpen: row.plays > 0 ? { navigation.goToTrack(TrackIdentity(artist: row.trackArtist, name: row.track, album: row.album, imageURL: nil)) } : nil
        ) {
            switch row.singleBasis {
            case .tracklist?:
                Badge(text: "Single · its tracklist has 1 track", systemImage: "checkmark.seal", tint: .secondary)
            case .name?:
                Badge(text: "Likely single · named after the song", systemImage: "music.note", tint: .secondary)
            case nil:
                if let count = row.knownTrackCount {
                    Badge(text: "Album has \(count.formatted()) tracks · 1 in Music", systemImage: "square.stack.3d.up", tint: .orange)
                }
            }
            if let sibling = row.siblings.first {
                Badge(text: "Maybe the same as “\(sibling.album)” (\(sibling.songs.formatted()) \(sibling.songs == 1 ? "song" : "songs"))", systemImage: "exclamationmark.triangle.fill", tint: .orange)
            }
            if let first = row.hints.first {
                let more = row.hints.count - 1
                Text("Also on \(first.album)\(more > 0 ? " and \(more) more" : "")")
                    .font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1)
                    .help(row.hints.map { "\($0.album)\($0.plays > 0 ? " · \($0.plays) plays" : "")\($0.inMusic ? " · in Music" : "")" }.joined(separator: "\n"))
            }
            if row.cloudStatus == "subscription" || row.cloudStatus == "no longer available" {
                Text(row.cloudStatus == "subscription" ? "Streaming copy" : "No longer available")
                    .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Data

    /// The scrobble part only; never touches Music.
    private func loadHistory() async {
        isLoading = true
        defer { isLoading = false }
        do {
            result = try await SongsWithoutAlbumsRunner.historyOnly(container: modelContainer)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func readMusic() async {
        guard !isReadingMusic else { return }
        isReadingMusic = true
        errorMessage = nil
        defer { isReadingMusic = false }
        do {
            result = try await SongsWithoutAlbumsRunner.run(container: modelContainer)
            options.hasRun = true
        } catch {
            // Keep whatever is on screen; the message sits in the headline.
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Row pieces

private struct Badge: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(AppTypography.supportingDense)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

private struct SongRow<Details: View>: View {
    let title: String
    let subtitle: String
    let plays: Int
    let lastPlayed: Date?
    let searchArtist: String
    let searchTrack: String
    let onOpen: (() -> Void)?
    @ViewBuilder let details: Details

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let onOpen {
                Button(action: onOpen) { content }
                    .buttonStyle(.plain)
                    .drillDownHighlight()
            } else {
                content
            }
            Button {
                Task { await AppleMusicLinks.open(kind: .track, artist: searchArtist, album: nil, track: searchTrack) }
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Search for this song in Apple Music")
        }
        .padding(.vertical, 8).padding(.horizontal, 4)
        .entityContextMenu(
            target: ImageTarget(kind: .track, artist: searchArtist, album: nil, track: searchTrack),
            onOpen: onOpen ?? {}
        )
        Divider()
    }

    private var content: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(AppTypography.contentTitle).lineLimit(1)
                Text(subtitle).font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(1)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { details }
                    VStack(alignment: .leading, spacing: 4) { details }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(plays.formatted()) \(plays == 1 ? "play" : "plays")")
                    .font(AppTypography.metadata.monospacedDigit())
                if let lastPlayed {
                    Text("last \(lastPlayed.formatted(.dateTime.month(.abbreviated).year()))")
                        .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 80, alignment: .trailing)
        }
        .contentShape(Rectangle())
    }
}
