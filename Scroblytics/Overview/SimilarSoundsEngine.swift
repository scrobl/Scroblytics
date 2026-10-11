import Foundation
import SwiftData

/// One artist/album/track the
/// user already listens to, used to seed a Last.fm similarity lookup.
struct RecommendationSeed {
    enum Kind {
        case artist, album, track
    }
    let kind: Kind
    let artist: String
    let album: String?
    let track: String?

    static func artist(_ artist: String) -> RecommendationSeed {
        RecommendationSeed(kind: .artist, artist: artist, album: nil, track: nil)
    }
}

struct RecommendationSeedResult {
    let label: String
    /// How many similar artists/tracks Last.fm returned for this seed.
    let similarFound: Int
    /// How many of those resolved to a track actually in the library.
    let inLibrary: Int
}

/// A library track surfaced as similar to one or more seeds.
struct RecommendedCandidate {
    let track: String
    let artist: String
    /// The most-played album this track appears under in the library, if any.
    let album: String?
    let totalPlaycount: Int
    let lastPlayed: Date
    /// 0-100, highest similarity match across every seed that surfaced this track.
    let matchScore: Int
    /// Seed labels that surfaced this track.
    let sources: [String]
    /// The single seed label that gave this track its highest match (best attribution).
    let topSource: String
    /// Locally-known artwork from this track's own scrobbles — not a new
    /// image-override subsystem, just the same imageURL every other card
    /// already reads off Scrobble.
    let imageURL: String?
}

/// The Similar Sounds engine — seeds one or more of the user's own
/// artists/albums/tracks, asks Last.fm for similar artists/tracks
/// (`artist.getSimilar`/`track.getSimilar`), then keeps only the candidates
/// actually in the local library. Reverb's PRD explicitly reuses this engine
/// rather than reimplementing similarity matching.
///
/// Deliberately scoped to just the "lookup / library-filtering / match-
/// scoring" core the PRD calls out. It does not resolve artist tags, apply condition-group
/// filters, resolve album release dates or enrich with image overrides or
/// popularity flags; Reverb's row content doesn't need them. The thumbnail is
/// just the locally-known Scrobble.imageURL every other card already reads.
@MainActor
enum SimilarSoundsEngine {
    /// Safety cap on external calls per request.
    static let seedCap = 15

    static func run(
        seeds: [RecommendationSeed], context: ModelContext, client: LastfmAPIClient
    ) async throws -> (candidates: [RecommendedCandidate], seedResults: [RecommendationSeedResult]) {
        let container = context.container
        let allScrobbles = try await offMain { try await ScrobbleSnapshotReader(modelContainer: container).fetchSortedSnapshots() }
        return try await run(seeds: seeds, scrobbles: allScrobbles, client: client)
    }

    /// The matching over an already-read, ascending-by-date library. Only the Last.fm calls
    /// are awaited; everything else is plain value work, so the caller can hand it a library it
    /// has already read for another purpose.
    static func run(
        seeds: [RecommendationSeed], scrobbles allScrobbles: [ScrobbleSnapshot], client: LastfmAPIClient
    ) async throws -> (candidates: [RecommendedCandidate], seedResults: [RecommendationSeedResult]) {
        let cappedSeeds = Array(seeds.prefix(seedCap))
        guard !cappedSeeds.isEmpty else { return ([], []) }

        func seedLabel(_ s: RecommendationSeed) -> String {
            switch s.kind {
            case .track: return "\(s.track ?? "") — \(s.artist)"
            case .album: return "\(s.album ?? "") — \(s.artist)"
            case .artist: return s.artist
            }
        }

        // The library indexes: one pass over every scrobble, off the main thread.
        let (artistByLower, tracksByArtistTrackLower, trackNamesByArtist) = await offMain {
            // Lowercased artist -> first-seen real casing, so a Last.fm-cased
            // similar-artist name resolves back to how the library spells it.
            var artistByLower: [String: String] = [:]
            var tracksByArtistTrackLower: [String: [ScrobbleSnapshot]] = [:]
            // Distinct track titles per artist, in first-played order — one pass here instead of
            // re-scanning the whole library for every similar artist Last.fm returns.
            var trackNamesByArtist: [String: [String]] = [:]
            var seenTrackByArtist: [String: Set<String>] = [:]
            for s in allScrobbles {
                let lowerArtist = s.artistName.lowercased()
                if artistByLower[lowerArtist] == nil { artistByLower[lowerArtist] = s.artistName }
                let key = "\(lowerArtist)\u{0}\(s.trackName.lowercased())"
                tracksByArtistTrackLower[key, default: []].append(s)
                if seenTrackByArtist[s.artistName, default: []].insert(s.trackName).inserted {
                    trackNamesByArtist[s.artistName, default: []].append(s.trackName)
                }
            }
            return (artistByLower, tracksByArtistTrackLower, trackNamesByArtist)
        }

        struct Merged {
            var tracks: [ScrobbleSnapshot]
            var score: Double
            var sources: Set<String>
            /// Seed label that produced this candidate's current best (max) match.
            var topSource: String
        }
        var merged: [String: Merged] = [:]
        // JS Map insertion order matters here (first-inserted key iterates
        // first below) — Swift's Dictionary doesn't provide that, so this is
        // tracked explicitly, same "Ordered" pattern as `buildAlbumGroups`.
        var mergedKeysOrdered: [String] = []

        // Resolves a Last.fm-cased artist/track pair against the library
        // (case-insensitive) and folds it into `merged` under the library's
        // own casing. Returns whether it matched a real library track.
        @discardableResult
        func addCandidate(artist: String, track: String, match: Double, source: String) -> Bool {
            guard let group = tracksByArtistTrackLower["\(artist.lowercased())\u{0}\(track.lowercased())"], !group.isEmpty else {
                return false
            }
            let key = "\(group[0].artistName.lowercased())\u{0}\(group[0].trackName.lowercased())"
            if var existing = merged[key] {
                if match > existing.score {
                    existing.score = match
                    existing.topSource = source
                }
                existing.sources.insert(source)
                merged[key] = existing
            } else {
                merged[key] = Merged(tracks: group, score: match, sources: [source], topSource: source)
                mergedKeysOrdered.append(key)
            }
            return true
        }

        // Exact seed identities to exclude from the results — recommending
        // the seed back to itself isn't a recommendation.
        let excludeTrackKeys = Set(cappedSeeds.filter { $0.kind == .track }
            .map { "\($0.artist.lowercased())\u{0}\(($0.track ?? "").lowercased())" })
        let excludeAlbumKeys = Set(cappedSeeds.filter { $0.kind == .album }
            .map { "\($0.artist.lowercased())\u{0}\(($0.album ?? "").lowercased())" })

        var seedResults: [RecommendationSeedResult] = []
        for seed in cappedSeeds {
            let label = seedLabel(seed)
            var matches: [(artist: String, track: String, match: Double)] = []
            let similarFound: Int

            if seed.kind == .track {
                let similar = await client.fetchSimilarTracks(artist: seed.artist, track: seed.track ?? "", limit: 100)
                similarFound = similar.count
                matches = similar.map { (artist: $0.artist, track: $0.name, match: $0.match) }
            } else {
                // Artist and album seeds both key off the artist — there's no
                // album-level similarity endpoint.
                let similarArtists = await client.fetchSimilarArtists(artist: seed.artist, limit: 30)
                similarFound = similarArtists.count
                for sa in similarArtists {
                    guard let realArtist = artistByLower[sa.name.lowercased()] else { continue }
                    for trackName in trackNamesByArtist[realArtist] ?? [] {
                        matches.append((artist: realArtist, track: trackName, match: sa.match))
                    }
                }
            }

            var inLibrary = 0
            for m in matches where addCandidate(artist: m.artist, track: m.track, match: m.match, source: label) {
                inLibrary += 1
            }
            seedResults.append(RecommendationSeedResult(label: label, similarFound: similarFound, inLibrary: inLibrary))
        }

        var candidates: [RecommendedCandidate] = []
        for key in mergedKeysOrdered {
            guard !excludeTrackKeys.contains(key), let m = merged[key] else { continue }

            // Most-played album this track appears under — first-encountered
            // order breaks ties
            // (Swift's Dictionary iteration order isn't
            // insertion order, so this is tracked explicitly too).
            var albumOrder: [String] = []
            var albumCounts: [String: Int] = [:]
            for s in m.tracks where !s.albumName.isEmpty {
                if albumCounts[s.albumName] == nil { albumOrder.append(s.albumName) }
                albumCounts[s.albumName, default: 0] += 1
            }
            var album: String?
            var bestAlbumCount = 0
            for name in albumOrder where albumCounts[name]! > bestAlbumCount {
                bestAlbumCount = albumCounts[name]!
                album = name
            }
            if let album, excludeAlbumKeys.contains("\(m.tracks[0].artistName.lowercased())\u{0}\(album.lowercased())") {
                continue
            }

            candidates.append(RecommendedCandidate(
                track: m.tracks[0].trackName,
                artist: m.tracks[0].artistName,
                album: album,
                totalPlaycount: m.tracks.count,
                lastPlayed: m.tracks[m.tracks.count - 1].playedAt,
                matchScore: Int((m.score * 100).rounded()),
                sources: Array(m.sources),
                topSource: m.topSource,
                imageURL: TextNormalization.firstNonPlaceholderImage(m.tracks.map(\.imageURL))
            ))
        }

        candidates.sort { a, b in
            a.matchScore != b.matchScore ? a.matchScore > b.matchScore : a.totalPlaycount > b.totalPlaycount
        }

        return (candidates, seedResults)
    }
}
