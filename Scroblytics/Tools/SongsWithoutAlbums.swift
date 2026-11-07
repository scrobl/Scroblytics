import Foundation
import SwiftData

/// "Songs Without Albums": two groups of songs that aren't properly tied to an album.
///
/// - **No album**: songs whose Album field is empty in Music, and scrobbles Last.fm recorded with no album name.
/// - **Alone on an album**: albums in the Music library holding exactly one song. Albums are told apart by their album artist
///   (falling back to the track's artist), so the tracks of a compilation, or a guest's credit on someone else's album, don't
///   each look like an album of their own.
///
/// Everything is computed in memory from the scrobble history and (for the Music part) one read of the library; nothing is
/// stored and nothing is written to Music or Last.fm.
enum SongsWithoutAlbumsEngine {
    /// Another album the same song is known on.
    struct AlbumHint: Sendable, Hashable {
        let album: String
        /// Plays of the song recorded under this album in the scrobble history.
        let plays: Int
        /// True when a copy of the song with this album is in the Music library.
        let inMusic: Bool
    }

    struct NoAlbumRow: Identifiable, Sendable {
        /// `LibraryGapsEngine.key` of the song.
        let id: String
        let artist: String
        let track: String
        /// A copy of the song with an empty Album field is in the Music library.
        let emptyInMusic: Bool
        let cloudStatus: String
        /// Scrobbles of this song with no album name, and all its scrobbles.
        let albumlessPlays: Int
        let totalPlays: Int
        /// Latest play without an album name (nil when the row comes from Music alone).
        let lastPlayed: Date?
        /// Other albums the song is on, most played first — the likely fix.
        let hints: [AlbumHint]
    }

    struct Sibling: Sendable, Hashable {
        let album: String
        let songs: Int
    }

    struct AloneRow: Identifiable, Sendable {
        let id: String
        /// The album's artist: Music's album artist, or the track's artist when it has none.
        let artist: String
        let album: String
        let track: String
        let trackArtist: String
        let cloudStatus: String
        let plays: Int
        let lastPlayed: Date?
        /// The album is named after the song ("Song" or "Song - Single").
        let namedAfterSong: Bool
        /// Other albums by the same artist whose name is the same apart from "- Single", "- EP" or an edition suffix.
        let siblings: [Sibling]
        /// Other albums the same song is on (scrobble history or elsewhere in the library).
        let hints: [AlbumHint]
        /// How many tracks the release has according to a saved tracklist decision or a Last.fm tracklist already cached on this
        /// Mac; nil when neither is known (nothing is looked up).
        let knownTrackCount: Int?

        enum SingleBasis: Sendable { case tracklist, name }

        /// Why the row looks like a single, which is not a problem to fix: the known tracklist has exactly one track, or, with no
        /// tracklist known, the album is named after its song. A known tracklist of several tracks always wins over the name (a real
        /// album can share a song's name), so an album that is only partly in the library is never taken for a single.
        var singleBasis: SingleBasis? {
            if let knownTrackCount { return knownTrackCount == 1 ? .tracklist : nil }
            return namedAfterSong ? .name : nil
        }
        var isSingle: Bool { singleBasis != nil }
    }

    struct Result: Sendable {
        var noAlbum: [NoAlbumRow]
        var alone: [AloneRow]
        /// nil when Music wasn't read.
        var musicTracks: Int?
        var musicAlbums: Int?
        var checkedAt: Date
    }

    // MARK: Names

    /// Case-insensitive, whitespace-collapsed (so "99.9 F° " and "99.9 F°" are one album).
    nonisolated static func plain(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    private nonisolated static let singleOrEP = try! NSRegularExpression(
        pattern: "\\s*(?:[-–—]\\s*(?:single|ep)|\\((?:single|ep)\\))\\s*$", options: [.caseInsensitive]
    )

    /// The album's name without a trailing "- Single" / "- EP" / "(EP)" and without edition words, normalized.
    nonisolated static func baseName(_ album: String) -> String {
        let trimmed = album.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(location: 0, length: (trimmed as NSString).length)
        let stripped = singleOrEP.stringByReplacingMatches(in: trimmed, options: [], range: range, withTemplate: "")
        return TextNormalization.normalizeAlbumName(stripped)
    }

    /// Letters and digits only, after dropping a trailing "- Single" / "- EP": "Song (2019)" and "Song 2019 - Single" are one name.
    private nonisolated static func lettersOnly(_ album: String) -> String {
        let trimmed = album.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(location: 0, length: (trimmed as NSString).length)
        let stripped = singleOrEP.stringByReplacingMatches(in: trimmed, options: [], range: range, withTemplate: "")
        return String(stripped.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Two album names that are the same release written differently: equal apart from "- Single", "- EP", an edition suffix or
    /// punctuation. Music and Last.fm often name one single differently, so a decision saved under one name speaks for the other.
    nonisolated static func sameRelease(_ a: String, _ b: String) -> Bool {
        let base = baseName(a)
        if !base.isEmpty, base == baseName(b) { return true }
        let letters = lettersOnly(a)
        return !letters.isEmpty && letters == lettersOnly(b)
    }

    // MARK: History

    private struct SongHistory {
        var plays = 0
        var albumless = 0
        var lastAlbumless: Date?
        var last: Date?
        var spellings: [String: (artist: String, track: String, plays: Int)] = [:]
        var albums: [String: (name: String, plays: Int)] = [:]
        var displayArtist: String { spellings.values.max { $0.plays < $1.plays }?.artist ?? "" }
        var displayTrack: String { spellings.values.max { $0.plays < $1.plays }?.track ?? "" }
    }

    private nonisolated static func history(from scrobbles: [ScrobbleSnapshot]) -> [String: SongHistory] {
        var byKey: [String: SongHistory] = [:]
        for s in scrobbles where !s.trackName.isEmpty && !s.artistName.isEmpty {
            let key = LibraryGapsEngine.key(artist: s.artistName, track: s.trackName)
            var h = byKey[key] ?? SongHistory()
            h.plays += 1
            if h.last.map({ s.playedAt > $0 }) ?? true { h.last = s.playedAt }
            let spelling = "\(s.artistName)\u{0}\(s.trackName)"
            h.spellings[spelling, default: (s.artistName, s.trackName, 0)].plays += 1
            let album = plain(s.albumName)
            if album.isEmpty {
                h.albumless += 1
                if h.lastAlbumless.map({ s.playedAt > $0 }) ?? true { h.lastAlbumless = s.playedAt }
            } else {
                h.albums[album, default: (s.albumName.trimmingCharacters(in: .whitespacesAndNewlines), 0)].plays += 1
            }
            byKey[key] = h
        }
        return byKey
    }

    // MARK: Known tracklists

    /// The number of tracks the release is known to have: a pasted tracklist the person saved, a saved match to a Last.fm album, or
    /// the tracklist cached for the album's own name, read from `turnover` only (no lookups, nothing fetched). The album is tried
    /// under each name given (the library's, then other spellings of the same release the song was scrobbled under) and under each
    /// artist name given, because a decision or cached lookup is filed under whichever names asked. "Just use the
    /// tracks I've played" says nothing about the release, so it is skipped.
    nonisolated static func knownTrackCount(artists: [String], albums: [String], turnover: AlbumTurnoverEngine.Snapshot) -> Int? {
        var tried = Set<String>()
        for album in albums {
          for artist in artists where tried.insert(plain(artist) + "\u{241F}" + plain(album)).inserted {
            let group = AlbumGroup(artist: artist, displayName: album, normalizedName: TextNormalization.normalizeAlbumName(album), variants: [album], scrobbles: [])
            let resolution = turnover.resolution(for: group)
            switch resolution {
            case .manual(let tracks)?:
                if !tracks.isEmpty { return tracks.count }
            case .observed?:
                continue
            default:
                guard let request = AlbumTurnoverEngine.tracklistRequest(group: group, resolution: resolution),
                      case .found(let list)? = turnover.tracklists[AlbumTurnoverEngine.tracklistCacheKey(artist: request.artist, album: request.album)],
                      !list.tracks.isEmpty else { continue }
                return list.tracks.count
            }
          }
        }
        return nil
    }

    // MARK: Compute

    nonisolated static func compute(
        scrobbles: [ScrobbleSnapshot], music: AppleMusicSnapshot?, turnover: AlbumTurnoverEngine.Snapshot = .empty, now: Date = Date()
    ) -> Result {
        let history = history(from: scrobbles)

        // Library copies by song, split into those with and without an album.
        var emptyCopies: [String: AppleMusicSnapshot.Track] = [:]
        var albumsOfSong: [String: [String: String]] = [:] // song key → plain album → display album
        if let music {
            for t in music.library where !t.name.isEmpty {
                let key = LibraryGapsEngine.key(artist: t.artist, track: t.name)
                let album = plain(t.album)
                if album.isEmpty {
                    emptyCopies[key] = emptyCopies[key] ?? t
                } else {
                    albumsOfSong[key, default: [:]][album] = albumsOfSong[key]?[album] ?? t.album.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        // --- No album
        var noAlbumKeys = Set(history.filter { $0.value.albumless > 0 }.keys)
        noAlbumKeys.formUnion(emptyCopies.keys)
        let noAlbum: [NoAlbumRow] = noAlbumKeys.map { key in
            let h = history[key]
            let copy = emptyCopies[key]
            var byAlbum: [String: AlbumHint] = [:]
            for (plainName, entry) in h?.albums ?? [:] {
                byAlbum[plainName] = AlbumHint(album: entry.name, plays: entry.plays, inMusic: albumsOfSong[key]?[plainName] != nil)
            }
            for (plainName, display) in albumsOfSong[key] ?? [:] where byAlbum[plainName] == nil {
                byAlbum[plainName] = AlbumHint(album: display, plays: 0, inMusic: true)
            }
            let hints = byAlbum.values.sorted { ($0.plays, $1.album) > ($1.plays, $0.album) }
            return NoAlbumRow(
                id: key, artist: h?.displayArtist ?? copy?.artist ?? "", track: h?.displayTrack ?? copy?.name ?? "",
                emptyInMusic: copy != nil, cloudStatus: copy?.cloudStatus ?? "",
                albumlessPlays: h?.albumless ?? 0, totalPlays: h?.plays ?? 0, lastPlayed: h?.lastAlbumless, hints: hints
            )
        }

        // --- Alone on an album
        var alone: [AloneRow] = []
        var albumCount: Int?
        if let music {
            struct AlbumGroup {
                var artist: String
                var album: String
                var songs: [String: AppleMusicSnapshot.Track] = [:]
            }
            var groups: [String: AlbumGroup] = [:]
            for t in music.library where !t.name.isEmpty {
                let album = plain(t.album)
                guard !album.isEmpty else { continue }
                let owner = t.albumArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? t.artist : t.albumArtist
                let gk = plain(owner) + "\u{241F}" + album
                var g = groups[gk] ?? AlbumGroup(artist: owner.trimmingCharacters(in: .whitespacesAndNewlines), album: t.album.trimmingCharacters(in: .whitespacesAndNewlines))
                g.songs[LibraryGapsEngine.key(artist: t.artist, track: t.name)] = g.songs[LibraryGapsEngine.key(artist: t.artist, track: t.name)] ?? t
                groups[gk] = g
            }
            albumCount = groups.count
            // Every album name the scrobbles use, per artist (plain names), to find a release's other spellings.
            var scrobbledAlbums: [String: [String: String]] = [:]
            for sc in scrobbles where !sc.albumName.isEmpty && !sc.artistName.isEmpty {
                let album = plain(sc.albumName)
                if !album.isEmpty { scrobbledAlbums[plain(sc.artistName), default: [:]][album] = sc.albumName.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            // Albums of the same artist by base name, for "looks like another edition".
            var byOwnerBase: [String: [(gk: String, album: String, songs: Int)]] = [:]
            for (gk, g) in groups {
                byOwnerBase[plain(g.artist) + "\u{241F}" + baseName(g.album), default: []].append((gk, g.album, g.songs.count))
            }
            for (gk, g) in groups where g.songs.count == 1 {
                guard let (songKey, track) = g.songs.first else { continue }
                let h = history[songKey]
                let base = baseName(g.album)
                let named = !base.isEmpty && base == TextNormalization.normalizeTrackTitle(track.name)
                let siblings = (byOwnerBase[plain(g.artist) + "\u{241F}" + base] ?? [])
                    .filter { $0.gk != gk }
                    .map { Sibling(album: $0.album, songs: $0.songs) }
                    .sorted { ($0.songs, $1.album) > ($1.songs, $0.album) }
                let thisPlain = plain(g.album)
                let thisNormal = TextNormalization.normalizeAlbumName(g.album)
                var byAlbum: [String: AlbumHint] = [:]
                for (plainName, entry) in h?.albums ?? [:] where plainName != thisPlain && TextNormalization.normalizeAlbumName(entry.name) != thisNormal && !sameRelease(entry.name, g.album) {
                    byAlbum[plainName] = AlbumHint(album: entry.name, plays: entry.plays, inMusic: albumsOfSong[songKey]?[plainName] != nil)
                }
                for (plainName, display) in albumsOfSong[songKey] ?? [:]
                where plainName != thisPlain && TextNormalization.normalizeAlbumName(display) != thisNormal && !sameRelease(display, g.album) && byAlbum[plainName] == nil {
                    byAlbum[plainName] = AlbumHint(album: display, plays: 0, inMusic: true)
                }
                // The same release under other names the artist's scrobbles use, and under the artist spellings they use: a match
                // fixed on that album's page is filed there, not under the library's names. (Looked up by album, not through this
                // song's plays: the single's own scrobble may carry a title the song doesn't merge with.)
                let artists = [g.artist, track.artist] + (h?.spellings.values.sorted { ($0.plays, $1.artist) > ($1.plays, $0.artist) }.map(\.artist) ?? [])
                var seenArtist = Set<String>()
                var sameReleaseNames: [String] = []
                for artist in artists where seenArtist.insert(plain(artist)).inserted {
                    for (plainName, name) in (scrobbledAlbums[plain(artist)] ?? [:]).sorted(by: { $0.key < $1.key })
                    where plainName != thisPlain && sameRelease(name, g.album) && !sameReleaseNames.contains(name) {
                        sameReleaseNames.append(name)
                    }
                }
                alone.append(AloneRow(
                    id: gk, artist: g.artist, album: g.album, track: track.name, trackArtist: track.artist,
                    cloudStatus: track.cloudStatus, plays: h?.plays ?? 0, lastPlayed: h?.last, namedAfterSong: named,
                    siblings: siblings, hints: byAlbum.values.sorted { ($0.plays, $1.album) > ($1.plays, $0.album) },
                    knownTrackCount: knownTrackCount(artists: artists, albums: [g.album] + sameReleaseNames, turnover: turnover)
                ))
            }
        }

        return Result(noAlbum: noAlbum, alone: alone, musicTracks: music?.library.count, musicAlbums: albumCount, checkedAt: now)
    }
}

enum SongsWithoutAlbumsRunner {
    /// Reads Music (it must be running — never launched) and the scrobble history, then compares them. Read-only.
    static func run(container: ModelContainer) async throws -> SongsWithoutAlbumsEngine.Result {
        let apple = try await AppleMusicFavoritesReader.read(includeCloudStatus: true, includeAlbumArtist: true)
        let snapshots = try await offMain { try await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container) }
        // Saved match decisions and the Last.fm tracklists already cached here (read-only, no network), to tell a real single from a
        // partly-imported album.
        let turnover = await offMain { AlbumTurnoverEngine.loadSnapshot(context: ModelContext(container)) }
        return await Task.detached(priority: .userInitiated) {
            SongsWithoutAlbumsEngine.compute(scrobbles: snapshots, music: apple, turnover: turnover)
        }.value
    }

    /// The scrobble-history part only (no Music read).
    static func historyOnly(container: ModelContainer) async throws -> SongsWithoutAlbumsEngine.Result {
        let snapshots = try await offMain { try await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container) }
        return await Task.detached(priority: .userInitiated) {
            SongsWithoutAlbumsEngine.compute(scrobbles: snapshots, music: nil)
        }.value
    }
}
