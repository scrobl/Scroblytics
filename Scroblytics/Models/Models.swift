import Foundation
import SwiftData

/// A single play event — the raw event log that Overview, Top Charts and Album
/// Turnover derive everything from. Deliberately denormalized/raw: the same
/// track title can carry a different `albumName` across scrobbles (a
/// re-release, a mislabel, Last.fm metadata drift), and squashing that at
/// sync time would throw away information the album grouping logic
/// (buildAlbumGroups, detectAlbumMerges) needs to see later.
@Model
final class Scrobble {
    #Index<Scrobble>([\.playedAt])
    /// Raw artist name exactly as Last.fm returned it for this play.
    var artistName: String
    /// Raw album name, "" when Last.fm has none for this play (`ScrobbleTrack.l`).
    var albumName: String
    /// Raw track title (`ScrobbleTrack.t`).
    var trackName: String
    /// Preferred-size art URL for this play, or nil (`ScrobbleTrack.img`).
    var imageURL: String?
    /// When this play happened (`ScrobbleTrack.uts`, unix seconds).
    var playedAt: Date
    /// Stamped with the enclosing sync run's identity timestamp whenever this
    /// row is confirmed present by a fetch. Used to reconcile a completed
    /// backfill window against Last.fm's current data (see `SyncEngine`) —
    /// the "still returned by Last.fm" signal, kept in the database rather
    /// than by holding the whole history in memory every run.
    var lastConfirmedAt: Date

    init(artistName: String, albumName: String, trackName: String, imageURL: String?, playedAt: Date, lastConfirmedAt: Date) {
        self.artistName = artistName
        self.albumName = albumName
        self.trackName = trackName
        self.imageURL = imageURL
        self.playedAt = playedAt
        self.lastConfirmedAt = lastConfirmedAt
    }
}

/// Plain, `Sendable` snapshot of the `Scrobble` fields every ranking/
/// aggregation engine actually needs. `Scrobble` is a SwiftData `@Model`
/// class tied to the context it was fetched on and isn't `Sendable`, so it
/// can't cross into a background `Task` — every Overview engine that used to
/// take `[Scrobble]` now takes `[ScrobbleSnapshot]` instead, letting the
/// whole page's local computation run off the main actor instead of
/// blocking it for the several seconds a ~100k-scrobble library takes to
/// group/sort ten different ways.
struct ScrobbleSnapshot: Sendable {
    let artistName: String
    let albumName: String
    let trackName: String
    let imageURL: String?
    let playedAt: Date
}

extension Scrobble {
    var snapshot: ScrobbleSnapshot {
        ScrobbleSnapshot(artistName: artistName, albumName: albumName, trackName: trackName, imageURL: imageURL, playedAt: playedAt)
    }
}

/// One performer, with casing already resolved (most-played casing wins) —
/// resolved once at write time instead of on every read.
@Model
final class Artist {
    /// `name.trimmed.lowercased()` — the merge identity for casing variants
    /// Last.fm doesn't let you correct (`Beyoncé` vs `beyoncé`).
    @Attribute(.unique) var normalizedName: String
    /// Canonical display casing.
    var name: String
    /// Filename in the image-overrides store (keyed by the bare artist name).
    var customImageFilename: String?
    /// Locally cached Deezer artist image. A non-nil resolution timestamp with
    /// a nil filename records a genuine miss and prevents repeated lookups.
    var detectedImageFilename: String?
    var imageResolvedAt: Date?
    /// Community tags from `artist.getTopTags` (lowercased, weight-sorted,
    /// capped at 20) — a re-fetchable cache, so never included in backup/restore.
    var communityTags: [String]?
    var communityTagsResolvedAt: Date?

    init(normalizedName: String, name: String) {
        self.normalizedName = normalizedName
        self.name = name
    }
}

enum AlbumMatchMode: String, Codable {
    case canonical
    case observed
    case manual
}

/// An artist+album identity, scoped for the override/match-resolution fields
/// that are inherently per-album — NOT a container of tracks. A track's
/// membership in an album varies per scrobble (re-releases, mislabeled
/// imports, multi-album tracks), so that relationship is derived from
/// `Scrobble` rows at query time by later phases, never stored as a fixed
/// foreign key here.
@Model
final class Album {
    /// `"<canonical artist name>\0<normalizeAlbumName(title)>"` — so a backup
    /// restore resolves to the same row this schema already uses.
    @Attribute(.unique) var identityKey: String
    /// Canonical display title (the most-played raw variant).
    var title: String
    var normalizedTitle: String
    var artist: Artist?

    /// User-entered/corrected release date ("YYYY" | "YYYY-MM" | "YYYY-MM-DD").
    /// Local-only, never synced back to Last.fm.
    var releaseDateOverride: String?
    /// Resolved (MusicBrainz/Deezer) release date cache — distinct from the
    /// override above; never included in backups (re-fetchable).
    var releaseDateDetected: String?
    /// Stamped whenever resolution has been ATTEMPTED, regardless of outcome
    /// — without this, `releaseDateDetected == nil` can't distinguish "never
    /// checked yet" from "checked, MusicBrainz and Deezer both genuinely have
    /// no date for this album," and a genuine miss would get silently
    /// re-queued and re-fetched forever. Same existence-signals-resolved
    /// idiom as `TrackDurationCacheEntry`, just as a sibling field instead of
    /// a separate table, since `Album` already carries its own detected/
    /// override pair rather than a dedicated cache entry.
    var releaseDateResolvedAt: Date?

    var customImageFilename: String?
    /// Locally cached Deezer album artwork. A non-nil resolution timestamp with
    /// a nil filename records a genuine miss and prevents repeated lookups.
    var detectedImageFilename: String?
    var imageResolvedAt: Date?

    /// "Fix album match…" resolution — one of three modes
    /// (`canonical` | `observed` | `manual`).
    var matchResolutionMode: AlbumMatchMode?
    /// Set only when `matchResolutionMode == .canonical`.
    var canonicalArtist: String?
    var canonicalAlbum: String?
    /// Set only when `matchResolutionMode == .manual` — a captured tracklist
    /// (Apple Music import or pasted list) that IS the canonical tracklist,
    /// with no catalog lookup involved.
    var manualTracklist: [String]?

    init(identityKey: String, title: String, normalizedTitle: String, artist: Artist?) {
        self.identityKey = identityKey
        self.title = title
        self.normalizedTitle = normalizedTitle
        self.artist = artist
    }
}

/// An album edition the person chose to count on its own ("Album (25th Anniversary Edition)" next to "Album").
/// Edition names normally merge into one album for turnover, so one match decision covers them all; a row here
/// (with `countsSeparately`) pulls one exact name out of that merge and carries that edition's own match decision. The decision fields mirror
/// `Album`'s; a nil `matchResolutionMode` means "automatic" (Last.fm is asked for the edition's exact title).
@Model
final class AlbumEditionMatch {
    /// `TextNormalization.editionIdentityKey(artist:album:)` — the artist plus the album's exact name.
    @Attribute(.unique) var editionKey: String
    var artist: String
    var title: String
    var matchResolutionMode: AlbumMatchMode?
    var canonicalArtist: String?
    var canonicalAlbum: String?
    var manualTracklist: [String]?
    /// False = the person looked at this edition and chose to keep it merged with the others ("reviewed"): it is not
    /// counted on its own and the Merged Editions finder stops listing it. True = counted on its own.
    var countsSeparately: Bool = true

    init(editionKey: String, artist: String, title: String) {
        self.editionKey = editionKey
        self.artist = artist
        self.title = title
    }
}

/// A custom image attached to one exact Last.fm album title. Album rows group
/// edition variants for statistics and match metadata, so storing this on
/// `Album` would incorrectly share artwork between distinct releases.
@Model
final class AlbumImageOverride {
    @Attribute(.unique) var identityKey: String
    var artist: String
    var album: String
    var filename: String

    init(identityKey: String, artist: String, album: String, filename: String) {
        self.identityKey = identityKey
        self.artist = artist
        self.album = album
        self.filename = filename
    }
}

/// An artist+track identity, deliberately album-agnostic — `lovedKey(artist, track)`,
/// which Loved Tracks, Track Duration Overrides, and BPM Overrides all key by
/// regardless of which album a play was scrobbled under. Release date and custom image CAN be track-scoped
/// too (`ReleaseDateTarget`/`ImageOverrideTarget` both have a `"track"` kind),
/// used as a fallback when no reliable album is known for that track.
@Model
final class Track {
    /// `lovedKey(artist, title)` — space-separated, both sides lowercased.
    @Attribute(.unique) var identityKey: String
    var title: String
    var normalizedTitle: String
    var artist: Artist?

    /// User-entered/corrected runtime. No upper bound — a live recording, DJ
    /// mix, or podcast scrobbled as a track can legitimately run long.
    var durationOverrideSeconds: Int?
    /// User-entered/corrected BPM. Kept to 2 decimal places.
    var bpmOverride: Double?
    var customImageFilename: String?
    /// Track-scoped release date override — used only when the track has no
    /// reliably-known album to hang a release date off of instead.
    var releaseDateOverride: String?

    init(identityKey: String, title: String, normalizedTitle: String, artist: Artist?) {
        self.identityKey = identityKey
        self.title = title
        self.normalizedTitle = normalizedTitle
        self.artist = artist
    }
}

/// Sync engine bookkeeping — one row per connected account: the sync
/// metadata (last sync, playcount baseline) plus `BackfillState`.
@Model
final class SyncState {
    var username: String
    /// Stamped with the sync run's START time, only once that run fully
    /// completes (for a completed backfill, the baseline is the stored last-sync time).
    var lastSyncedAt: Date?
    /// Last.fm's account-wide playcount baseline, for detecting backdated
    /// plays on the next incremental sync (see `SyncEngine`).
    var remoteTotal: Int?

    /// Resumable backfill cursor — non-nil only mid-backfill.
    var backfillNextPage: Int?
    /// Fixed upper-bound unix-seconds for the CURRENT window (pinned so page
    /// numbers stay stable across a long paginated run).
    var backfillTo: Int?
    var backfillTotalPages: Int?
    /// Identity timestamp for the whole backfill run (constant across window
    /// transitions and resumes) — lets `Scrobble.lastConfirmedAt` reconcile
    /// correctly even if the app restarts mid-window.
    var backfillRunIdentity: Date?

    init(username: String) {
        self.username = username
    }
}

@Model
final class FlaggedTrack {
    var artist: String
    var track: String
    /// Album known when flagged — a fallback if the track later leaves the
    /// scrobble cache under its original album name. `nil` and `""` are
    /// treated as the same "no album known" bucket.
    var album: String?
    var flaggedAt: Date

    init(artist: String, track: String, album: String?, flaggedAt: Date) {
        self.artist = artist
        self.track = track
        self.album = album
        self.flaggedAt = flaggedAt
    }
}

/// A saved Ask filter. `queryJSON` is the resolved `FilterQuery` kept as an
/// opaque blob, stored losslessly.
@Model
final class SavedQuery {
    @Attribute(.unique) var remoteId: String
    var name: String
    var queryJSON: Data
    var createdAt: Date
    var columns: [String]?

    init(remoteId: String, name: String, queryJSON: Data, createdAt: Date, columns: [String]?) {
        self.remoteId = remoteId
        self.name = name
        self.queryJSON = queryJSON
        self.createdAt = createdAt
        self.columns = columns
    }
}

@Model
final class LinerNote {
    @Attribute(.unique) var remoteId: String
    var periodType: String
    var from: Date
    var to: Date
    var label: String
    var optionsJSON: Data
    var text: String
    var generatedText: String
    var generatedAt: Date
    var updatedAt: Date

    init(remoteId: String, periodType: String, from: Date, to: Date, label: String, optionsJSON: Data, text: String, generatedText: String, generatedAt: Date, updatedAt: Date) {
        self.remoteId = remoteId
        self.periodType = periodType
        self.from = from
        self.to = to
        self.label = label
        self.optionsJSON = optionsJSON
        self.text = text
        self.generatedText = generatedText
        self.generatedAt = generatedAt
        self.updatedAt = updatedAt
    }
}

/// Opaque per-tool filter state (Fading Favorites, Climbing, etc.) — the
/// `options`/`advancedGroups` payloads are stored opaquely and typed
/// only by the tool UI.
@Model
final class ToolFilterSetting {
    @Attribute(.unique) var toolId: String
    var optionsJSON: Data
    var advancedGroupsJSON: Data

    init(toolId: String, optionsJSON: Data, advancedGroupsJSON: Data) {
        self.toolId = toolId
        self.optionsJSON = optionsJSON
        self.advancedGroupsJSON = advancedGroupsJSON
    }
}

@Model
final class AppSettings {
    var theme: String

    init(theme: String) {
        self.theme = theme
    }
}

/// Persistent cache of one computed Reverb candidate pool (see
/// `ReverbEngine`) — the expensive part (external Last.fm similarity calls)
/// computed once per sync per the PRD, not recomputed on every Overview
/// load. Row arrays are JSON-encoded blobs, same style as
/// `ToolFilterSetting`'s `optionsJSON`/`advancedGroupsJSON`, since they're
/// opaque to SwiftData and only ever read/written as a whole by `ReverbEngine`.
@Model
final class ReverbPoolCache {
    /// The `SyncState.lastSyncedAt` this pool was computed against; nil if
    /// computed before any sync completed. A mismatch against the CURRENT
    /// sync's timestamp means the cache is stale and must be recomputed.
    var computedForSyncAt: Date?
    var computedAt: Date
    var artistsJSON: Data
    var albumsJSON: Data
    var tracksJSON: Data

    init(computedForSyncAt: Date?, computedAt: Date, artistsJSON: Data, albumsJSON: Data, tracksJSON: Data) {
        self.computedForSyncAt = computedForSyncAt
        self.computedAt = computedAt
        self.artistsJSON = artistsJSON
        self.albumsJSON = albumsJSON
        self.tracksJSON = tracksJSON
    }
}

/// Persistent, per-sync cache of every applicable album's most recent
/// completed-cycle date — the expensive, range-independent part of the
/// Overview totals row's "N turned over" stat (a range-independent cache
/// computed once per sync rather than recomputed for every album on every
/// call). The caller filters the cached
/// `groupKey -> lastTurnoverDate` map by whatever range is selected; no
/// re-fetching or re-resolving happens just because the date range changed.
@Model
final class AlbumTurnoverCompletionCache {
    var computedForSyncAt: Date?
    var computedAt: Date
    /// JSON-encoded `[String: Date]`, keyed by `AlbumTurnoverEngine.groupKey`.
    var completionsJSON: Data

    init(computedForSyncAt: Date?, computedAt: Date, completionsJSON: Data) {
        self.computedForSyncAt = computedForSyncAt
        self.computedAt = computedAt
        self.completionsJSON = completionsJSON
    }
}

/// Persistent, indefinite cache of `album.getInfo` tracklist lookups —
/// tracklists don't change, so a genuine result (found, OR a confirmed
/// "Last.fm has no such album" miss) is cached forever. Explicit PRD
/// requirement (`album-turnover-feature-prompt.md`: "cached indefinitely —
/// tracklists don't change"), not an optional optimization. A transient
/// fetch failure is never persisted here at all — no row exists for that
/// key — so the next lookup retries instead of freezing a blip as a
/// permanent miss.
@Model
final class AlbumTracklistCacheEntry {
    /// `"<queried artist><separator><queried album>"`, both trimmed +
    /// lowercased — the EXACT strings passed to `album.getInfo`, not the
    /// normalized album-group key. A group's auto-guessed query and a user's
    /// stored canonical resolution can each produce a different query string
    /// for the same physical release, so each is cached under its own key.
    /// Built by
    /// `AlbumTurnoverEngine.tracklistCacheKey`, which — like
    /// `TextNormalization.albumIdentityKey` — uses a U+241F separator, NOT a
    /// literal NUL byte (a real NUL here gets silently truncated by SQLite,
    /// confirmed directly: it collapsed every album by the same artist onto
    /// one row until this key was fixed to match).
    @Attribute(.unique) var cacheKey: String
    /// `canonicalArtist`/`canonicalAlbum`/`tracks` all nil together means a
    /// cached genuine miss ("Last.fm has no such album") — distinct from no
    /// row existing at all, which means "never successfully resolved, retry
    /// on next lookup."
    var canonicalArtist: String?
    var canonicalAlbum: String?
    var tracks: [String]?
    var cachedAt: Date

    init(cacheKey: String, canonicalArtist: String?, canonicalAlbum: String?, tracks: [String]?, cachedAt: Date) {
        self.cacheKey = cacheKey
        self.canonicalArtist = canonicalArtist
        self.canonicalAlbum = canonicalAlbum
        self.tracks = tracks
        self.cachedAt = cachedAt
    }
}

/// Cache-or-fetch for a track's Deezer-resolved runtime — same shape as
/// `AlbumTracklistCacheEntry` (a row's mere existence means "already
/// resolved," `seconds == nil` means a cached genuine miss, no row means
/// "never tried, retry on next lookup"), keyed by
/// `TextNormalization.lovedKey(artist:track:)` (album-agnostic, matching the
/// existing `Track.identityKey` convention). Deliberately NOT stored directly on `Track` as a second
/// field (unlike `Album.releaseDateOverride`/`releaseDateDetected`'s
/// two-field pattern): a `durationDetectedSeconds: Int?` field on `Track`
/// couldn't distinguish "never resolved" from "resolved, no match," the same
/// ambiguity `AlbumTracklistCacheEntry` was built to avoid.
@Model
final class TrackDurationCacheEntry {
    @Attribute(.unique) var cacheKey: String
    /// nil = a cached genuine miss (Deezer has no match for this track).
    var seconds: Int?
    var cachedAt: Date

    init(cacheKey: String, seconds: Int?, cachedAt: Date) {
        self.cacheKey = cacheKey
        self.seconds = seconds
        self.cachedAt = cachedAt
    }
}

/// One Last.fm similarity answer (similar tracks or similar artists), kept so Rabbit Hole doesn't ask again for the same track
/// within a month. `payload` is the answer as JSON; only a successful answer (including a genuine "nothing similar") is stored,
/// never a failure. Derived from Last.fm, so it is not part of a backup.
@Model
final class SimilarityLookupCacheEntry {
    /// "track\u{1F}artist\u{1F}title" or "artist\u{1F}artist", lowercased.
    @Attribute(.unique) var cacheKey: String
    var payload: Data
    var cachedAt: Date

    init(cacheKey: String, payload: Data, cachedAt: Date) {
        self.cacheKey = cacheKey
        self.payload = payload
        self.cachedAt = cachedAt
    }
}

/// Cached tempo lookup for one track, keyed by `TextNormalization.lovedKey` like `TrackDurationCacheEntry`.
/// A nil `bpm` is a confirmed miss (neither source has a tempo for it); a temporary failure is never stored.
/// `timeSignature` and `musicalKey` come back with the same GetSongBPM lookup, so they are kept rather than
/// fetched again later.
@Model
final class TrackBPMCacheEntry {
    @Attribute(.unique) var cacheKey: String
    var bpm: Double?
    /// `BPMSource.rawValue` of whoever supplied `bpm`; nil for a miss.
    var source: String?
    var timeSignature: String?
    var musicalKey: String?
    var cachedAt: Date

    init(cacheKey: String, bpm: Double?, source: String?, timeSignature: String?, musicalKey: String?, cachedAt: Date) {
        self.cacheKey = cacheKey
        self.bpm = bpm
        self.source = source
        self.timeSignature = timeSignature
        self.musicalKey = musicalKey
        self.cachedAt = cachedAt
    }
}

/// The connected account's Last.fm-loved tracks — a row's mere EXISTENCE
/// means "loved," unlike `TrackDurationCacheEntry`'s cache-or-miss shape;
/// there's no "loved: false" row, an unloved track just has no row at all.
/// Keyed by `TextNormalization.lovedKey(artist:track:)`, matching every
/// other per-track identity in this app. Deliberately a standalone table
/// rather than a `loved: Bool` field on `Track`: a track can be loved on
/// Last.fm without ever having been scrobbled locally (loved from the
/// website, a different scrobbler, etc.), and `Track` rows only exist for
/// titles this library has actually scrobbled — forcing a `Track` row into
/// existence just to record loved status would pollute Artist/Track counts
/// with entries that aren't real listening history.
///
/// Populated by a full re-page of `user.getLovedTracks` at the end of every
/// sync (union-merged into the prior
/// set on a partial failure, never truncated — only a fully complete page
/// walk replaces the set outright, since a dropped page must not read as
/// "these tracks got unloved"), and patched in place after every manual
/// love/unlove call so the UI reflects a toggle instantly without waiting
/// for the next sync.
@Model
final class LovedTrackEntry {
    @Attribute(.unique) var cacheKey: String
    var artist: String
    var track: String

    init(cacheKey: String, artist: String, track: String) {
        self.cacheKey = cacheKey
        self.artist = artist
        self.track = track
    }
}

/// Whether one scrobbled track is in the Apple Music library, as of the last "Check library" run (Library Gaps).
/// One row per distinct scrobbled track (keyed by `AppleMusicMatcher.durationMatchKey`, the same artist+title
/// key every other Apple Music match uses). A track with NO row has never been checked — consumers treat that
/// as unknown, never as "not in the library". Re-derivable from Music, so not part of backups (the user's
/// dismissals, which are not re-derivable, live in `LibraryGapDismissal`).
@Model
final class LibraryPresenceEntry {
    @Attribute(.unique) var matchKey: String
    var artist: String
    var track: String
    var inLibrary: Bool
    /// The last check at which the track WAS in the library, set when it goes missing. nil = never seen there
    /// (or still there).
    var lastSeenAt: Date?
    var firstCheckedAt: Date
    /// "“Title” by Artist" of a near match Music has when the exact key is missing — a spelling or credit
    /// variant, so the track is probably present under another name. nil = no near match.
    var nearMatch: String?
    /// "no longer available" when every copy in the library is greyed out in Music.
    var cloudStatus: String?

    init(
        matchKey: String, artist: String, track: String, inLibrary: Bool, lastSeenAt: Date?, firstCheckedAt: Date,
        nearMatch: String?, cloudStatus: String?
    ) {
        self.matchKey = matchKey
        self.artist = artist
        self.track = track
        self.inLibrary = inLibrary
        self.lastSeenAt = lastSeenAt
        self.firstCheckedAt = firstCheckedAt
        self.nearMatch = nearMatch
        self.cloudStatus = cloudStatus
    }
}

/// The user's answer to an Uncertain Library Gaps row: "that Music track isn't this one — this track isn't in my
/// library." `nearMatch` is the text of the near match they confirmed against; while a confirmation exists, checks
/// leave the track's near match cleared, so it stays Never in library (or Removed) rather than going back to
/// Uncertain. A check that finds the track in the library deletes it. Kept apart from `LibraryPresenceEntry`: that
/// table is rebuilt from Music on every check, while a confirmation is the user's own decision — it's included in
/// native backups. (The type and backup key keep the names of the "dismissal" this replaced; a record with no
/// `nearMatch` is one of those, and means nothing.)
@Model
final class LibraryGapDismissal {
    /// `LibraryGapsEngine.key(artist:track:)`.
    @Attribute(.unique) var matchKey: String
    var artist: String
    var track: String
    var dismissedAt: Date
    var nearMatch: String? = nil

    init(matchKey: String, artist: String, track: String, dismissedAt: Date, nearMatch: String? = nil) {
        self.matchKey = matchKey
        self.artist = artist
        self.track = track
        self.dismissedAt = dismissedAt
        self.nearMatch = nearMatch
    }
}

/// The user's verdict on one uncertain pairing in the Loved Status Audit: a track spelled one way on Last.fm and
/// another way in Apple Music. `sameTrack` = they are the same song (the audit then treats the two spellings as one);
/// otherwise they are different songs (the audit stops suggesting that pairing). The pair is kept as both spellings so a
/// decision can be listed, undone and backed up; `pairKey` is its identity.
@Model
final class LovedAuditDecision {
    @Attribute(.unique) var pairKey: String
    var lastfmArtist: String
    var lastfmTrack: String
    var appleArtist: String
    var appleTrack: String
    var sameTrack: Bool
    var decidedAt: Date

    init(pairKey: String, lastfmArtist: String, lastfmTrack: String, appleArtist: String, appleTrack: String, sameTrack: Bool, decidedAt: Date) {
        self.pairKey = pairKey
        self.lastfmArtist = lastfmArtist
        self.lastfmTrack = lastfmTrack
        self.appleArtist = appleArtist
        self.appleTrack = appleTrack
        self.sameTrack = sameTrack
        self.decidedAt = decidedAt
    }
}

/// The last Library Gaps run — a single row. Kept apart from the per-track rows so a run that changes nothing
/// writes one row, not eleven thousand.
@Model
final class LibraryPresenceCheck {
    var checkedAt: Date
    var libraryTrackCount: Int
    var trackedCount: Int

    init(checkedAt: Date, libraryTrackCount: Int, trackedCount: Int) {
        self.checkedAt = checkedAt
        self.libraryTrackCount = libraryTrackCount
        self.trackedCount = trackedCount
    }
}

/// A saved Tag Management rule: tag the tracks of one Apple Music playlist with these Last.fm tags. A playlist
/// changes over time (a smart playlist changes on its own), so a rule is a repeatable sync — it holds only what's
/// needed to rebuild the diff, never a track list. User-authored, so part of native backups.
@Model
final class TagPlaylistRule {
    @Attribute(.unique) var id: UUID
    /// Music's persistent ID — survives a rename. The name is kept to find the playlist again if the ID changes
    /// (e.g. after the playlist was rebuilt) and to label the rule.
    var playlistPersistentID: String
    var playlistName: String
    /// Normalized (trimmed, lowercased) Last.fm tags this playlist maps to.
    var tags: [String]
    /// When on, a review also offers to remove these tags from tracks that have left the playlist.
    var mirrorRemovals: Bool
    var createdAt: Date
    var lastAppliedAt: Date?

    init(
        id: UUID = UUID(), playlistPersistentID: String, playlistName: String, tags: [String],
        mirrorRemovals: Bool = false, createdAt: Date = Date(), lastAppliedAt: Date? = nil
    ) {
        self.id = id
        self.playlistPersistentID = playlistPersistentID
        self.playlistName = playlistName
        self.tags = tags
        self.mirrorRemovals = mirrorRemovals
        self.createdAt = createdAt
        self.lastAppliedAt = lastAppliedAt
    }
}

/// The identity of an entity in the tag caches: `"<kind>␟<artist>␟<name>"`, every part trimmed and
/// lowercased (an artist is `"artist␟<artist>"`). Uses U+241F like the other keys, never a NUL
/// (SQLite silently truncates a NUL).
enum EntityTagKey {
    private nonisolated static let separator = "\u{241F}"

    nonisolated static func make(kind: TopChartsEntity, artist: String, name: String?) -> String {
        let a = artist.trimmingCharacters(in: .whitespaces).lowercased()
        if kind == .artist { return "artist\(separator)\(a)" }
        return "\(kind.rawValue)\(separator)\(a)\(separator)\((name ?? "").trimmingCharacters(in: .whitespaces).lowercased())"
    }
}

/// Last.fm COMMUNITY tags for one album or track (`album.getTopTags` / `track.getTopTags`), cached
/// indefinitely like artist tags. `tags` empty = looked up, Last.fm has none for it itself (the
/// artist's tags are then used). A transient failure is never cached. Artist community tags live on
/// `Artist.communityTags`.
@Model
final class EntityCommunityTagCacheEntry {
    @Attribute(.unique) var cacheKey: String
    var tags: [String]
    var cachedAt: Date

    init(cacheKey: String, tags: [String], cachedAt: Date) {
        self.cacheKey = cacheKey
        self.tags = tags
        self.cachedAt = cachedAt
    }
}

/// The connected user's OWN tags on one artist, album or track. Kept current three ways: a detail
/// page's live fetch, tag adds/removes made in the app, and a complete pull of every personal tag
/// (`user.getPersonalTags`) — see `EntityTagsEngine.syncPersonalTags`.
@Model
final class UserEntityTagCacheEntry {
    @Attribute(.unique) var cacheKey: String
    var tags: [String]
    var cachedAt: Date

    init(cacheKey: String, tags: [String], cachedAt: Date) {
        self.cacheKey = cacheKey
        self.tags = tags
        self.cachedAt = cachedAt
    }
}

/// When the user's personal tags were last pulled IN FULL. Lives in the same store as
/// `UserEntityTagCacheEntry` on purpose: "no row for this entity" only means "no personal tags" while
/// this record says the cache is complete, so the two must never disagree (a copied or restored store
/// carries both, or neither).
@Model
final class PersonalTagSyncState {
    @Attribute(.unique) var username: String
    var syncedAt: Date

    init(username: String, syncedAt: Date) {
        self.username = username
        self.syncedAt = syncedAt
    }
}

/// Resolved release date for the rare track that has no locally-observed
/// album at all (see `ReleaseDateEngine`) — the vast majority of tracks
/// never need a row here at all, since their date is read straight off
/// their primary album's `Album.releaseDateDetected`/`releaseDateOverride`
/// instead. A row's mere existence means "resolution attempted"; `date ==
/// nil` is a cached genuine miss, distinct from "never tried" (no row).
@Model
final class TrackReleaseDateCacheEntry {
    @Attribute(.unique) var cacheKey: String
    var date: String?
    var cachedAt: Date

    init(cacheKey: String, date: String?, cachedAt: Date) {
        self.cacheKey = cacheKey
        self.date = date
        self.cachedAt = cachedAt
    }
}

/// A named, saved condition set for the query framework. `specJSON` is a
/// `QuerySpec` in its own versioned Codable form.
@Model
final class SavedConditionSet {
    @Attribute(.unique) var id: UUID
    var name: String
    var specJSON: Data
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, specJSON: Data, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.specJSON = specJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Raw Last.fm/Deezer popularity signals for one artist/album/track (see
/// `PopularityStore`). Re-fetchable, so never included in backups. A row's
/// existence means "resolution attempted": all-nil signals is a cached genuine
/// miss (neither service knows the entity), distinct from "never tried" (no
/// row). Percentiles/tiers are NEVER stored — they depend on every other row
/// and are recomputed from these raw values (`PopularitySnapshot`).
@Model
final class PopularityCacheEntry {
    @Attribute(.unique) var cacheKey: String
    /// "artist" | "album" | "track"
    var kind: String
    /// Lowercased/trimmed artist name — groups album/track rows into the
    /// artist-scoped comparison pool.
    var artistKey: String
    var lfmListeners: Int?
    var lfmPlaycount: Int?
    var deezerFans: Int?
    var deezerRank: Int?
    var resolvedAt: Date

    init(
        cacheKey: String, kind: String, artistKey: String,
        lfmListeners: Int?, lfmPlaycount: Int?, deezerFans: Int?, deezerRank: Int?,
        resolvedAt: Date
    ) {
        self.cacheKey = cacheKey
        self.kind = kind
        self.artistKey = artistKey
        self.lfmListeners = lfmListeners
        self.lfmPlaycount = lfmPlaycount
        self.deezerFans = deezerFans
        self.deezerRank = deezerRank
        self.resolvedAt = resolvedAt
    }
}
