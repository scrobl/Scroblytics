import Foundation
import SwiftData

struct TopTagEntry: Identifiable, Hashable {
    let id = UUID()
    let tag: String
    let weight: Int
}

/// Tag weighting (`aggregateTagWeights`): sums each
/// in-range scrobble's weight (play count only) into every one of its
/// artist's cached community tags. An artist tagged both "rock" and
/// "alternative" contributes its full weight to each. Untagged artists
/// contribute nothing.
///
/// Deliberately NOT wired to the Metric toggle, even though `DurationEngine`
/// now exists: weighting by Time Listened here would mean resolving a
/// duration for every distinct track behind every distinct tagged artist in
/// range just to size a tag cloud, a much larger cold-cache cost than any of
/// the toggle's other call sites (Top Charts, Overview's Listening Totals/
/// Top Picks, entity headers) pay for their own narrower pools. Revisit if
/// that cost turns out to be acceptable in practice — this is a deliberate
/// scope cut, not an oversight.
///
/// Needs a new external dependency the sync layer doesn't fetch on its own:
/// `artist.getTopTags`, resolved lazily here (cached on the `Artist` row) —
/// on demand and cached, rather than
/// requiring a dedicated warm-up pass before this card can show anything.
@MainActor
enum TopTagsEngine {
    static let defaultLimit = 10

    static func fetch(
        context: ModelContext, range: DateRange, credentials: LastfmCredentials?, limit: Int = defaultLimit
    ) async throws -> [TopTagEntry] {
        // Plays per artist in range, and every artist's cached tags, from one background read — the
        // weighting only needs counts, never the scrobble rows themselves.
        let container = context.container
        let data = try await offMain { try await TopTagsDataReader(modelContainer: container).fetchArtistPlays(range: range) }
        guard !data.playsByArtist.isEmpty else { return [] }

        let tagMap = try await resolveArtistTags(
            names: Set(data.playsByArtist.keys), cached: data.cachedTags, context: context, credentials: credentials
        )

        var weights: [String: Int] = [:]
        for (artist, plays) in data.playsByArtist {
            guard let tags = tagMap[artist], !tags.isEmpty else { continue }
            for tag in tags { weights[tag, default: 0] += plays }
        }

        return weights
            .sorted { a, b in a.value != b.value ? a.value > b.value : a.key < b.key }
            .prefix(limit)
            .map { TopTagEntry(tag: $0.key, weight: $0.value) }
    }

    /// Cache-first: reads each artist's persisted `communityTags`, and for
    /// anything missing, fetches from Last.fm (bounded concurrency) and persists the
    /// result. A transient per-artist failure is skipped (contributes no
    /// tags this run and is left uncached to retry next
    /// time) rather than failing the whole card.
    private static func resolveArtistTags(
        names: Set<String>, cached: [String: [String]], context: ModelContext, credentials: LastfmCredentials?
    ) async throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        var toFetch: [String] = []

        for name in names {
            if let tags = cached[EntityTagsSnapshot.artistKey(name)] {
                result[name] = tags
            } else {
                toFetch.append(name)
            }
        }

        guard !toFetch.isEmpty, let credentials else { return result }
        let client = LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username)

        // One lookup at a time. This used to fetch five artists at once in a task group, but a Last.fm request
        // is spaced out by `LastfmPacer` anyway (so the group gained no speed), and that group, started from here
        // while an import was writing, aborted the app on macOS 15 ("pure virtual function called" inside Swift's
        // task completion, reproduced and traced to this loop). Don't bring concurrency back without a test on macOS 15.
        for name in toFetch {
            try Task.checkCancellation()
            // A transient failure (nil) is left uncached and tried again next time.
            guard let tags = try? await client.fetchArtistTopTags(artist: name) else { continue }
            result[name] = tags
            if let artist = try findArtist(named: name, context: context) {
                artist.communityTags = tags
                artist.communityTagsResolvedAt = Date()
            }
        }
        try context.save()
        return result
    }

    private static func findArtist(named name: String, context: ModelContext) throws -> Artist? {
        let normalized = EntityTagsSnapshot.artistKey(name)
        var descriptor = FetchDescriptor<Artist>(predicate: #Predicate<Artist> { $0.normalizedName == normalized })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

@ModelActor
private actor TopTagsDataReader {
    struct ArtistPlays: Sendable {
        /// Scrobbles per artist name (as scrobbled) inside the range.
        let playsByArtist: [String: Int]
        /// `Artist.normalizedName` → its cached community tags, for every artist that has them.
        let cachedTags: [String: [String]]
    }

    func fetchArtistPlays(range: DateRange) throws -> ArtistPlays {
        let from = range.from
        let to = range.to
        var plays: [String: Int] = [:]
        for s in try modelContext.fetch(FetchDescriptor<Scrobble>(
            predicate: #Predicate<Scrobble> { $0.playedAt >= from && $0.playedAt <= to }
        )) {
            plays[s.artistName, default: 0] += 1
        }
        var cached: [String: [String]] = [:]
        for artist in try modelContext.fetch(FetchDescriptor<Artist>()) {
            if let tags = artist.communityTags { cached[artist.normalizedName] = tags }
        }
        return ArtistPlays(playsByArtist: plays, cachedTags: cached)
    }
}
