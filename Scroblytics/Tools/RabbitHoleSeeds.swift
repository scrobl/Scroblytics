import Foundation

/// Ways to start a Rabbit Hole without searching for a track.
enum RabbitHoleStart: String, CaseIterable, Identifiable, Sendable {
    case nowPlaying, forgottenFavourite, topTracks, surprise

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nowPlaying: "What’s playing now"
        case .forgottenFavourite: "A forgotten favourite"
        case .topTracks: "One of my top tracks"
        case .surprise: "Surprise me"
        }
    }

    var systemImage: String {
        switch self {
        case .nowPlaying: "play.circle"
        case .forgottenFavourite: "clock.arrow.circlepath"
        case .topTracks: "star"
        case .surprise: "sparkles"
        }
    }
}

enum RabbitHoleSeeds {
    /// How many starting tracks are tried before giving up.
    static let attempts = 4
    /// A starting track is accepted when at least this many tracks could be offered from it, so the first step is never empty.
    static let minimumPool = 6
    private static let shortlistSize = 12

    /// Tracks to try, best first, for the chosen way of starting. Empty when nothing fits (for example, nothing is playing).
    static func shortlist(
        _ kind: RabbitHoleStart, library: RabbitHoleLibrary, lovedKeys: Set<String>, nowPlaying: (artist: String, track: String)?,
        now: Date = Date(), using rng: inout some RandomNumberGenerator
    ) -> [Int] {
        let year: TimeInterval = 365 * 86400
        switch kind {
        case .nowPlaying:
            guard let nowPlaying, let index = library.index(artist: nowPlaying.artist, track: nowPlaying.track) else { return [] }
            return [index]
        case .forgottenFavourite:
            func matches(_ i: Int, olderThan age: TimeInterval, minimumPlays: Int) -> Bool {
                let track = library.tracks[i]
                return track.plays >= minimumPlays && now.timeIntervalSince(track.lastPlayed) >= age
                    && (lovedKeys.contains(track.key) || track.plays >= 8)
            }
            var pool = library.tracks.indices.filter { matches($0, olderThan: year, minimumPlays: 3) }
            if pool.isEmpty { pool = library.tracks.indices.filter { matches($0, olderThan: year / 2, minimumPlays: 5) } }
            return Array(pool.shuffled(using: &rng).prefix(shortlistSize))
        case .topTracks:
            let top = library.tracks.indices.sorted { library.tracks[$0].plays > library.tracks[$1].plays }.prefix(200)
            return Array(top.shuffled(using: &rng).prefix(shortlistSize))
        case .surprise:
            let pool = library.tracks.indices.filter { library.tracks[$0].plays >= 2 }
            return Array(pool.shuffled(using: &rng).prefix(shortlistSize))
        }
    }

    /// The first track in the shortlist whose pool is big enough (up to `attempts` tried). `poolSize` asks how many tracks could be offered.
    @MainActor
    static func firstViable(_ shortlist: [Int], minimum: Int = minimumPool, poolSize: (Int) async -> Int) async -> Int? {
        for index in shortlist.prefix(attempts) where await poolSize(index) >= minimum { return index }
        return nil
    }
}
