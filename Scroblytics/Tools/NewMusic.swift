import SwiftUI

/// A track Last.fm calls similar that you have never played: it is in no scrobble, so the Query engine has no row for it. Similar Sounds
/// and Rabbit Hole offer these beside the tracks from your library when "new music" is on.
struct NewMusicCandidate: Sendable, Hashable {
    let artist: String
    let track: String
    /// 0-100, the best match across the seeds that surfaced it.
    let matchScore: Int
    /// Seed labels that surfaced it, best match first.
    let sources: [String]
    let topSource: String
}

enum NewMusic {
    /// The same track however Last.fm and your history spell it: case, "(Remastered)", "feat." tags and the like are ignored, so a
    /// track you have played under a slightly different title is never offered as new.
    static func key(artist: String, track: String) -> String {
        artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + "\u{0}" + TextNormalization.normalizeTrackTitle(track)
    }

    /// The track's public page on Last.fm. Last.fm writes spaces as `+` and each part is encoded on its own, so punctuation in a name
    /// cannot change the route.
    static func lastfmURL(artist: String, track: String) -> URL? {
        func segment(_ value: String) -> String {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~ ")
            let encoded = value.trimmingCharacters(in: .whitespacesAndNewlines).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return encoded.replacingOccurrences(of: " ", with: "+").replacingOccurrences(of: "%20", with: "+")
        }
        return URL(string: "https://www.last.fm/music/\(segment(artist))/_/\(segment(track))")
    }

    static func openInLastfm(artist: String, track: String) {
        if let url = lastfmURL(artist: artist, track: track) { NSWorkspace.shared.open(url) }
    }
}

/// The small marker on a track that comes from outside your library.
struct NewMusicBadge: View {
    var body: some View {
        Text("New")
            .font(AppTypography.compactMetadata.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
            .help("New to you: Last.fm calls it similar, but you haven't played it.")
            .accessibilityLabel("New to you")
    }
}

/// A random source that repeats for a given seed, so a shuffled list keeps its order until it is reshuffled.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Puts the new tracks into Similar Sounds' results. The Query engine evaluates the tracks from your library exactly as before (its
/// conditions, caps, order and limit); the new ones are placed among its rows afterwards, so nothing about how a result is computed changes.
enum SimilarSoundsBlend {
    struct Output: Sendable {
        var rows: [QueryDisplayRow]
        /// How many of `rows` are new music.
        var shown: Int
        /// New tracks left out because the refinement has conditions, which describe listening that a new track doesn't have.
        var hiddenByConditions: Int
    }

    /// `library` are `result`'s rows, already made for display. A new track takes its place by match score, falls in at random under
    /// Shuffled, and goes after your own tracks under Play count and Last played (it has neither). The per-artist limit counts the new
    /// ones too; the per-album limit can't (a new track has no album here); the song limit applies to the whole list.
    static func blend(
        library: [QueryDisplayRow], result: QueryResult, newMusic: [NewMusicCandidate], scores: SimilaritySnapshot,
        hasConditions: Bool, arrangement: SimilarSoundsArrangement, imageLookup: [String: String]
    ) -> Output {
        guard !newMusic.isEmpty else { return Output(rows: library, shown: 0, hiddenByConditions: 0) }
        guard !hasConditions else { return Output(rows: library, shown: 0, hiddenByConditions: newMusic.count) }

        let ordered = newMusic.sorted { $0.matchScore != $1.matchScore ? $0.matchScore > $1.matchScore : $0.track < $1.track }
        let rows = ordered.map { displayRow($0, columns: result.columns, imageLookup: imageLookup) }

        var merged = library
        switch arrangement.sort {
        case .matchScore:
            var index = 0
            for (candidate, row) in zip(ordered, rows) {
                // After every library row that scores at least as high (the engine's own order for them is by score).
                while index < merged.count, (scores.byID[merged[index].entityID]?.score ?? 0) >= candidate.matchScore { index += 1 }
                merged.insert(row, at: index)
                index += 1
            }
        case .shuffled:
            var generator = SeededRandom(seed: arrangement.shuffleSeed ^ 0xA5A5_A5A5)
            for row in rows { merged.insert(row, at: Int.random(in: 0...merged.count, using: &generator)) }
        case .plays, .lastPlayed:
            merged.append(contentsOf: rows)
        }

        if let perArtist = arrangement.perArtist {
            var counts: [String: Int] = [:]
            merged = merged.filter { row in
                let artist = row.entity.artist.lowercased()
                let kept = counts[artist, default: 0] < perArtist || !row.isNewMusic
                if kept { counts[artist, default: 0] += 1 }
                return kept
            }
        }
        if let limit = arrangement.songLimit { merged = Array(merged.prefix(limit)) }
        return Output(rows: merged, shown: merged.filter(\.isNewMusic).count, hiddenByConditions: 0)
    }

    private static func displayRow(_ candidate: NewMusicCandidate, columns: [ResolvedField], imageLookup: [String: String]) -> QueryDisplayRow {
        var cells: [String: QueryCell] = [:]
        for column in columns {
            switch column.field.id {
            case "similarScore": cells[column.cacheKey] = .value(.number(Double(candidate.matchScore)))
            case "similarBecause": cells[column.cacheKey] = .value(.text(candidate.sources.joined(separator: SimilaritySnapshot.sourceSeparator)))
            default: break
            }
        }
        let entity = QueryEntity(id: QueryEntityID(target: .track, artist: candidate.artist, name: candidate.track))
        let target = ImageTarget(kind: .track, artist: candidate.artist, album: nil, track: candidate.track)
        return QueryDisplayRow(
            row: QueryRow(entity: entity, cells: cells),
            imageURL: ImageResolutionEngine.effectiveImageURL(for: target, lookup: imageLookup, fallbackURL: nil),
            subtitle: candidate.artist,
            isNewMusic: true
        )
    }
}
