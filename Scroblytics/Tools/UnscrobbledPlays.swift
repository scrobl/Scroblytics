import Foundation
import SwiftData

/// "Unscrobbled Plays": songs Music has played more recently than the song's latest scrobble.
///
/// Music keeps one `played date` per track, the last time it played. A scrobbler normally gives the scrobble that same
/// instant, so a song whose latest scrobble is older than its Music played date was probably played without being scrobbled.
/// Two kinds of difference are not that, and are kept apart:
/// - **Time differs**: the two times are a whole number of hours apart (to within a few minutes), which is the same play
///   recorded with a clock or time-zone shift, not a missed one.
/// - **Spelling variants**: the song was scrobbled under a differently written title ("(feat. …)", "(Acoustic)"). Whether
///   that counts as the same song is the person's choice (`matchVariants`): on, the app's usual song matching applies;
///   off, only an identical artist and title (ignoring case and spacing) counts, so such songs show up to be cleaned.
///
/// Everything is computed in memory from the scrobble history and one read of the Music library; nothing is stored and
/// nothing is written to Music or Last.fm.
enum UnscrobbledPlaysEngine {
    /// Music's played date and a scrobble's time for one play agree to the second on most songs; this much is allowed anyway.
    nonisolated static let tolerance: TimeInterval = 600
    /// A play newer than the last sync, less this, hasn't had time to reach the history, so it can't be judged yet. Scrobblers send
    /// within seconds, so a few minutes is enough.
    nonisolated static let recentGrace: TimeInterval = 300
    /// The largest whole-hour difference treated as a time-zone shift.
    nonisolated static let maxShiftHours = 14

    enum Kind: Sendable { case neverScrobbled, playedAfterLastScrobble }

    struct Row: Identifiable, Sendable {
        /// The song's key under the matching in use.
        let id: String
        let artist: String
        let track: String
        let album: String
        let cloudStatus: String
        /// When Music last played the song (the latest of its copies), and its play count (summed over the copies).
        let musicLastPlayed: Date
        let musicPlays: Int
        /// The song's latest scrobble and how many it has, under the matching in use.
        let lastScrobble: Date?
        let scrobbles: Int
        let kind: Kind
        /// How the latest scrobble spelled the song, for opening its page; nil when never scrobbled.
        let historyArtist: String?
        let historyTrack: String?
        /// Music's played date minus the latest scrobble, in seconds (nil when never scrobbled).
        let gap: TimeInterval?
        /// For a Time differs row, the whole hours between the two times.
        let shiftHours: Int?
        /// With variants not matched: how the song was scrobbled when that is a differently written title that would have
        /// counted as the same song, for example "Artist — Title (feat. Someone)".
        let variantSpelling: String?
        /// With variants not matched: a scrobble under another spelling already covers this play (it is at or after Music's played
        /// date), so submitting it would count the play twice.
        let coveredByVariant: Bool
    }

    /// A song Music played too recently to judge: the history may not have its scrobble yet.
    struct RecentSong: Identifiable, Sendable {
        let id: String
        let artist: String
        let track: String
        let album: String
        let musicLastPlayed: Date
        /// The song's latest scrobble, if it has one.
        let lastScrobble: Date?
    }

    struct Result: Sendable {
        var notScrobbled: [Row]
        var timeDiffers: [Row]
        /// Songs compared (played in Music since the first scrobble and old enough to judge) and how many of them agree.
        var compared: Int
        var upToDate: Int
        /// Songs whose last Music play is too recent to judge, and songs last played before the first scrobble.
        var tooRecent: Int
        /// The songs behind `tooRecent`, newest first, so nothing is hidden silently.
        var tooRecentSongs: [RecentSong] = []
        /// The moment the history was last synced (or the newest scrobble, when that isn't known): plays after `judgedBefore` are too recent.
        var judgedBefore: Date? = nil
        var beforeFirstScrobble: Int
        /// Plays submitted from this tool that the history hasn't caught up with yet (the next sync brings them in); not listed.
        var submittedWaiting: Int = 0
        var firstScrobble: Date?
        var matchVariants: Bool
        var checkedAt: Date
    }

    /// Everything one read gathers, so a change of matching recomputes without reading Music again.
    struct Inputs: Sendable {
        let music: AppleMusicSnapshot
        /// The history as scrobbled, and with artist spellings merged (used when variants count as the same song).
        let raw: [ScrobbleSnapshot]
        let canonical: [ScrobbleSnapshot]
        /// When the history was last synced, or nil when unknown.
        let syncedThrough: Date?
    }

    // MARK: Names

    /// Case-insensitive, whitespace-collapsed: the identical-title key used when variants are not matched.
    nonisolated static func exactKey(artist: String, track: String) -> String {
        plain(artist) + "\u{241F}" + plain(track)
    }

    private nonisolated static func plain(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    // MARK: History

    private struct Stats {
        var latest: Date
        var count: Int
        /// How the latest scrobble spelled the song.
        var artist: String
        var track: String
    }

    // MARK: Compute

    nonisolated static func evaluate(_ inputs: Inputs, matchVariants: Bool, submitted: Set<String> = [], now: Date = Date()) -> Result {
        compute(
            scrobbles: matchVariants ? inputs.canonical : inputs.raw, music: inputs.music, matchVariants: matchVariants,
            syncedThrough: inputs.syncedThrough, submitted: submitted, now: now
        )
    }

    nonisolated static func compute(
        scrobbles: [ScrobbleSnapshot], music: AppleMusicSnapshot, matchVariants: Bool, syncedThrough: Date?,
        submitted: Set<String> = [], now: Date = Date()
    ) -> Result {
        // Latest scrobble and count per identical title; the variant-matched stats are built from those, once per distinct title.
        var exact: [String: Stats] = [:]
        var first: Date?
        var newest: Date?
        for s in scrobbles where !s.trackName.isEmpty && !s.artistName.isEmpty {
            let key = exactKey(artist: s.artistName, track: s.trackName)
            if var e = exact[key] {
                e.count += 1
                if s.playedAt > e.latest { e.latest = s.playedAt; e.artist = s.artistName; e.track = s.trackName }
                exact[key] = e
            } else {
                exact[key] = Stats(latest: s.playedAt, count: 1, artist: s.artistName, track: s.trackName)
            }
            if first.map({ s.playedAt < $0 }) ?? true { first = s.playedAt }
            if newest.map({ s.playedAt > $0 }) ?? true { newest = s.playedAt }
        }
        var fuzzy: [String: Stats] = [:]
        for e in exact.values {
            let fk = LibraryGapsEngine.key(artist: e.artist, track: e.track)
            if var f = fuzzy[fk] {
                f.count += e.count
                if e.latest > f.latest { f.latest = e.latest; f.artist = e.artist; f.track = e.track }
                fuzzy[fk] = f
            } else {
                fuzzy[fk] = e
            }
        }
        let stats = matchVariants ? fuzzy : exact

        // Library copies of a song are one song (under the matching in use): the latest play, the summed count.
        struct Song {
            var track: AppleMusicSnapshot.Track
            var lastPlayed: Date?
            var plays: Int
        }
        var songs: [String: Song] = [:]
        for t in music.library where !t.name.isEmpty {
            let ek = exactKey(artist: t.artist, track: t.name)
            let key = matchVariants ? LibraryGapsEngine.key(artist: t.artist, track: t.name) : ek
            var song = songs[key] ?? Song(track: t, lastPlayed: nil, plays: 0)
            song.plays += t.playCount
            if let played = t.lastPlayedAt, played > (song.lastPlayed ?? .distantPast) {
                song.lastPlayed = played
                song.track = t
            }
            songs[key] = song
        }

        let judgedBefore = (syncedThrough ?? newest ?? now).addingTimeInterval(-recentGrace)
        var result = Result(
            notScrobbled: [], timeDiffers: [], compared: 0, upToDate: 0, tooRecent: 0, beforeFirstScrobble: 0,
            firstScrobble: first, matchVariants: matchVariants, checkedAt: now
        )
        result.judgedBefore = judgedBefore
        guard let first else { return result }
        for (key, song) in songs {
            guard let played = song.lastPlayed else { continue }
            if played < first { result.beforeFirstScrobble += 1; continue }
            if played > judgedBefore {
                result.tooRecent += 1
                result.tooRecentSongs.append(RecentSong(
                    id: key, artist: song.track.artist, track: song.track.name, album: song.track.album, musicLastPlayed: played, lastScrobble: stats[key]?.latest
                ))
                continue
            }
            result.compared += 1
            let found = stats[key]
            let gap = found.map { played.timeIntervalSince($0.latest) }
            if let gap, gap <= tolerance { result.upToDate += 1; continue }

            // With variants not matched, say when a differently written scrobble of the song exists that would have counted.
            var variant: String?
            var covered = false
            if !matchVariants, let f = fuzzy[LibraryGapsEngine.key(artist: song.track.artist, track: song.track.name)],
               f.latest > (found?.latest ?? .distantPast), exactKey(artist: f.artist, track: f.track) != key {
                variant = "\(f.artist) — \(f.track)"
                covered = f.latest >= played.addingTimeInterval(-tolerance)
            }

            var shift: Int?
            if let gap {
                let hours = Int((gap / 3600).rounded())
                if (1...maxShiftHours).contains(hours), abs(gap - Double(hours) * 3600) <= tolerance { shift = hours }
            }
            let row = Row(
                id: key, artist: song.track.artist, track: song.track.name, album: song.track.album, cloudStatus: song.track.cloudStatus,
                musicLastPlayed: played, musicPlays: song.plays, lastScrobble: found?.latest, scrobbles: found?.count ?? 0,
                kind: found == nil ? .neverScrobbled : .playedAfterLastScrobble, historyArtist: found?.artist, historyTrack: found?.track, gap: gap, shiftHours: shift, variantSpelling: variant,
                coveredByVariant: covered
            )
            if shift != nil {
                result.timeDiffers.append(row)
            } else if submitted.contains(UnscrobbledPlaysScrobbling.ledgerKey(artist: row.artist, track: row.track, timestamp: Int(played.timeIntervalSince1970))) {
                result.submittedWaiting += 1
            } else {
                result.notScrobbled.append(row)
            }
        }
        result.tooRecentSongs.sort { $0.musicLastPlayed > $1.musicLastPlayed }
        return result
    }

    // MARK: Clusters

    /// Rows grouped by the month Music last played them, newest month first: where the gaps cluster.
    nonisolated static func byMonth(_ rows: [Row], calendar: Calendar = AppCalendars.listening) -> [(month: Date, count: Int)] {
        var counts: [Date: Int] = [:]
        for row in rows {
            let start = calendar.dateInterval(of: .month, for: row.musicLastPlayed)?.start ?? row.musicLastPlayed
            counts[start, default: 0] += 1
        }
        return counts.map { ($0.key, $0.value) }.sorted { $0.month > $1.month }
    }
}

enum UnscrobbledPlaysRunner {
    /// Reads Music (it must be running; never launched) and the scrobble history. Read-only.
    static func read(container: ModelContainer) async throws -> UnscrobbledPlaysEngine.Inputs {
        let music = try await AppleMusicFavoritesReader.read(includeCloudStatus: true, includePlayed: true)
        let (raw, canonical, synced) = try await offMain {
            let raw = try await ScrobbleHistoryCache.shared.snapshots(container: container)
            let canonical = try await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)
            let synced = (try? ModelContext(container).fetch(FetchDescriptor<SyncState>()))?.first?.lastSyncedAt
            return (raw, canonical, synced)
        }
        return UnscrobbledPlaysEngine.Inputs(music: music, raw: raw, canonical: canonical, syncedThrough: synced)
    }
}
