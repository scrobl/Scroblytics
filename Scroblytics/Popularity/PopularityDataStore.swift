import Foundation
import SwiftData

/// One entity awaiting a popularity lookup.
struct PopularityTarget: Sendable, Hashable {
    let lookup: PopularityLookup
    var key: String { lookup.key }
}

/// All SwiftData access for popularity, off the main actor: seeding the queue
/// from the synced library, upserting resolved signals, and reading the whole
/// cache back for a fresh `PopularitySnapshot`.
@ModelActor
actor PopularityDataStore {
    struct SeedResult: Sendable {
        let targets: [PopularityTarget]
        /// Album/Track rows with no artist — can't be looked up, reported not hidden.
        let skippedWithoutArtist: Int
        let freshCount: Int
    }

    /// Every artist/album/track in the library that has no cache row yet or
    /// whose row is older than `staleBefore`. Artists first (the smallest pool
    /// completes soonest), then albums, then tracks.
    func seedTargets(staleBefore: Date) throws -> SeedResult {
        let cached = Dictionary(
            uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<PopularityCacheEntry>()).map { ($0.cacheKey, $0.resolvedAt) }
        )

        var targets: [PopularityTarget] = []
        var seen = Set<String>()
        var skipped = 0
        var fresh = 0

        func consider(_ lookup: PopularityLookup) {
            let key = lookup.key
            guard seen.insert(key).inserted else { return }
            if let resolvedAt = cached[key], resolvedAt >= staleBefore {
                fresh += 1
                return
            }
            targets.append(PopularityTarget(lookup: lookup))
        }

        for artist in try modelContext.fetch(FetchDescriptor<Artist>()) where !artist.name.isEmpty {
            consider(.artist(artist.name))
        }
        for album in try modelContext.fetch(FetchDescriptor<Album>()) {
            guard let artist = album.artist?.name, !artist.isEmpty, !album.title.isEmpty else { skipped += 1; continue }
            consider(.album(artist: artist, name: album.title))
        }
        for track in try modelContext.fetch(FetchDescriptor<Track>()) {
            guard let artist = track.artist?.name, !artist.isEmpty, !track.title.isEmpty else { skipped += 1; continue }
            consider(.track(artist: artist, name: track.title))
        }
        return SeedResult(targets: targets, skippedWithoutArtist: skipped, freshCount: fresh)
    }

    func save(_ results: [(target: PopularityTarget, signals: PopularitySignals)], at date: Date = Date()) throws {
        for (target, signals) in results {
            let key = target.key
            var descriptor = FetchDescriptor<PopularityCacheEntry>(predicate: #Predicate { $0.cacheKey == key })
            descriptor.fetchLimit = 1
            if let existing = try modelContext.fetch(descriptor).first {
                existing.lfmListeners = signals.lfmListeners
                existing.lfmPlaycount = signals.lfmPlaycount
                existing.deezerFans = signals.deezerFans
                existing.deezerRank = signals.deezerRank
                existing.resolvedAt = date
            } else {
                modelContext.insert(PopularityCacheEntry(
                    cacheKey: key, kind: target.lookup.kind.rawValue, artistKey: target.lookup.artistKey,
                    lfmListeners: signals.lfmListeners, lfmPlaycount: signals.lfmPlaycount,
                    deezerFans: signals.deezerFans, deezerRank: signals.deezerRank,
                    resolvedAt: date
                ))
            }
        }
        try modelContext.save()
    }

    func loadRecords() throws -> [PopularityRecord] {
        try modelContext.fetch(FetchDescriptor<PopularityCacheEntry>()).compactMap { entry in
            guard let kind = PopularityKind(rawValue: entry.kind) else { return nil }
            return PopularityRecord(
                key: entry.cacheKey, kind: kind, artistKey: entry.artistKey,
                signals: PopularitySignals(
                    lfmListeners: entry.lfmListeners, lfmPlaycount: entry.lfmPlaycount,
                    deezerFans: entry.deezerFans, deezerRank: entry.deezerRank
                )
            )
        }
    }
}
