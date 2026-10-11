import Foundation
import SwiftData

/// One thing whose community tags the sweep should look up.
struct TagTarget: Hashable, Sendable {
    let kind: TopChartsEntity
    let artist: String
    /// nil for an artist.
    let name: String?

    var key: String { EntityTagKey.make(kind: kind, artist: artist, name: name) }
}

/// The SwiftData side of the tag sweep, on its own background context so seeding a ~13k-entity
/// library and saving results never touch the main actor. Mirrors `PopularityDataStore`.
@ModelActor
actor TagDataStore {
    struct SeedResult: Sendable {
        let targets: [TagTarget]
        /// Album/Track rows with no artist — can't be looked up, reported not hidden.
        let skippedWithoutArtist: Int
        let cachedCount: Int
    }

    /// Everything in the library whose community tags haven't been looked up: artists with no
    /// `communityTags`, albums/tracks with no cache row. Artists first (the smallest pool completes
    /// soonest), then albums, then tracks. A looked-up entity — even one Last.fm has no tags for —
    /// is never seeded again.
    func seedTargets() throws -> SeedResult {
        let cachedRows = Set(try modelContext.fetch(FetchDescriptor<EntityCommunityTagCacheEntry>()).map(\.cacheKey))
        var targets: [TagTarget] = []
        var seen = Set<String>()
        var skipped = 0
        var cached = 0

        func consider(_ target: TagTarget, alreadyCached: Bool) {
            guard seen.insert(target.key).inserted else { return }
            if alreadyCached { cached += 1 } else { targets.append(target) }
        }

        for artist in try modelContext.fetch(FetchDescriptor<Artist>()) where !artist.name.isEmpty {
            consider(TagTarget(kind: .artist, artist: artist.name, name: nil), alreadyCached: artist.communityTags != nil)
        }
        for album in try modelContext.fetch(FetchDescriptor<Album>()) {
            guard let artist = album.artist?.name, !artist.isEmpty, !album.title.isEmpty else { skipped += 1; continue }
            let target = TagTarget(kind: .album, artist: artist, name: album.title)
            consider(target, alreadyCached: cachedRows.contains(target.key))
        }
        for track in try modelContext.fetch(FetchDescriptor<Track>()) {
            guard let artist = track.artist?.name, !artist.isEmpty, !track.title.isEmpty else { skipped += 1; continue }
            let target = TagTarget(kind: .track, artist: artist, name: track.title)
            consider(target, alreadyCached: cachedRows.contains(target.key))
        }
        return SeedResult(targets: targets, skippedWithoutArtist: skipped, cachedCount: cached)
    }

    /// Which of `targets` still have nothing cached (a query's candidates may already have been
    /// filled in by the sweep or a detail page since it was computed).
    func uncached(_ targets: [TagTarget]) throws -> [TagTarget] {
        let cachedRows = Set(try modelContext.fetch(FetchDescriptor<EntityCommunityTagCacheEntry>()).map(\.cacheKey))
        var artistsWithTags = Set<String>()
        for artist in try modelContext.fetch(FetchDescriptor<Artist>()) where artist.communityTags != nil {
            artistsWithTags.insert(artist.normalizedName)
        }
        return targets.filter { target in
            target.kind == .artist
                ? !artistsWithTags.contains(EntityTagsSnapshot.artistKey(target.artist))
                : !cachedRows.contains(target.key)
        }
    }

    func save(_ results: [(target: TagTarget, tags: [String])], at date: Date = Date()) throws {
        for (target, tags) in results {
            if target.kind == .artist {
                let normalized = EntityTagsSnapshot.artistKey(target.artist)
                var descriptor = FetchDescriptor<Artist>(predicate: #Predicate { $0.normalizedName == normalized })
                descriptor.fetchLimit = 1
                if let artist = try modelContext.fetch(descriptor).first {
                    artist.communityTags = tags
                    artist.communityTagsResolvedAt = date
                }
                continue
            }
            let key = target.key
            var descriptor = FetchDescriptor<EntityCommunityTagCacheEntry>(predicate: #Predicate { $0.cacheKey == key })
            descriptor.fetchLimit = 1
            if let existing = try modelContext.fetch(descriptor).first {
                existing.tags = tags
                existing.cachedAt = date
            } else {
                modelContext.insert(EntityCommunityTagCacheEntry(cacheKey: key, tags: tags, cachedAt: date))
            }
        }
        try modelContext.save()
    }
}
