import Foundation
import SwiftData

/// Applies a user's "Fix album match…" decision from the Fix UI to the
/// backing `Album` row — the write side of the same `matchResolutionMode`/
/// `canonicalArtist`/`canonicalAlbum`/`manualTracklist` fields
/// `NativeBackupEngine` restores and `AlbumTurnoverEngine.storedResolution`
/// reads back. A resolution set here takes effect immediately the next time
/// `AlbumTurnoverEngine.resolveTurnover`/`resolveAlbumTurnover` runs for this
/// album — no separate "recompute" step.
///
/// A group that is one edition counted on its own (`group.editionKey != nil`) writes to that edition's
/// `AlbumEditionMatch` row instead, so its decision never touches the album the other editions share.
@MainActor
enum AlbumMatchFixEngine {
    enum FixError: Error, LocalizedError {
        case albumNotFound(artist: String, album: String)
        var errorDescription: String? {
            switch self {
            case .albumNotFound(let artist, let album):
                return "No local Album row exists yet for \(artist) — \(album). This shouldn't happen for an album with scrobbles; try syncing again first."
            }
        }
    }

    /// Looks up the `Album` row a group's Fix UI is acting on. Deliberately
    /// throws rather than creating one on the fly: every scrobbled album gets
    /// an `Album` row from `SyncEngine.resolveAlbum` during sync, so a miss
    /// here means something unexpected (a stale group, a sync gap) — worth
    /// surfacing, not silently papering over with a fabricated row.
    static func findAlbum(context: ModelContext, group: AlbumGroup) throws -> Album {
        let key = TextNormalization.albumIdentityKey(artist: group.artist, album: group.displayName)
        var descriptor = FetchDescriptor<Album>(predicate: #Predicate { $0.identityKey == key })
        descriptor.fetchLimit = 1
        guard let album = try context.fetch(descriptor).first else {
            throw FixError.albumNotFound(artist: group.artist, album: group.displayName)
        }
        return album
    }

    /// Step 2a/2b of the waterfall: a Last.fm alternate candidate or an Apple
    /// Music library edition, both keyed by an exact artist/album name pair a
    /// catalog (or the local library) already confirmed exists.
    static func applyCanonical(context: ModelContext, group: AlbumGroup, canonicalArtist: String, canonicalAlbum: String) throws {
        try write(context: context, group: group, mode: .canonical, canonicalArtist: canonicalArtist, canonicalAlbum: canonicalAlbum, manualTracklist: nil)
    }

    /// Step 2b (Apple Music, when treated as a captured tracklist rather than
    /// a re-queryable catalog name) or step 2c (manual paste): a tracklist
    /// captured directly, no further catalog lookup involved.
    static func applyManual(context: ModelContext, group: AlbumGroup, tracks: [String]) throws {
        try write(context: context, group: group, mode: .manual, canonicalArtist: nil, canonicalAlbum: nil, manualTracklist: tracks)
    }

    /// The "use observed tracks" opt-out — always available. Locks the album
    /// to its own scrobbled titles as the denominator, bypassing the
    /// confidence classifier entirely (same as a stored `.observed` resolution).
    static func applyObserved(context: ModelContext, group: AlbumGroup) throws {
        try write(context: context, group: group, mode: .observed, canonicalArtist: nil, canonicalAlbum: nil, manualTracklist: nil)
    }

    /// Stores a decision on the row that owns the group's match: its own edition row, or the shared `Album`.
    private static func write(
        context: ModelContext, group: AlbumGroup, mode: AlbumMatchMode?,
        canonicalArtist: String?, canonicalAlbum: String?, manualTracklist: [String]?
    ) throws {
        if let editionKey = group.editionKey {
            guard let edition = try findEdition(context: context, key: editionKey), edition.countsSeparately else {
                throw FixError.albumNotFound(artist: group.artist, album: group.displayName)
            }
            edition.matchResolutionMode = mode
            edition.canonicalArtist = canonicalArtist
            edition.canonicalAlbum = canonicalAlbum
            edition.manualTracklist = manualTracklist
        } else {
            let album = try findAlbum(context: context, group: group)
            album.matchResolutionMode = mode
            album.canonicalArtist = canonicalArtist
            album.canonicalAlbum = canonicalAlbum
            album.manualTracklist = manualTracklist
        }
        try context.save()
    }

    // MARK: - Counting an edition on its own

    static func findEdition(context: ModelContext, key: String) throws -> AlbumEditionMatch? {
        var descriptor = FetchDescriptor<AlbumEditionMatch>(predicate: #Predicate { $0.editionKey == key })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Starts counting one exact album name on its own: its plays, turnover and match leave the album its edition
    /// names share. Idempotent. Returns the edition's key. The cached "last completed cycle" dates are dropped so
    /// the Overview count follows the new grouping.
    @discardableResult
    static func separateEdition(context: ModelContext, artist: String, album: String) throws -> String {
        let key = TextNormalization.editionIdentityKey(artist: artist, album: album)
        if let existing = try findEdition(context: context, key: key) {
            existing.countsSeparately = true
        } else {
            context.insert(AlbumEditionMatch(editionKey: key, artist: artist, title: album))
        }
        try dropCompletionCache(context: context)
        try context.save()
        return key
    }

    /// Merges an edition back into its album. Its own saved decision goes with it; the edition stays on record as
    /// reviewed, so the Merged Editions finder doesn't suggest it again.
    static func rejoinEdition(context: ModelContext, key: String) throws {
        if let edition = try findEdition(context: context, key: key) { markKeptMerged(edition) }
        try dropCompletionCache(context: context)
        try context.save()
    }

    /// "Keep merged": records that the person reviewed this edition name and wants it counted with the others.
    static func keepMerged(context: ModelContext, artist: String, album: String) throws {
        let key = TextNormalization.editionIdentityKey(artist: artist, album: album)
        let edition = try findEdition(context: context, key: key) ?? {
            let created = AlbumEditionMatch(editionKey: key, artist: artist, title: album)
            context.insert(created)
            return created
        }()
        markKeptMerged(edition)
        try dropCompletionCache(context: context)
        try context.save()
    }

    private static func markKeptMerged(_ edition: AlbumEditionMatch) {
        edition.countsSeparately = false
        edition.matchResolutionMode = nil
        edition.canonicalArtist = nil
        edition.canonicalAlbum = nil
        edition.manualTracklist = nil
    }

    private static func dropCompletionCache(context: ModelContext) throws {
        for entry in try context.fetch(FetchDescriptor<AlbumTurnoverCompletionCache>()) { context.delete(entry) }
    }

    /// "Reset to automatic matching" — clears any stored resolution so the
    /// album goes back through the plain `classifyConfidence` auto-classify
    /// path next time. Only meaningful (and only shown in the Fix UI) when a
    /// resolution currently exists.
    static func resetToAutomatic(context: ModelContext, group: AlbumGroup) throws {
        // An edition counted on its own stays separate; only its decision goes back to automatic.
        if group.editionKey != nil {
            try write(context: context, group: group, mode: nil, canonicalArtist: nil, canonicalAlbum: nil, manualTracklist: nil)
            return
        }
        _ = try findAlbum(context: context, group: group)
        // A decision may sit on any name variant of the group (see `AlbumTurnoverEngine.resolutionKeys`), so clear them all —
        // otherwise a leftover on another variant would quietly take over again.
        let keys = AlbumTurnoverEngine.resolutionKeys(for: group)
        for album in try context.fetch(FetchDescriptor<Album>(predicate: #Predicate { keys.contains($0.identityKey) })) {
            album.matchResolutionMode = nil
            album.canonicalArtist = nil
            album.canonicalAlbum = nil
            album.manualTracklist = nil
        }
        try context.save()
    }
}
