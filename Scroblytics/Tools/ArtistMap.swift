import Foundation
import CoreGraphics

// The engine behind the Artist Map: which artists are on it, how Last.fm's similar-artist answers join them, which cluster each one
// falls in and where it sits. Everything here is pure (no view, no network) except `ArtistMapLoader`, which reads and fills the local
// answer cache through a provider, so it can be checked with a stand-in.

// MARK: - Names

enum ArtistMapNames {
    /// The same artist however Last.fm and your history spell it: case, accents, "The", "&" or "and", and punctuation are ignored.
    /// Only used to join the two spellings; the map shows the spelling from your history.
    static func key(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
        var spaced = ""
        spaced.reserveCapacity(folded.count)
        for scalar in folded.unicodeScalars {
            spaced.unicodeScalars.append(CharacterSet.alphanumerics.contains(scalar) ? scalar : " ")
        }
        let joined = spaced.split(separator: " ").joined(separator: " ")
        if joined.hasPrefix("the "), joined.count > 4 { return String(joined.dropFirst(4)) }
        return joined
    }
}

// MARK: - Scope

/// An artist the map is about, with the plays that decide its size.
struct ArtistMapEntry: Sendable, Equatable {
    let name: String
    let plays: Int
}

enum ArtistMapScope {
    /// Your most played artists in a period, and the key of every artist you have ever played (a Last.fm neighbor outside the top list but in
    /// your history is left off the map; only one you have never played can appear as a dashed "not played" dot).
    static func top(
        snapshots: [ScrobbleSnapshot], count: Int, from: Date? = nil, to: Date? = nil
    ) -> (entries: [ArtistMapEntry], libraryKeys: Set<String>) {
        var inPeriod: [String: (name: String, plays: Int)] = [:]
        var library = Set<String>()
        for play in snapshots {
            let key = ArtistMapNames.key(play.artistName)
            guard !key.isEmpty else { continue }
            library.insert(key)
            if let from, play.playedAt < from { continue }
            if let to, play.playedAt > to { continue }
            var entry = inPeriod[key] ?? (play.artistName, 0)
            entry.plays += 1
            inPeriod[key] = entry
        }
        let ranked = inPeriod.sorted { l, r in
            l.value.plays != r.value.plays ? l.value.plays > r.value.plays : l.key < r.key
        }
        let entries = ranked.prefix(max(0, count)).map { ArtistMapEntry(name: $0.value.name, plays: $0.value.plays) }
        return (entries, library)
    }
}

// MARK: - Graph

struct ArtistMapGraph: Sendable, Equatable {
    struct Node: Sendable, Equatable {
        let key: String
        let name: String
        /// 0 for an artist you have never played.
        let plays: Int
        let isGhost: Bool
    }

    struct Edge: Sendable, Equatable {
        let a: Int
        let b: Int
        /// How strongly a's answer lists b, and b's answer lists a (0 = not listed). Last.fm's scores are not symmetric.
        let aToB: Double
        let bToA: Double
        /// The line's strength: the higher of the two directions.
        var weight: Double { max(aToB, bToA) }
    }

    var nodes: [Node] = []
    var edges: [Edge] = []

    func index(ofKey key: String) -> Int? { nodes.firstIndex { $0.key == key } }

    /// Never-played artists the map offers at most.
    static let ghostCap = 25
    /// A never-played neighbor is only offered when some artist you play lists it at least this strongly.
    static let ghostFloor = 0.3

    /// `scope` are the artists on the map (any order; the busiest come first in `nodes`). `neighbors` are Last.fm's answers, keyed by
    /// `ArtistMapNames.key` of the artist asked about. `libraryKeys` are all the artists you have ever played.
    static func build(
        scope: [ArtistMapEntry], libraryKeys: Set<String>, neighbors: [String: [SimilarArtist]],
        ghostCap: Int = ghostCap, ghostFloor: Double = ghostFloor
    ) -> ArtistMapGraph {
        // One node per artist: spellings that join count together, and the busiest spelling is shown.
        var merged: [String: (name: String, plays: Int, best: Int)] = [:]
        for entry in scope {
            let key = ArtistMapNames.key(entry.name)
            guard !key.isEmpty else { continue }
            var m = merged[key] ?? (entry.name, 0, -1)
            m.plays += entry.plays
            if entry.plays > m.best { m.best = entry.plays; m.name = entry.name }
            merged[key] = m
        }
        let ordered = merged.sorted { l, r in
            l.value.plays != r.value.plays ? l.value.plays > r.value.plays : l.key < r.key
        }
        var graph = ArtistMapGraph()
        graph.nodes = ordered.map { Node(key: $0.key, name: $0.value.name, plays: $0.value.plays, isGhost: false) }
        let n = graph.nodes.count
        var indexByKey: [String: Int] = [:]
        for (i, node) in graph.nodes.enumerated() { indexByKey[node.key] = i }

        // Directed scores between artists on the map, and what each lists that you have never played.
        var directed: [Int: Double] = [:]
        var ghostScores: [String: (name: String, links: [Int: Double])] = [:]
        for (i, node) in graph.nodes.enumerated() {
            for similar in neighbors[node.key] ?? [] {
                let key = ArtistMapNames.key(similar.name)
                guard !key.isEmpty, key != node.key else { continue }
                if let j = indexByKey[key] {
                    directed[i * n + j] = max(directed[i * n + j] ?? 0, similar.match)
                } else if !libraryKeys.contains(key), similar.match >= ghostFloor {
                    var ghost = ghostScores[key] ?? (similar.name, [:])
                    ghost.links[i] = max(ghost.links[i] ?? 0, similar.match)
                    ghostScores[key] = ghost
                }
            }
        }
        for i in 0..<n {
            for j in (i + 1)..<max(n, i + 1) {
                let forward = directed[i * n + j] ?? 0, backward = directed[j * n + i] ?? 0
                if forward > 0 || backward > 0 { graph.edges.append(Edge(a: i, b: j, aToB: forward, bToA: backward)) }
            }
        }

        // The never-played artists several of yours point at come first.
        let ghosts = ghostScores.sorted { l, r in
            let ls = l.value.links.values.reduce(0, +), rs = r.value.links.values.reduce(0, +)
            return ls != rs ? ls > rs : l.key < r.key
        }.prefix(max(0, ghostCap))
        for (key, ghost) in ghosts {
            let index = graph.nodes.count
            graph.nodes.append(Node(key: key, name: ghost.name, plays: 0, isGhost: true))
            for (i, score) in ghost.links.sorted(by: { $0.key < $1.key }) {
                graph.edges.append(Edge(a: i, b: index, aToB: score, bToA: 0))
            }
        }
        return graph
    }

    /// What the slider and the toggle leave on screen: lines at or above `minMatch`, and never-played dots only when asked for and
    /// still joined to something. Artists you play always stay, joined or not.
    /// On screen every artist keeps its strongest links (and any link another artist counts among its strongest), so a crowded map
    /// stays readable. The panel lists at most six closest links, so none of those is ever lost.
    static let linksPerArtist = 8

    func filtered(minMatch: Double, showGhosts: Bool, linksPerArtist limit: Int? = ArtistMapGraph.linksPerArtist) -> ArtistMapGraph {
        var keep = edges.filter { $0.weight >= minMatch - 1e-9 }
        if let limit {
            var strongest = [[Int]](repeating: [], count: nodes.count)
            for (i, edge) in keep.enumerated() where !nodes[edge.a].isGhost && !nodes[edge.b].isGhost {
                strongest[edge.a].append(i)
                strongest[edge.b].append(i)
            }
            var retained = Set<Int>()
            for list in strongest {
                for i in list.sorted(by: { keep[$0].weight != keep[$1].weight ? keep[$0].weight > keep[$1].weight : $0 < $1 }).prefix(limit) { retained.insert(i) }
            }
            keep = keep.enumerated().filter { retained.contains($0.offset) || nodes[$0.element.a].isGhost || nodes[$0.element.b].isGhost }.map(\.element)
        }
        var linkedGhosts = Set<Int>()
        for edge in keep where nodes[edge.b].isGhost { linkedGhosts.insert(edge.b) }
        var remap: [Int: Int] = [:]
        var out = ArtistMapGraph()
        for (i, node) in nodes.enumerated() {
            if node.isGhost, !(showGhosts && linkedGhosts.contains(i)) { continue }
            remap[i] = out.nodes.count
            out.nodes.append(node)
        }
        for edge in keep {
            if let a = remap[edge.a], let b = remap[edge.b] {
                out.edges.append(Edge(a: a, b: b, aToB: edge.aToB, bToA: edge.bToA))
            }
        }
        return out
    }
}

// MARK: - Groups

/// Clusters of artists that point at each other, found by letting every artist take on the group most of its strongest links belong to.
/// Deterministic: the same graph always gives the same groups.
struct ArtistMapGroups: Sendable, Equatable {
    /// Per node: its group, or -1 for an artist with no group (alone, in a pair that is the whole group, or never played).
    var groupOfNode: [Int] = []
    /// Per group, named after its busiest member.
    var names: [String] = []
    var sizes: [Int] = []

    /// A group needs at least this many artists.
    static let minimumSize = 3

    static func find(in graph: ArtistMapGraph) -> ArtistMapGroups {
        let n = graph.nodes.count
        var adjacent = [[(Int, Double)]](repeating: [], count: n)
        for edge in graph.edges where !graph.nodes[edge.a].isGhost && !graph.nodes[edge.b].isGhost {
            adjacent[edge.a].append((edge.b, edge.weight))
            adjacent[edge.b].append((edge.a, edge.weight))
        }
        var label = Array(0..<n)
        let players = (0..<n).filter { !graph.nodes[$0].isGhost }
        for _ in 0..<40 {
            var changed = false
            for i in players where !adjacent[i].isEmpty {
                var sums: [Int: Double] = [:]
                for (j, w) in adjacent[i] { sums[label[j], default: 0] += w }
                var best = label[i], bestSum = -1.0
                for key in sums.keys.sorted() where sums[key]! > bestSum + 1e-12 { best = key; bestSum = sums[key]! }
                if let current = sums[label[i]], current >= bestSum - 1e-12 { continue }
                label[i] = best
                changed = true
            }
            if !changed { break }
        }
        var members: [Int: [Int]] = [:]
        for i in players { members[label[i], default: []].append(i) }
        let groups = members.values.filter { $0.count >= minimumSize }.sorted { l, r in
            l.count != r.count ? l.count > r.count : l[0] < r[0]
        }
        var result = ArtistMapGroups(groupOfNode: [Int](repeating: -1, count: n))
        for (g, group) in groups.enumerated() {
            for i in group { result.groupOfNode[i] = g }
            // Nodes are in play order, so the first member is the busiest.
            result.names.append(graph.nodes[group[0]].name)
            result.sizes.append(group.count)
        }
        return result
    }
}

// MARK: - Layout

enum ArtistMapLayout {
    /// The drawing area, in points, a layout assumes when it isn't told one.
    static let defaultCanvas = CGSize(width: 900, height: 600)
    /// A dot's radius, in points, when it isn't told one, and the clear space kept between two dots.
    static let defaultRadius = 8.0
    static let defaultGap = 6.0

    /// Where the dots start when nothing says otherwise: a spread that depends only on the artist's name, so a map opens the same way
    /// every time. In the unit square.
    private static func start(_ key: String) -> CGPoint {
        var h: UInt64 = 14_695_981_039_346_656_037
        for byte in key.utf8 { h ^= UInt64(byte); h = h &* 1_099_511_628_211 }
        let angle = Double(h % 3600) / 3600 * 2 * Double.pi
        let radius = 0.05 + 0.35 * (Double((h >> 16) % 1000) / 1000).squareRoot()
        return CGPoint(x: 0.5 + cos(angle) * radius, y: 0.5 + sin(angle) * radius)
    }

    /// Positions in the unit square, one per node, in order. The layout is worked out in points on a `canvas` of the real size, so
    /// distances mean the same thing across and down, and `radii` (points, per node) keep every dot clear of the next. Linked artists are
    /// pulled together in proportion to the match and every pair is pushed apart. `previous` (by artist key, unit square) starts the dots
    /// where they were, so changing the slider nudges the picture instead of redrawing it.
    static func force(
        graph: ArtistMapGraph, previous: [String: CGPoint] = [:], canvas: CGSize = defaultCanvas, radii: [Double] = [], gap: Double = defaultGap
    ) -> [CGPoint] {
        let n = graph.nodes.count
        if n == 0 { return [] }
        let width = max(Double(canvas.width), 50), height = max(Double(canvas.height), 50)
        if n == 1 { return [CGPoint(x: 0.5, y: 0.5)] }
        let radius: [Double] = (0..<n).map { $0 < radii.count ? radii[$0] : defaultRadius }
        let margin = (radius.max() ?? defaultRadius) + gap
        var x = [Double](repeating: 0, count: n), y = [Double](repeating: 0, count: n)
        var warm = false
        var isNew = [Bool](repeating: true, count: n)
        for (i, node) in graph.nodes.enumerated() {
            let p: CGPoint
            if let old = previous[node.key] { p = old; warm = true; isNew[i] = false } else { p = start(node.key) }
            x[i] = Double(p.x) * width; y[i] = Double(p.y) * height
        }
        let scale = (width * height).squareRoot()
        let iterations = warm ? 50 : 320
        let k = 0.75 * (width * height / Double(n)).squareRoot()
        for step in 0..<iterations {
            let cooling = 1 - Double(step) / Double(iterations)
            // A dot that was already on the map only settles a little; one that is new moves freely to find its place.
            let settle = 0.003 * scale * cooling + 0.001 * scale, arrive = 0.08 * scale * cooling + 0.002 * scale, cold = 0.12 * scale * cooling + 0.002 * scale
            var dx = [Double](repeating: 0, count: n), dy = [Double](repeating: 0, count: n)
            for i in 0..<n {
                for j in (i + 1)..<n {
                    var vx = x[i] - x[j], vy = y[i] - y[j]
                    var d = (vx * vx + vy * vy).squareRoot()
                    if d < 1e-6 { vx = 1e-3 * Double(i - j); vy = 1e-3; d = (vx * vx + vy * vy).squareRoot() }
                    let push = k * k / d
                    dx[i] += vx / d * push; dy[i] += vy / d * push
                    dx[j] -= vx / d * push; dy[j] -= vy / d * push
                }
            }
            for edge in graph.edges {
                let vx = x[edge.a] - x[edge.b], vy = y[edge.a] - y[edge.b]
                let d = max((vx * vx + vy * vy).squareRoot(), 1e-6)
                let pull = d * d / k * (0.25 + 0.75 * edge.weight)
                dx[edge.a] -= vx / d * pull; dy[edge.a] -= vy / d * pull
                dx[edge.b] += vx / d * pull; dy[edge.b] += vy / d * pull
            }
            for i in 0..<n {
                // A light pull to the middle keeps unlinked dots from being flung to the edge.
                dx[i] += (width / 2 - x[i]) * 1.0 * k / scale; dy[i] += (height / 2 - y[i]) * 1.0 * k / scale
                let d = max((dx[i] * dx[i] + dy[i] * dy[i]).squareRoot(), 1e-9)
                let move = min(d, warm ? (isNew[i] ? arrive : settle) : cold)
                x[i] += dx[i] / d * move; y[i] += dy[i] / d * move
            }
        }
        // Fill the canvas (keeping the shape), then make sure no two dots touch. A picture that grew out of an earlier one keeps its
        // scale (so the slider nudges it); it is only refitted if it left the canvas.
        let minX = x.min()!, maxX = x.max()!, minY = y.min()!, maxY = y.max()!
        let wall = (radius.max() ?? defaultRadius) + gap / 2   // the closest `separate` lets a dot come to the edge
        let outside = minX < wall - 0.5 || minY < wall - 0.5 || maxX > width - wall + 0.5 || maxY > height - wall + 0.5
        if !warm || outside {
            let spanX = maxX - minX, spanY = maxY - minY
            let factorX = spanX > 1e-9 ? (width - 2 * margin) / spanX : 1
            let factorY = spanY > 1e-9 ? (height - 2 * margin) / spanY : 1
            for i in 0..<n {
                x[i] = width / 2 + (x[i] - (minX + maxX) / 2) * factorX
                y[i] = height / 2 + (y[i] - (minY + maxY) / 2) * factorY
            }
        }
        separate(&x, &y, radii: radius, gap: gap, within: CGSize(width: width, height: height))
        return (0..<n).map { CGPoint(x: x[$0] / width, y: y[$0] / height) }
    }

    /// Pushes apart any two dots closer than their radii plus `gap`, keeping every dot inside the canvas.
    static func separate(_ x: inout [Double], _ y: inout [Double], radii: [Double], gap: Double, within canvas: CGSize) {
        let n = x.count
        let width = Double(canvas.width), height = Double(canvas.height)
        let wall = (radii.max() ?? defaultRadius) + gap / 2
        for _ in 0..<150 {
            var moved = false
            for i in 0..<n {
                for j in (i + 1)..<n {
                    var vx = x[i] - x[j], vy = y[i] - y[j]
                    var d = (vx * vx + vy * vy).squareRoot()
                    let wanted = radii[i] + radii[j] + gap
                    if d >= wanted { continue }
                    if d < 1e-9 { vx = 1; vy = 0; d = 1 }
                    let shift = (wanted - d) / 2 + 0.05
                    x[i] += vx / d * shift; y[i] += vy / d * shift
                    x[j] -= vx / d * shift; y[j] -= vy / d * shift
                    moved = true
                }
            }
            for i in 0..<n { x[i] = min(width - wall, max(wall, x[i])); y[i] = min(height - wall, max(wall, y[i])) }
            if !moved { break }
        }
    }
}

// MARK: - Answers: where they come from

/// Last.fm's similar-artist answers. The real one asks Last.fm and remembers the answer; checks use a stand-in.
protocol ArtistMapNeighborProviding: Sendable {
    /// The saved answer, or nil when there is none (or it is out of date). Never touches the network.
    func savedNeighbors(of artist: String) async -> [SimilarArtist]?
    /// Asks Last.fm and saves the answer. A failure (offline, rate limit, network) is thrown and nothing is saved.
    func fetchNeighbors(of artist: String) async throws -> [SimilarArtist]
}

private struct ArtistMapStored: Codable {
    let name: String
    let match: Double
}

/// The saved answers, read and written the same way whether or not an account is connected.
enum ArtistMapAnswers {
    /// The map keeps Last.fm's 100 closest artists under its own cache key, apart from Rabbit Hole's 30.
    static let neighborLimit = 100

    static func cacheKey(_ artist: String) -> String { "artistmap\u{1F}\(artist.lowercased())" }

    static func read(_ store: SimilarityCacheStore, artist: String) async -> [SimilarArtist]? {
        guard let data = await store.read(cacheKey(artist), maxAge: LastfmSimilarityProvider.maxAge),
              let stored = try? JSONDecoder().decode([ArtistMapStored].self, from: data) else { return nil }
        return stored.map { SimilarArtist(name: $0.name, match: $0.match) }
    }

    static func write(_ store: SimilarityCacheStore, list: [SimilarArtist], artist: String) async {
        guard let data = try? JSONEncoder().encode(list.map { ArtistMapStored(name: $0.name, match: $0.match) }) else { return }
        await store.write(cacheKey(artist), payload: data)
    }
}

extension LastfmSimilarityProvider: ArtistMapNeighborProviding {
    static let mapNeighborLimit = ArtistMapAnswers.neighborLimit
    static func mapCacheKey(_ artist: String) -> String { ArtistMapAnswers.cacheKey(artist) }

    func savedNeighbors(of artist: String) async -> [SimilarArtist]? { await ArtistMapAnswers.read(store, artist: artist) }

    func saveNeighbors(_ list: [SimilarArtist], of artist: String) async { await ArtistMapAnswers.write(store, list: list, artist: artist) }

    func fetchNeighbors(of artist: String) async throws -> [SimilarArtist] {
        let fetched = try await client.fetchSimilarArtistsChecked(artist: artist, limit: Self.mapNeighborLimit)
        await saveNeighbors(fetched, of: artist)
        return fetched
    }
}

/// What the map can use when no Last.fm account is connected: the saved answers, and no way to ask for more.
struct ArtistMapSavedProvider: ArtistMapNeighborProviding {
    struct NoAccount: Error {}
    let store: SimilarityCacheStore

    func savedNeighbors(of artist: String) async -> [SimilarArtist]? { await ArtistMapAnswers.read(store, artist: artist) }
    func fetchNeighbors(of artist: String) async throws -> [SimilarArtist] { throw NoAccount() }
}

enum ArtistMapLinks {
    /// What "Open in Query" shows for an artist: the tracks you have played by it, most played first.
    static func querySpec(artist: String) -> QuerySpec {
        var spec = QuerySpec(target: .track)
        spec.groups = [[QueryCondition("artist", .textIs, [.text(artist)]), QueryCondition("plays", .greaterThan, [.number(0)])]]
        spec.sorts = [QuerySort(key: .field(QueryFieldRef("plays")), direction: .descending)]
        spec.columns = AskInterpreter.baseColumns.map { QueryFieldRef($0) }
        return spec
    }

    /// An artist's public page on Last.fm. Last.fm writes spaces as `+` and each part is encoded on its own.
    static func lastfmURL(artist: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~ ")
        let name = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://www.last.fm/music/" + encoded.replacingOccurrences(of: " ", with: "+").replacingOccurrences(of: "%20", with: "+"))
    }
}

// MARK: - Loading

enum ArtistMapLoader {
    struct Summary: Sendable, Equatable {
        /// Artists whose answer was already saved, fetched now, or still without one.
        var fromSaved = 0
        var fetched = 0
        var missing = 0
        var failed = 0
        /// Why fetching ended early, when it did.
        var stopped: Stop?
    }

    enum Stop: Sendable, Equatable { case offline, cancelled, tooManyFailures }

    /// After this many failures in a row the lookups stop instead of hammering a service that is down.
    static let failureLimit = 5

    struct Update: Sendable {
        let key: String
        let neighbors: [SimilarArtist]
        let fromSaved: Bool
        let done: Int
        let total: Int
    }

    /// Reads the saved answer for every artist first (instantly, no network), then, when `fetchMissing`, asks Last.fm for the rest one by
    /// one, calling `onUpdate` after each answer so the map can grow. Stops when the task is cancelled or Offline mode is on; an offline or
    /// failed lookup is never recorded as "no neighbors".
    static func load(
        artists: [String], provider: any ArtistMapNeighborProviding, fetchMissing: Bool,
        isOffline: @Sendable () -> Bool, onUpdate: @Sendable (Update) -> Void
    ) async -> (neighbors: [String: [SimilarArtist]], summary: Summary) {
        var neighbors: [String: [SimilarArtist]] = [:]
        var summary = Summary()
        var missing: [String] = []
        var seen = Set<String>()
        for artist in artists {
            let key = ArtistMapNames.key(artist)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            if let saved = await provider.savedNeighbors(of: artist) {
                neighbors[key] = saved
                summary.fromSaved += 1
                onUpdate(Update(key: key, neighbors: saved, fromSaved: true, done: summary.fromSaved, total: seen.count))
            } else {
                missing.append(artist)
            }
        }
        summary.missing = missing.count
        guard fetchMissing, !missing.isEmpty else { return (neighbors, summary) }

        var consecutiveFailures = 0
        for artist in missing {
            if Task.isCancelled { summary.stopped = .cancelled; break }
            if isOffline() { summary.stopped = .offline; break }
            do {
                let list = try await provider.fetchNeighbors(of: artist)
                let key = ArtistMapNames.key(artist)
                neighbors[key] = list
                summary.fetched += 1
                summary.missing -= 1
                consecutiveFailures = 0
                onUpdate(Update(key: key, neighbors: list, fromSaved: false, done: summary.fromSaved + summary.fetched, total: seen.count))
            } catch is CancellationError {
                summary.stopped = .cancelled
                break
            } catch {
                summary.failed += 1
                consecutiveFailures += 1
                if consecutiveFailures >= failureLimit { summary.stopped = .tooManyFailures; break }
            }
        }
        return (neighbors, summary)
    }
}
