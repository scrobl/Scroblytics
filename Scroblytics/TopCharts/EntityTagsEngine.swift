import Foundation
import SwiftData

struct EntityTagsResult: Sendable {
    let tags: [String]
    let inherited: Bool
}

@MainActor
enum PersonalTagVocabulary {
    private static let refreshInterval: TimeInterval = 24 * 60 * 60

    static func tags(for username: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: tagsKey(username)) ?? []
    }

    static func merge(_ newTags: [String], for username: String) {
        var byNormalizedName = Dictionary(
            uniqueKeysWithValues: tags(for: username).map { (LastfmTagNormalization.normalize($0), $0) }
        )
        for tag in newTags {
            let normalized = LastfmTagNormalization.normalize(tag)
            if !normalized.isEmpty { byNormalizedName[normalized] = normalized }
        }
        UserDefaults.standard.set(byNormalizedName.values.sorted(), forKey: tagsKey(username))
    }

    static func refreshIfNeeded(client: LastfmAPIClient, username: String) async {
        let defaults = UserDefaults.standard
        if let refreshedAt = defaults.object(forKey: refreshKey(username)) as? Date,
           Date().timeIntervalSince(refreshedAt) < refreshInterval,
           !tags(for: username).isEmpty {
            return
        }
        guard let remoteTags = try? await client.fetchUserTopTags() else { return }
        merge(remoteTags, for: username)
        defaults.set(Date(), forKey: refreshKey(username))
    }

    private static func tagsKey(_ username: String) -> String {
        "personalTagVocabulary.tags.\(username.lowercased())"
    }

    private static func refreshKey(_ username: String) -> String {
        "personalTagVocabulary.refreshedAt.\(username.lowercased())"
    }
}

/// Community + personal tag lookups for a detail page — Display only (see
/// tags-feature-prompt.md; Browsing and Writing are separate, later work,
/// and explicitly not built here). Falls back to the parent artist's tags
/// when the album/track has none of its own, matching Last.fm's own website
/// behavior.
///
/// Community tags for an ARTIST reuse `TopTagsEngine`'s existing
/// `Artist.communityTags` disk cache rather than a second cache — same data,
/// same source. Album/track community tags and all personal tags are fetched
/// live on each page visit: unlike Overview's Top Tags card (which resolves
/// every scrobbled artist on every reload), a single detail-page visit is a
/// single on-demand call, so a separate on-disk community-tag
/// cache for albums/tracks isn't reproduced here — a deliberate scope
/// reduction for this Display-only pass, not an oversight.
///
/// `@MainActor`: takes a `ModelContext`, which isn't `Sendable` — same
/// reason `AlbumTurnoverEngine`/`TopTagsEngine` carry the same annotation.
/// An immutable, read-only copy of every tag cache (artist community tags on `Artist`, album/track
/// community tags, and the user's personal tags), so the query framework can read them off the main
/// actor. It never fetches. Resolution: an entity's community tags
/// are its OWN when it has any, otherwise its artist's; personal tags are the entity's own plus its
/// album's and artist's; an entity's tags are the two combined.
struct EntityTagsSnapshot: Sendable {
    /// `artistKey` → cached artist community tags (empty = looked up, Last.fm has none).
    var artistCommunity: [String: [String]] = [:]
    /// `EntityTagKey` (album/track) → cached community tags of that entity itself.
    var entityCommunity: [String: [String]] = [:]
    /// `EntityTagKey` (artist/album/track) → the user's own tags on it.
    var personal: [String: [String]] = [:]
    /// True once every personal tag has been pulled — until then an absent row proves nothing.
    var personalSynced = false

    static let empty = EntityTagsSnapshot()

    /// How an artist name is matched to its `Artist` row — the rule `resolveArtistCommunityTags`
    /// and `TopTagsEngine` use.
    nonisolated static func artistKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// nil = not looked up yet.
    nonisolated func tags(forArtist name: String) -> [String]? {
        artistCommunity[Self.artistKey(name)]
    }

    /// Community tags for one entity: its own if it has any, else its artist's. nil = the lookup
    /// this needs hasn't happened yet (its own, or — when its own is empty — its artist's).
    nonisolated func communityTags(kind: TopChartsEntity, artist: String, name: String?) -> [String]? {
        if kind == .artist { return tags(forArtist: artist) }
        guard let own = entityCommunity[EntityTagKey.make(kind: kind, artist: artist, name: name)] else { return nil }
        return own.isEmpty ? tags(forArtist: artist) : own
    }

    /// The user's own tags on the entity, its album and its artist, combined. nil until personal tags have been synced.
    nonisolated func personalTags(kind: TopChartsEntity, artist: String, name: String?, album: String?) -> [String]? {
        guard personalSynced else { return nil }
        var keys: [String] = []
        if kind == .track { keys.append(EntityTagKey.make(kind: .track, artist: artist, name: name)) }
        if kind == .album { keys.append(EntityTagKey.make(kind: .album, artist: artist, name: name)) }
        if kind == .track, let album, !album.isEmpty { keys.append(EntityTagKey.make(kind: .album, artist: artist, name: album)) }
        keys.append(EntityTagKey.make(kind: .artist, artist: artist, name: nil))
        return LastfmTagNormalization.normalizeList(keys.flatMap { personal[$0] ?? [] })
    }

    /// Every distinct tag (trimmed + lowercased, as filters compare them) with how many cached
    /// entities carry it, most common first — the autocomplete list.
    nonisolated var vocabulary: [(tag: String, items: Int)] {
        var counts: [String: Int] = [:]
        for source in [Array(artistCommunity.values), Array(entityCommunity.values), Array(personal.values)] {
            for tags in source {
                for tag in Set(LastfmTagNormalization.normalizeList(tags)) { counts[tag, default: 0] += 1 }
            }
        }
        return counts.map { (tag: $0.key, items: $0.value) }
            .sorted { $0.items != $1.items ? $0.items > $1.items : $0.tag < $1.tag }
    }
}

@MainActor
enum EntityTagsEngine {
    /// Posted (at most every few seconds) as the background tag sweep lands results, so open views
    /// can refresh.
    static let progressNotification = Notification.Name("EntityTagsProgress")

    /// Last.fm's "not found" (code 6) for an artist/album/track: a genuine, cacheable "no tags of its
    /// own" — unlike a transient failure, which must be retried.
    nonisolated static func isGenuineMiss(_ error: Error) -> Bool {
        if case LastfmAPIError.api(let code, _) = error { return code == 6 }
        return false
    }

    /// Read-only: never fetches and never writes. Entities whose tags haven't been looked up yet are
    /// simply absent.
    nonisolated static func loadSnapshot(context: ModelContext) -> EntityTagsSnapshot {
        var snapshot = EntityTagsSnapshot()
        for artist in (try? context.fetch(FetchDescriptor<Artist>())) ?? [] {
            if let tags = artist.communityTags { snapshot.artistCommunity[artist.normalizedName] = tags }
        }
        for row in (try? context.fetch(FetchDescriptor<EntityCommunityTagCacheEntry>())) ?? [] {
            snapshot.entityCommunity[row.cacheKey] = row.tags
        }
        for row in (try? context.fetch(FetchDescriptor<UserEntityTagCacheEntry>())) ?? [] {
            snapshot.personal[row.cacheKey] = row.tags
        }
        if let username = LastfmCredentialsStore.load()?.username {
            snapshot.personalSynced = personalTagsSyncedAt(context: context, username: username) != nil
        }
        return snapshot
    }

    // MARK: - Personal tag cache

    /// When every personal tag was last pulled in full; nil = never.
    nonisolated static func personalTagsSyncedAt(context: ModelContext, username: String) -> Date? {
        let name = username.lowercased()
        var descriptor = FetchDescriptor<PersonalTagSyncState>(predicate: #Predicate { $0.username == name })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).first)?.syncedAt
    }

    private static func userTagRow(context: ModelContext, key: String) -> UserEntityTagCacheEntry? {
        var descriptor = FetchDescriptor<UserEntityTagCacheEntry>(predicate: #Predicate { $0.cacheKey == key })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Records the user's own tags on one entity, replacing what was cached (an empty list
    /// removes the row — no personal tags is the absence of a row).
    static func cacheUserTags(context: ModelContext, kind: TopChartsEntity, artist: String, name: String?, tags: [String]) {
        let key = EntityTagKey.make(kind: kind, artist: artist, name: name)
        let normalized = LastfmTagNormalization.normalizeList(tags)
        let existing = userTagRow(context: context, key: key)
        if normalized.isEmpty {
            if let existing { context.delete(existing) }
        } else if let existing {
            existing.tags = normalized
            existing.cachedAt = Date()
        } else {
            context.insert(UserEntityTagCacheEntry(cacheKey: key, tags: normalized, cachedAt: Date()))
        }
        try? context.save()
    }

    /// Applies a tag add/remove the user just made to the cache, on top of what's cached.
    static func patchUserTags(
        context: ModelContext, kind: TopChartsEntity, artist: String, name: String?, adding: [String] = [], removing: String? = nil
    ) {
        let key = EntityTagKey.make(kind: kind, artist: artist, name: name)
        var tags = userTagRow(context: context, key: key)?.tags ?? []
        tags += adding
        if let removing { tags.removeAll { $0 == LastfmTagNormalization.normalize(removing) } }
        cacheUserTags(context: context, kind: kind, artist: artist, name: name, tags: tags)
    }

    /// Pulls EVERY personal tag in full: the user's tag list, then everything tagged with each, per
    /// kind. Afterwards an entity with no cached row genuinely has no personal tags. Computed in
    /// full before anything is written, so a failure part-way leaves the old cache untouched.
    ///
    /// Albums and tracks come straight from `user.getPersonalTags`. ARTISTS do not: for
    /// `taggingtype=artist` Last.fm lists every artist that has ANY tagged track (verified against the
    /// per-artist `artist.getTags`, which correctly says none), so that list is only a set of
    /// candidates — each is confirmed with `artist.getTags` and its direct tags are what's kept.
    static func syncPersonalTags(client: LastfmAPIClient, context: ModelContext, progress: (String) -> Void = { _ in }) async throws {
        let vocabulary = try await client.fetchUserTopTags()
        var byEntity: [String: [String]] = [:]
        var artistCandidates: [String: String] = [:]   // artistKey → name as Last.fm spells it
        let kinds: [TopChartsEntity] = [.artist, .album, .track]
        var done = 0
        for tag in vocabulary {
            for kind in kinds {
                progress("\(done + 1) of \(vocabulary.count * kinds.count)")
                for item in try await client.fetchPersonalTaggedItems(tag: tag, kind: kind) {
                    if kind == .artist {
                        artistCandidates[EntityTagsSnapshot.artistKey(item.artist)] = item.artist
                    } else {
                        byEntity[EntityTagKey.make(kind: kind, artist: item.artist, name: item.name), default: []].append(tag)
                    }
                }
                done += 1
            }
        }
        for (index, candidate) in artistCandidates.values.sorted().enumerated() {
            progress("artists \(index + 1) of \(artistCandidates.count)")
            var tags: [String]?
            for attempt in 0..<3 where tags == nil {
                tags = try? await client.fetchUserTags(entity: .artist, artist: candidate)
                if tags == nil { try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 500_000_000) }
            }
            guard let direct = tags else { throw LastfmAPIError.malformedField("artist.getTags failed for \(candidate)") }
            if !direct.isEmpty { byEntity[EntityTagKey.make(kind: .artist, artist: candidate, name: nil)] = direct }
        }
        for row in (try? context.fetch(FetchDescriptor<UserEntityTagCacheEntry>())) ?? [] { context.delete(row) }
        for (key, tags) in byEntity {
            context.insert(UserEntityTagCacheEntry(cacheKey: key, tags: LastfmTagNormalization.normalizeList(tags), cachedAt: Date()))
        }
        // The marker is written in the same save as the rows, so it can never claim a sync that didn't land.
        let name = client.username.lowercased()
        var stateDescriptor = FetchDescriptor<PersonalTagSyncState>(predicate: #Predicate { $0.username == name })
        stateDescriptor.fetchLimit = 1
        if let state = try context.fetch(stateDescriptor).first { state.syncedAt = Date() }
        else { context.insert(PersonalTagSyncState(username: name, syncedAt: Date())) }
        try context.save()
        PersonalTagVocabulary.merge(vocabulary, for: client.username)
    }

    // MARK: - Community tag cache

    private static func communityRow(context: ModelContext, key: String) -> EntityCommunityTagCacheEntry? {
        var descriptor = FetchDescriptor<EntityCommunityTagCacheEntry>(predicate: #Predicate { $0.cacheKey == key })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func fetchCommunityTags(
        client: LastfmAPIClient, context: ModelContext, entity: TopChartsEntity,
        artist: String, album: String? = nil, track: String? = nil
    ) async -> EntityTagsResult {
        if entity == .artist {
            let tags = (try? await resolveArtistCommunityTags(client: client, context: context, artist: artist)) ?? []
            return EntityTagsResult(tags: tags, inherited: false)
        }

        let name = entity == .album ? album : track
        let cacheKey = EntityTagKey.make(kind: entity, artist: artist, name: name)
        let ownTags: [String]
        if let cached = communityRow(context: context, key: cacheKey) {
            // Cached indefinitely, like artist tags — community tags barely move.
            ownTags = cached.tags
        } else {
            do {
                switch entity {
                case .album:
                    ownTags = try await client.fetchAlbumTopTags(artist: artist, album: album ?? "")
                case .track:
                    ownTags = try await client.fetchTrackTopTags(artist: artist, track: track ?? "")
                case .artist:
                    ownTags = []
                }
                // Only a real answer is cached (found tags, or a genuine "none"); a transient failure
                // below is not, so the next lookup retries it.
                context.insert(EntityCommunityTagCacheEntry(cacheKey: cacheKey, tags: ownTags, cachedAt: Date()))
                try? context.save()
            } catch {
                ownTags = []
                if isGenuineMiss(error) {
                    // Last.fm doesn't know this album/track: remember that, so it isn't asked again.
                    context.insert(EntityCommunityTagCacheEntry(cacheKey: cacheKey, tags: [], cachedAt: Date()))
                    try? context.save()
                }
            }
        }

        if ownTags.isEmpty {
            let artistTags = (try? await resolveArtistCommunityTags(client: client, context: context, artist: artist)) ?? []
            if !artistTags.isEmpty {
                return EntityTagsResult(tags: artistTags, inherited: true)
            }
        }
        return EntityTagsResult(tags: ownTags, inherited: false)
    }

    static func fetchUserTags(
        client: LastfmAPIClient, context: ModelContext, entity: TopChartsEntity, artist: String, album: String? = nil, track: String? = nil
    ) async -> EntityTagsResult {
        await PersonalTagVocabulary.refreshIfNeeded(client: client, username: client.username)
        let ownFetch = try? await client.fetchUserTags(entity: entity, artist: artist, album: album, track: track)
        let ownTags = ownFetch ?? []
        PersonalTagVocabulary.merge(ownTags, for: client.username)
        // A successful fetch is the freshest truth about this entity's own tags — keep the cache in step.
        if ownFetch != nil {
            cacheUserTags(context: context, kind: entity, artist: artist, name: entity == .album ? album : track, tags: ownTags)
        }
        if ownTags.isEmpty, entity != .artist {
            let artistFetch = try? await client.fetchUserTags(entity: .artist, artist: artist)
            let artistTags = artistFetch ?? []
            if artistFetch != nil { cacheUserTags(context: context, kind: .artist, artist: artist, name: nil, tags: artistTags) }
            PersonalTagVocabulary.merge(artistTags, for: client.username)
            if !artistTags.isEmpty {
                return EntityTagsResult(tags: artistTags, inherited: true)
            }
        }
        return EntityTagsResult(tags: ownTags, inherited: false)
    }

    private static func resolveArtistCommunityTags(client: LastfmAPIClient, context: ModelContext, artist: String) async throws -> [String] {
        let normalized = EntityTagsSnapshot.artistKey(artist)
        var descriptor = FetchDescriptor<Artist>(predicate: #Predicate<Artist> { $0.normalizedName == normalized })
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first, let cached = existing.communityTags {
            return cached
        }
        let tags = try await client.fetchArtistTopTags(artist: artist)
        if let existing = try context.fetch(descriptor).first {
            existing.communityTags = tags
            existing.communityTagsResolvedAt = Date()
            try context.save()
        }
        return tags
    }
}
