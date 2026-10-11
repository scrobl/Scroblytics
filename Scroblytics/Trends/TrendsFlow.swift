import Foundation

/// "Listening flow": what you play right after what, within one sitting. Plays are split into sessions wherever the
/// gap between two plays is longer than the session gap; inside a session every pair of neighbouring plays is a
/// hand-off from one artist (or genre) to the next. The same artist twice in a row is repeat listening, not a hand-off,
/// so it isn't counted. Only plays inside the selected period are used, so nothing straddles its edge.
struct TrendsFlow: Sendable {
    enum Granularity: String, CaseIterable, Identifiable, Sendable {
        case artist, genre
        var id: String { rawValue }
        var label: String { self == .artist ? "Artists" : "Genres" }
    }

    enum EdgeStatus: Sendable { case shared, new, dropped }

    struct Node: Identifiable, Sendable, Hashable {
        let id: String
        /// Plays in the period.
        let plays: Int
        /// How many sessions it opened / closed, and the hand-offs in and out (of the ones shown).
        let opens: Int
        let closes: Int
        let inCount: Int
        let outCount: Int
        /// Connected group (0 = the biggest), for grouping and colour.
        let cluster: Int
        /// The share of its plays that were the first / last of a session.
        var openShare: Double { plays == 0 ? 0 : Double(opens) / Double(plays) }
        var closeShare: Double { plays == 0 ? 0 : Double(closes) / Double(plays) }
    }

    struct Edge: Identifiable, Sendable, Hashable {
        let source: String
        let target: String
        /// This period's count (the previous period's, for a dropped edge).
        let count: Int
        let status: EdgeStatus
        /// The previous period's count, when comparing (0 when it wasn't there).
        let previousCount: Int?
        var id: String { source + "\u{0}" + target }
    }

    let granularity: Granularity
    let gapMinutes: Int
    let minTransitions: Int
    let range: DateRange
    let compareRange: DateRange?
    let sessionCount: Int
    /// Hand-offs before the minimum-count filter.
    let totalTransitions: Int
    let nodes: [Node]
    let edges: [Edge]

    var comparing: Bool { compareRange != nil }
}

enum TrendsFlowEngine {
    /// The raw counts for one period.
    struct Counts: Sendable {
        var plays: [String: Int] = [:]
        var opens: [String: Int] = [:]
        var closes: [String: Int] = [:]
        var transitions: [Pair: Int] = [:]
        var sessions = 0
        var totalTransitions: Int { transitions.values.reduce(0, +) }
    }

    struct Pair: Hashable, Sendable { let from: String; let to: String }

    /// `scrobbles` must be sorted by time (ties in their stored order) with canonical artist names. `label` turns a
    /// play's artist into the thing plotted (the artist, or its dominant genre); nil leaves the play out.
    static func counts(scrobbles: [ScrobbleSnapshot], range: DateRange, gapMinutes: Int, label: (String) -> String?) -> Counts {
        var counts = Counts()
        let gap = Double(gapMinutes) * 60
        var lastTime: Date?                       // the previous play of any kind, for the gap
        var previous: String?                     // the previous labelled play in this session
        var sessionOpen = false                   // this session already has its first play recorded
        var last: String?                         // the last labelled play of the session, to close it

        func closeSession() { if let last { counts.closes[last, default: 0] += 1 }; last = nil; previous = nil; sessionOpen = false }

        for s in scrobbles where s.playedAt >= range.from && s.playedAt <= range.to {
            if let t = lastTime, s.playedAt.timeIntervalSince(t) > gap { closeSession() }
            lastTime = s.playedAt
            // A play with nothing to plot (no artist, or an untagged artist in the genre view) hands off to nothing.
            guard !s.artistName.isEmpty, let name = label(s.artistName) else { previous = nil; continue }
            counts.plays[name, default: 0] += 1
            if !sessionOpen {
                sessionOpen = true
                counts.sessions += 1
                counts.opens[name, default: 0] += 1
            }
            if let p = previous, p != name { counts.transitions[Pair(from: p, to: name), default: 0] += 1 }
            previous = name
            last = name
        }
        closeSession()
        return counts
    }

    static func compute(
        scrobbles: [ScrobbleSnapshot], tags: EntityTagsSnapshot, granularity: TrendsFlow.Granularity, gapMinutes: Int, minTransitions: Int,
        range: DateRange, compareRange: DateRange?
    ) -> TrendsFlow {
        // The dominant genre of an artist is its first (most-applied) community tag.
        var genreCache: [String: String?] = [:]
        let label: (String) -> String? = { artist in
            guard granularity == .genre else { return artist }
            if let cached = genreCache[artist] { return cached }
            let genre = tags.tags(forArtist: artist)?.first.map { LastfmTagNormalization.normalize($0) }.flatMap { $0.isEmpty ? nil : $0 }
            genreCache[artist] = .some(genre)
            return genre
        }
        let current = counts(scrobbles: scrobbles, range: range, gapMinutes: gapMinutes, label: label)
        let previous = compareRange.map { counts(scrobbles: scrobbles, range: $0, gapMinutes: gapMinutes, label: label) }

        var edges: [TrendsFlow.Edge] = []
        let keep = current.transitions.filter { $0.value >= minTransitions }
        let previousKeep = previous?.transitions.filter { $0.value >= minTransitions } ?? [:]
        for (pair, count) in keep {
            let status: TrendsFlow.EdgeStatus = previous == nil ? .shared : (previousKeep[pair] != nil ? .shared : .new)
            edges.append(.init(source: pair.from, target: pair.to, count: count, status: status, previousCount: previous.map { $0.transitions[pair] ?? 0 }))
        }
        for (pair, count) in previousKeep where keep[pair] == nil {
            edges.append(.init(source: pair.from, target: pair.to, count: count, status: .dropped, previousCount: count))
        }
        edges.sort { $0.count != $1.count ? $0.count > $1.count : ($0.source, $0.target) < ($1.source, $1.target) }

        // Nodes: everything that appears in an edge; clusters are the connected groups of this period's edges.
        var neighbours: [String: Set<String>] = [:]
        var inCount: [String: Int] = [:], outCount: [String: Int] = [:]
        for e in edges where e.status != .dropped {
            neighbours[e.source, default: []].insert(e.target)
            neighbours[e.target, default: []].insert(e.source)
            outCount[e.source, default: 0] += e.count
            inCount[e.target, default: 0] += e.count
        }
        let ids = Set(edges.flatMap { [$0.source, $0.target] })
        var clusterOf: [String: Int] = [:]
        var groups: [[String]] = []
        for id in ids.sorted() where clusterOf[id] == nil {
            var stack = [id], group: [String] = []
            clusterOf[id] = -1
            while let n = stack.popLast() {
                group.append(n)
                for m in neighbours[n] ?? [] where clusterOf[m] == nil { clusterOf[m] = -1; stack.append(m) }
            }
            groups.append(group)
        }
        groups.sort { $0.count != $1.count ? $0.count > $1.count : $0[0] < $1[0] }
        for (rank, group) in groups.enumerated() { for id in group { clusterOf[id] = rank } }

        let nodes = ids.map { id in
            TrendsFlow.Node(id: id, plays: current.plays[id] ?? 0, opens: current.opens[id] ?? 0, closes: current.closes[id] ?? 0,
                            inCount: inCount[id] ?? 0, outCount: outCount[id] ?? 0, cluster: clusterOf[id] ?? 0)
        }
        .sorted { $0.plays != $1.plays ? $0.plays > $1.plays : $0.id < $1.id }

        return TrendsFlow(
            granularity: granularity, gapMinutes: gapMinutes, minTransitions: minTransitions, range: range, compareRange: compareRange,
            sessionCount: current.sessions, totalTransitions: current.totalTransitions, nodes: nodes, edges: edges
        )
    }
}
