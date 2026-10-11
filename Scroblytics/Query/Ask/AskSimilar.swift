import Foundation
import SwiftData
import Observation

/// "Find 25 songs similar to X": a request for NEW music like something the person already has, which is the Similar Sounds
/// tool's job, not a filter over their own history. The model only names the seed (and how many results); finding that seed
/// in the library, and everything after, is the tool's own code.
struct AskSimilarIntent: Sendable, Equatable {
    /// The artist, album or song name as the person gave it.
    let seedText: String
    /// What the model thinks it is, when it could tell.
    let kind: SimilarSeed.Kind?
    /// An artist named to tell the seed apart ("Time by Hans Zimmer" → Hans Zimmer).
    let artistHint: String?
    let limit: Int

    static let defaultLimit = 30
}

/// A request to open Similar Sounds on one seed and run it.
struct AskSimilarRequest: Identifiable, Sendable {
    let id = UUID()
    let seed: SimilarSeed
    let limit: Int
}

/// Hands a "find similar" from the Ask box (toolbar popover or the Query tab's bar) to the Similar Sounds tool.
@MainActor
@Observable
final class AskSimilarRouter {
    var pending: AskSimilarRequest?
}

/// Finds the library item an intent names. Only things you've actually scrobbled can seed Similar Sounds, so an unknown
/// name resolves to nothing and the review says so rather than guessing.
enum AskSimilarResolver {
    static func resolve(_ intent: AskSimilarIntent, container: ModelContainer) async -> SimilarSeed? {
        guard let scrobbles = try? await offMain({
            QueryIdentity.canonicalizingArtists(try await ScrobbleSnapshotReader(modelContainer: container).fetchSortedSnapshots())
        }) else { return nil }
        return await Task.detached(priority: .userInitiated) { resolve(intent, scrobbles: scrobbles) }.value
    }

    nonisolated static func resolve(_ intent: AskSimilarIntent, scrobbles: [ScrobbleSnapshot]) -> SimilarSeed? {
        func fold(_ s: String) -> String {
            s.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter || $0.isNumber }
        }
        let wanted = fold(intent.seedText)
        guard !wanted.isEmpty else { return nil }
        let hint = intent.artistHint.map(fold).flatMap { $0.isEmpty ? nil : $0 }
        func artistOK(_ artist: String) -> Bool {
            guard let hint else { return true }
            let a = fold(artist)
            return a == hint || a.contains(hint) || hint.contains(a)
        }

        var tracks: [String: (seed: SimilarSeed, plays: Int)] = [:]
        var albums: [String: (seed: SimilarSeed, plays: Int)] = [:]
        var artists: [String: (seed: SimilarSeed, plays: Int)] = [:]
        for s in scrobbles {
            if fold(TextNormalization.normalizeTrackTitle(s.trackName)) == wanted || fold(s.trackName) == wanted, artistOK(s.artistName) {
                let key = "\(s.artistName)\u{0}\(s.trackName)"
                var entry = tracks[key] ?? (SimilarSeed(kind: .track, artist: s.artistName, album: nil, track: s.trackName), 0)
                entry.plays += 1
                tracks[key] = entry
            }
            if !s.albumName.isEmpty, fold(TextNormalization.normalizeAlbumName(s.albumName)) == wanted || fold(s.albumName) == wanted, artistOK(s.artistName) {
                let key = "\(s.artistName)\u{0}\(s.albumName)"
                var entry = albums[key] ?? (SimilarSeed(kind: .album, artist: s.artistName, album: s.albumName, track: nil), 0)
                entry.plays += 1
                albums[key] = entry
            }
            if fold(s.artistName) == wanted {
                var entry = artists[s.artistName] ?? (SimilarSeed(kind: .artist, artist: s.artistName, album: nil, track: nil), 0)
                entry.plays += 1
                artists[s.artistName] = entry
            }
        }
        func best(_ pool: [String: (seed: SimilarSeed, plays: Int)]) -> SimilarSeed? { pool.values.max { $0.plays < $1.plays }?.seed }
        switch intent.kind {
        case .track?: return best(tracks)
        case .album?: return best(albums)
        case .artist?: return best(artists)
        case nil: return best(tracks) ?? best(albums) ?? best(artists)
        }
    }
}
