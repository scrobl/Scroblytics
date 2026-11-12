import Foundation
import SwiftData

/// "Duplicate Scrobbles": plays of the same song that started closer together than a real listen allows, which is how a player or
/// scrobbler that submits twice looks in a history. The first play of a run is the one to keep; the later ones are the extras.
///
/// Last.fm counts a play only once half the song (or four minutes) has been heard, so two real scrobbles of one song cannot start closer
/// together than that. With the song's length known (entered, found online, or Apple Music's):
/// - **certain**: the gap is under the shorter of half the length and four minutes;
/// - **possible**: the gap is longer than that but still under 90% of the length (a skip back to the start is possible);
/// - a gap of 90% or more is a repeat played straight through, which is not flagged: the stored length is often a few seconds longer
///   than the real play, so a back-to-back repeat can look a little short.
/// With no known length the test is a fixed gap (60 seconds unless changed), and anything under it is **possible**.
///
/// Songs are matched the way the rest of the app matches them (`AppleMusicMatcher.durationMatchKey`, so the Song matching settings
/// apply), across albums. Pure: the caller supplies the plays, oldest first, and the lengths.
enum DuplicateScrobblesEngine {
    enum Confidence: String, Sendable, Codable { case certain, possible }

    /// Last.fm's rule for counting a play: half the song or four minutes, whichever is less.
    nonisolated static let scrobbleCapSeconds = 240.0
    /// A gap this share of the song's length or more is a repeat played straight through.
    nonisolated static let straightThroughShare = 0.9

    /// What one pair of neighbouring plays of a song is, given the gap between their starts and the song's length (nil when unknown).
    nonisolated static func verdict(gap: Double, lengthSeconds: Int?, fallbackGapSeconds: Int) -> Confidence? {
        guard let lengthSeconds else { return gap < Double(max(fallbackGapSeconds, 0)) ? .possible : nil }
        let length = Double(lengthSeconds)
        if gap < min(length / 2, scrobbleCapSeconds) { return .certain }
        return gap < length * straightThroughShare ? .possible : nil
    }

    struct Options: Sendable, Equatable {
        /// The gap under which two plays of a song with no known length count as one.
        var fallbackGapSeconds: Int = 60
    }

    struct Cluster: Identifiable, Sendable, Equatable {
        var id: String { "\(key)\u{0}\(Int(times[0].timeIntervalSince1970))" }
        /// The song's match key (artist and normalized title).
        let key: String
        /// The first play's spelling of the artist, title and album.
        let artist: String
        let track: String
        let album: String
        /// Every distinct title the run was scrobbled under (more than one when edition notes were folded together).
        let titles: [String]
        let imageURL: String?
        /// The run, oldest first: the first is kept, each later one is an extra.
        let times: [Date]
        /// The song's length (seconds) the gaps were judged against; nil when it is unknown and the fixed gap was used.
        let lengthSeconds: Int?
        /// Certain when any neighbouring pair in the run is; the rows list every time, so the others can be judged by eye.
        let confidence: Confidence

        var extraPlays: Int { times.count - 1 }
        /// What "I've reviewed this run" is remembered by: the artist, the first play's title and time, and how many plays the run has.
        /// It doesn't depend on the Song matching settings or the fixed gap, and a run that grows (another play joins it) is a different
        /// run again, so something new in it is not hidden by an old review.
        var ignoreKey: String {
            "\(TextNormalization.artistIdentityKey(artist))\u{0}\(track.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())\u{0}\(Int(times[0].timeIntervalSince1970))\u{0}\(times.count)"
        }
        /// The shortest gap between neighbouring plays in the run, in seconds.
        var smallestGap: Double { zip(times, times.dropFirst()).map { $1.timeIntervalSince($0) }.min() ?? 0 }
        var first: Date { times[0] }
        var last: Date { times[times.count - 1] }
    }

    struct Result: Sendable {
        var clusters: [Cluster]
        var extraPlays: Int { clusters.reduce(0) { $0 + $1.extraPlays } }
        var certain: [Cluster] { clusters.filter { $0.confidence == .certain } }
        var possible: [Cluster] { clusters.filter { $0.confidence == .possible } }
    }

    private struct Pair: Hashable { let artist: String; let track: String }

    /// - Parameters:
    ///   - scrobbles: every play, oldest first (artists in one spelling each).
    ///   - lengths: `DurationEngine.Snapshot.secondsLookup`, keyed by `DurationEngine.cacheKey`.
    nonisolated static func find(scrobbles: [ScrobbleSnapshot], lengths: [String: Int], options: Options = Options()) -> Result {
        // Group the plays by exact (artist, title) first: that is cheap, and only the distinct pairs need the match key, which is the
        // costly part. Then pairs with the same match key are merged.
        var byPair: [Pair: [Int]] = [:]
        for (index, play) in scrobbles.enumerated() where !play.trackName.isEmpty {
            byPair[Pair(artist: play.artistName, track: play.trackName), default: []].append(index)
        }
        var byKey: [String: [Int]] = [:]
        for (pair, indexes) in byPair {
            byKey[AppleMusicMatcher.durationMatchKey(artist: pair.artist, track: pair.track), default: []].append(contentsOf: indexes)
        }

        var lengthOf: [Pair: Int?] = [:]
        func length(_ play: ScrobbleSnapshot) -> Int? {
            let pair = Pair(artist: play.artistName, track: play.trackName)
            if let known = lengthOf[pair] { return known }
            let seconds = lengths[DurationEngine.cacheKey(artist: play.artistName, track: play.trackName)].flatMap { $0 > 0 ? $0 : nil }
            lengthOf[pair] = .some(seconds)
            return seconds
        }

        var clusters: [Cluster] = []
        for (key, unsorted) in byKey where unsorted.count > 1 {
            let indexes = unsorted.sorted()
            var run: [Int] = []
            var runConfidence = Confidence.possible
            func close(_ run: inout [Int]) {
                defer { run = [] }
                guard run.count > 1 else { return }
                let plays = run.map { scrobbles[$0] }
                var known: Int?
                for play in plays {
                    if let seconds = length(play) { known = seconds; break }
                }
                let first = plays[0]
                var titles: [String] = []
                for play in plays where !titles.contains(play.trackName) { titles.append(play.trackName) }
                clusters.append(Cluster(
                    key: key, artist: first.artistName, track: first.trackName,
                    album: plays.first { !$0.albumName.isEmpty }?.albumName ?? "",
                    titles: titles,
                    imageURL: plays.first { $0.imageURL != nil && !TextNormalization.isLastfmPlaceholderImage($0.imageURL) }?.imageURL,
                    times: plays.map(\.playedAt), lengthSeconds: known, confidence: runConfidence
                ))
            }
            for position in 1..<indexes.count {
                let earlier = scrobbles[indexes[position - 1]], later = scrobbles[indexes[position]]
                let gap = later.playedAt.timeIntervalSince(earlier.playedAt)
                // The earlier play's length, else the later one's (the same song under another spelling may have one).
                let known = length(earlier) ?? length(later)
                if let found = verdict(gap: gap, lengthSeconds: known, fallbackGapSeconds: options.fallbackGapSeconds) {
                    if run.isEmpty { run = [indexes[position - 1]]; runConfidence = .possible }
                    if found == .certain { runConfidence = .certain }
                    run.append(indexes[position])
                } else {
                    close(&run)
                }
            }
            close(&run)
        }
        clusters.sort { ($0.last, $0.key) > ($1.last, $1.key) }
        return Result(clusters: clusters)
    }

    // MARK: - Reviewed runs

    /// The runs the person has looked at and decided need no action. Kept as one JSON value with the tool's other options (so it is in
    /// backups with them); keys of runs that no longer show (deleted on Last.fm, or hidden by a different setting) are left alone, so
    /// a review is not lost when a setting is changed and changed back.
    struct IgnoredRuns: Codable, Equatable, Sendable {
        var keys: [String] = []

        func contains(_ cluster: Cluster) -> Bool { keys.contains(cluster.ignoreKey) }

        mutating func ignore(_ clusters: [Cluster]) {
            var all = Set(keys)
            for cluster in clusters { all.insert(cluster.ignoreKey) }
            keys = all.sorted()
        }

        mutating func stopIgnoring(_ clusters: [Cluster]) {
            let gone = Set(clusters.map(\.ignoreKey))
            keys = keys.filter { !gone.contains($0) }
        }
    }

    static let ignoredToolId = "duplicatescrobbles.ignored"

    /// The runs to show: those not yet reviewed, or (`ignored`) only the reviewed ones.
    static func visible(_ clusters: [Cluster], ignoredRuns: IgnoredRuns, ignored: Bool) -> [Cluster] {
        let reviewed = Set(ignoredRuns.keys)
        return clusters.filter { reviewed.contains($0.ignoreKey) == ignored }
    }

    // MARK: - Query hand-off

    /// Query on the single plays of the song around the run: that song's title (every spelling the run used) for the days it spans,
    /// oldest first, so the extra plays can be seen next to the neighbouring ones.
    static func spec(for cluster: Cluster, calendar: Calendar = AppCalendars.listening) -> QuerySpec {
        var spec = QuerySpec(target: .scrobble)
        let start = calendar.startOfDay(for: cluster.first)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: cluster.last)) ?? cluster.last
        spec.period = QueryPeriod(from: start, to: nextDay.addingTimeInterval(-1))
        spec.groups = cluster.titles.map { title in
            [QueryCondition("artist", .textIs, [.text(cluster.artist)]), QueryCondition("name", .textIs, [.text(title)])]
        }
        spec.sorts = [QuerySort(key: .field(QueryFieldRef("playedAt")), direction: .ascending)]
        spec.columns = [QueryFieldRef("playedAt"), QueryFieldRef("playAlbum"), QueryFieldRef("playGap")]
        spec.limit = QuerySpec.scrobbleLimit
        return spec
    }

    // MARK: - Wording

    /// "3 plays within 4 seconds", "2 plays 38 seconds apart".
    static func summary(_ cluster: Cluster) -> String {
        let span = cluster.last.timeIntervalSince(cluster.first)
        if cluster.times.count == 2 { return "2 plays \(durationText(span)) apart" }
        return "\(cluster.times.count) plays within \(durationText(span))"
    }

    static func durationText(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole) second\(whole == 1 ? "" : "s")" }
        return String(format: "%d:%02d", whole / 60, whole % 60) + " min"
    }

    static func lengthText(_ cluster: Cluster, fallbackGapSeconds: Int) -> String {
        guard let length = cluster.lengthSeconds else { return "Length unknown · under \(fallbackGapSeconds) s" }
        let share = Int((cluster.smallestGap / Double(length) * 100).rounded())
        return "Length \(durationText(Double(length))) · closest gap \(share < 1 ? "under 1" : String(share))% of it"
    }
}

/// Last.fm's pages for the person's own library, where a play can be deleted.
enum LastfmUserLinks {
    /// One path segment in Last.fm's form: spaces as `+`, everything else that could change the route percent-encoded.
    static func segment(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .addingPercentEncoding(withAllowedCharacters: allowed)?
            .replacingOccurrences(of: "%20", with: "+") ?? ""
    }

    /// The person's play history of one song: `last.fm/user/<name>/library/music/<artist>/_/<track>`.
    static func songHistoryURL(username: String, artist: String, track: String) -> URL? {
        URL(string: "https://www.last.fm/user/\(segment(username))/library/music/\(segment(artist))/_/\(segment(track))")
    }
}
