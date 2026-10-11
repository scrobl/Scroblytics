import Foundation

enum SearchResultKind: CaseIterable, Sendable {
    case artist, album, track

    var label: String {
        switch self {
        case .artist: return "Artist"
        case .album: return "Album"
        case .track: return "Track"
        }
    }

    var pluralLabel: String {
        switch self {
        case .artist: return "Artists"
        case .album: return "Albums"
        case .track: return "Tracks"
        }
    }

    var entity: TopChartsEntity {
        switch self {
        case .artist: return .artist
        case .album: return .album
        case .track: return .track
        }
    }
}

struct SearchResult: Identifiable, Hashable, Sendable {
    let kind: SearchResultKind
    let title: String
    let subtitle: String?
    let playCount: Int
    let imageURL: String?
    let artist: ArtistIdentity?
    let album: AlbumIdentity?
    let track: TrackIdentity?

    var id: String { "\(kind)\u{0}\(title)\u{0}\(subtitle ?? "")" }

    static func == (lhs: SearchResult, rhs: SearchResult) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Builds the same all-time, play-count-ranked library search used by the
/// command palette. The expensive scrobble aggregation is pure and can
/// run in a detached task; the overlay keeps the resulting snapshot for the
/// lifetime of one presentation and only filters that snapshot while typing.
enum GlobalSearchEngine {
    struct Candidates: Sendable {
        let artists: [SearchResult]
        let albums: [SearchResult]
        let tracks: [SearchResult]
    }

    private struct Group: Sendable {
        var artist: String
        var name: String
        var playCount = 0
        var albumCounts: [String: Int] = [:]
        var imageByAlbum: [String: String] = [:]
    }

    nonisolated static func makeCandidates(
        scrobbles: [ScrobbleSnapshot],
        imageLookup: [String: String]
    ) -> Candidates {
        var artistGroups: [String: Group] = [:]
        var albumGroups: [String: Group] = [:]
        var trackGroups: [String: Group] = [:]

        for scrobble in scrobbles {
            let artistKey = normalized(scrobble.artistName)
            var artist = artistGroups[artistKey] ?? Group(artist: scrobble.artistName, name: scrobble.artistName)
            artist.playCount += 1
            artistGroups[artistKey] = artist

            if !scrobble.albumName.isEmpty {
                let albumKey = artistKey + "\u{0}" + normalized(scrobble.albumName)
                var album = albumGroups[albumKey] ?? Group(artist: scrobble.artistName, name: scrobble.albumName)
                album.playCount += 1
                if let imageURL = scrobble.imageURL { album.imageByAlbum[scrobble.albumName] = imageURL }
                albumGroups[albumKey] = album
            }

            let trackKey = artistKey + "\u{0}" + normalized(scrobble.trackName)
            var track = trackGroups[trackKey] ?? Group(artist: scrobble.artistName, name: scrobble.trackName)
            track.playCount += 1
            track.albumCounts[scrobble.albumName, default: 0] += 1
            if let imageURL = scrobble.imageURL { track.imageByAlbum[scrobble.albumName] = imageURL }
            trackGroups[trackKey] = track
        }

        let artists = artistGroups.values.map { group in
            let target = ImageTarget(kind: .artist, artist: group.artist, album: nil, track: nil)
            return SearchResult(
                kind: .artist, title: group.name, subtitle: nil,
                playCount: group.playCount,
                imageURL: ImageResolutionEngine.effectiveImageURL(for: target, lookup: imageLookup),
                artist: ArtistIdentity(name: group.name), album: nil, track: nil
            )
        }

        let albums = albumGroups.values.map { group in
            let target = ImageTarget(kind: .album, artist: group.artist, album: group.name, track: nil)
            return SearchResult(
                kind: .album, title: group.name, subtitle: group.artist,
                playCount: group.playCount,
                imageURL: ImageResolutionEngine.effectiveImageURL(
                    for: target, lookup: imageLookup, fallbackURL: group.imageByAlbum[group.name]
                ),
                artist: nil, album: AlbumIdentity(artist: group.artist, name: group.name), track: nil
            )
        }

        let tracks = trackGroups.values.map { group in
            let primaryAlbum = group.albumCounts.max { $0.value < $1.value }?.key
            let album = primaryAlbum.flatMap { $0.isEmpty ? nil : $0 }
            let target = ImageTarget(kind: .track, artist: group.artist, album: album, track: group.name)
            return SearchResult(
                kind: .track, title: group.name,
                subtitle: album.map { "\(group.artist) — \($0)" } ?? group.artist,
                playCount: group.playCount,
                imageURL: ImageResolutionEngine.effectiveImageURL(
                    for: target, lookup: imageLookup,
                    fallbackURL: primaryAlbum.flatMap { group.imageByAlbum[$0] }
                ),
                artist: nil, album: nil,
                track: TrackIdentity(artist: group.artist, name: group.name, album: album, imageURL: nil)
            )
        }

        return Candidates(artists: artists, albums: albums, tracks: tracks)
    }

    /// Returns up to `limitPerKind` matches in each section. Exact
    /// case-insensitive matches come first, then higher all-time play counts.
    nonisolated static func filter(
        candidates: Candidates,
        query: String,
        limitPerKind: Int = 6
    ) -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        func matches(in values: [SearchResult]) -> [SearchResult] {
            values
                .filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
                .sorted { lhs, rhs in
                    let lhsExact = lhs.title.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                    let rhsExact = rhs.title.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                    if lhsExact != rhsExact { return lhsExact }
                    if lhs.playCount != rhs.playCount { return lhs.playCount > rhs.playCount }
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                .prefix(limitPerKind)
                .map { $0 }
        }

        return matches(in: candidates.artists)
            + matches(in: candidates.albums)
            + matches(in: candidates.tracks)
    }

    private nonisolated static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
