import Foundation
import SwiftData

/// Applies a user's "Fix album match…" decision from the Fix UI to the
/// backing `Album` row — the write side of the same `matchResolutionMode`/
/// `canonicalArtist`/`canonicalAlbum`/`manualTracklist` fields
/// `NativeBackupEngine` restores and `AlbumTurnoverEngine.storedResolution`
/// reads back. A resolution set here takes effect immediately the next time
/// `AlbumTurnoverEngine.resolveTurnover`/`resolveAlbumTurnover` runs for this
/// album — no separate "recompute" step.
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
        let album = try findAlbum(context: context, group: group)
        album.matchResolutionMode = .canonical
        album.canonicalArtist = canonicalArtist
        album.canonicalAlbum = canonicalAlbum
        album.manualTracklist = nil
        try context.save()
    }

    /// Step 2b (Apple Music, when treated as a captured tracklist rather than
    /// a re-queryable catalog name) or step 2c (manual paste): a tracklist
    /// captured directly, no further catalog lookup involved.
    static func applyManual(context: ModelContext, group: AlbumGroup, tracks: [String]) throws {
        let album = try findAlbum(context: context, group: group)
        album.matchResolutionMode = .manual
        album.manualTracklist = tracks
        album.canonicalArtist = nil
        album.canonicalAlbum = nil
        try context.save()
    }

    /// The "use observed tracks" opt-out — always available. Locks the album
    /// to its own scrobbled titles as the denominator, bypassing the
    /// confidence classifier entirely (same as a stored `.observed` resolution).
    static func applyObserved(context: ModelContext, group: AlbumGroup) throws {
        let album = try findAlbum(context: context, group: group)
        album.matchResolutionMode = .observed
        album.canonicalArtist = nil
        album.canonicalAlbum = nil
        album.manualTracklist = nil
        try context.save()
    }

    /// "Reset to automatic matching" — clears any stored resolution so the
    /// album goes back through the plain `classifyConfidence` auto-classify
    /// path next time. Only meaningful (and only shown in the Fix UI) when a
    /// resolution currently exists.
    static func resetToAutomatic(context: ModelContext, group: AlbumGroup) throws {
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
