import Foundation
import SwiftData

/// Local reads/writes against `LovedTrackEntry` for UI code — the periodic
/// bulk re-page lives in `SyncEngine` itself (its own actor, its own
/// context); this is the MainActor-side counterpart list/detail views use to
/// check status and to toggle it. `@MainActor` for the same reason as
/// `DurationEngine`: takes a `ModelContext`, which isn't `Sendable`.
@MainActor
enum LovedTracksEngine {
    static func isLoved(context: ModelContext, artist: String, track: String) -> Bool {
        let key = TextNormalization.lovedKey(artist: artist, track: track)
        var descriptor = FetchDescriptor<LovedTrackEntry>(predicate: #Predicate { $0.cacheKey == key })
        descriptor.fetchLimit = 1
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    /// Bulk membership set for list rendering — one fetch instead of one
    /// query per row.
    nonisolated static func lovedSet(context: ModelContext) -> Set<String> {
        let all = (try? context.fetch(FetchDescriptor<LovedTrackEntry>())) ?? []
        return Set(all.map(\.cacheKey))
    }

    /// Patches the local set right after a successful love/unlove write, so
    /// every view reading loved status reflects it immediately. The next full sync's complete re-page is
    /// the only other thing that touches this table.
    static func patchLocal(context: ModelContext, artist: String, track: String, loved: Bool) {
        let key = TextNormalization.lovedKey(artist: artist, track: track)
        var descriptor = FetchDescriptor<LovedTrackEntry>(predicate: #Predicate { $0.cacheKey == key })
        descriptor.fetchLimit = 1
        let existing = try? context.fetch(descriptor).first
        if loved {
            if existing == nil {
                context.insert(LovedTrackEntry(cacheKey: key, artist: artist, track: track, lovedAt: .now))
            }
        } else if let existing {
            context.delete(existing)
        }
        try? context.save()
    }

    /// Loves or unloves a track against the real API, then patches the local
    /// set on success. Throws on failure (including "not connected") so
    /// callers can surface the error — this performs a real, consequential
    /// write, unlike the read-only helpers above.
    static func toggle(context: ModelContext, artist: String, track: String, loved: Bool) async throws {
        guard let credentials = LastfmCredentialsStore.load(), let secret = credentials.apiSecret, let sessionKey = credentials.sessionKey else {
            throw LovedTracksError.notConnected
        }
        if loved {
            try await LastfmWriteClient.unloveTrack(apiKey: credentials.apiKey, secret: secret, sessionKey: sessionKey, artist: artist, track: track)
            patchLocal(context: context, artist: artist, track: track, loved: false)
        } else {
            try await LastfmWriteClient.loveTrack(apiKey: credentials.apiKey, secret: secret, sessionKey: sessionKey, artist: artist, track: track)
            patchLocal(context: context, artist: artist, track: track, loved: true)
        }
    }

    enum LovedTracksError: Error, LocalizedError {
        case notConnected

        var errorDescription: String? {
            switch self {
            case .notConnected: "Connect Track Actions in Settings › Sync to love or unlove tracks."
            }
        }
    }
}
