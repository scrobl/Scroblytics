import Foundation
import AppKit
import SwiftData
import SwiftUI
import CoreGraphics

#if DEBUG
/// `SCROBLYTICS_ARTISTMAP_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): the Artist Map engine on made-up artists. How Last.fm
/// names are joined to yours, the graph (both directions of a score, never-played neighbors, the slider and toggle), the groups, the layout
/// (deterministic, inside the square, no two dots on top of each other, linked artists closer), the lookups (saved answers first, never any
/// network while offline, a failure never recorded as "nothing similar") and the local answer cache. Exits 0 on success.
enum ArtistMapChecks {
    @MainActor
    private final class Report {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
            if !ok { failures += 1 }
        }
    }

    /// A value several tasks can share.
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func with<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
    }

    /// Stands in for Last.fm and the saved answers.
    private final class StubProvider: ArtistMapNeighborProviding, @unchecked Sendable {
        let saved: Box<[String: [SimilarArtist]]>
        let stale: [String: [SimilarArtist]]
        let answers: [String: [SimilarArtist]]
        let failing: Set<String>
        let delay: UInt64
        let calls = Box<[String]>([])

        init(saved: [String: [SimilarArtist]] = [:], stale: [String: [SimilarArtist]] = [:], answers: [String: [SimilarArtist]] = [:], failing: Set<String> = [], delay: UInt64 = 0) {
            self.saved = Box(saved)
            self.stale = stale
            self.answers = answers
            self.failing = failing
            self.delay = delay
        }

        func savedNeighbors(of artist: String) async -> [SimilarArtist]? { saved.with { $0[artist] } }
        func staleNeighbors(of artist: String) async -> [SimilarArtist]? { stale[artist] }

        func fetchNeighbors(of artist: String) async throws -> [SimilarArtist] {
            calls.with { $0.append(artist) }
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            if failing.contains(artist) { throw URLError(.notConnectedToInternet) }
            let list = answers[artist] ?? []
            saved.with { $0[artist] = list }
            return list
        }
    }

    private static func sim(_ name: String, _ match: Double) -> SimilarArtist { SimilarArtist(name: name, match: match) }
    private static func key(_ name: String) -> String { ArtistMapNames.key(name) }
    private static func distance(_ p: CGPoint, _ q: CGPoint) -> Double { hypot(Double(p.x - q.x), Double(p.y - q.y)) }
    /// The distance between two positions in points on the layout's default canvas (the unit square is stretched to it).
    private static func points(_ p: CGPoint, _ q: CGPoint) -> Double {
        let canvas = ArtistMapLayout.defaultCanvas
        return hypot(Double(p.x - q.x) * Double(canvas.width), Double(p.y - q.y) * Double(canvas.height))
    }
    private static let clearance = 2 * ArtistMapLayout.defaultRadius + ArtistMapLayout.defaultGap

    /// Every name pointing at all the others at 70%.
    private static func clique(_ names: [String]) -> [String: [SimilarArtist]] {
        var out: [String: [SimilarArtist]] = [:]
        for name in names { out[key(name)] = names.filter { $0 != name }.map { sim($0, 0.7) } }
        return out
    }

    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_ARTISTMAP_CHECK"] != nil else { return }
        Task { @MainActor in
            let report = Report()
            namesAndScope(report)
            let graph = graphChecks(report)
            sliderChecks(report, graph)
            groupChecks(report)
            layoutChecks(report, container)
            seedChecks(report)
            refinementChecks(report, container)
            await lookupChecks(report)
            await cacheChecks(report, container)
            print(report.failures == 0 ? "ALL CHECKS PASSED" : "\(report.failures) CHECK(S) FAILED")
            exit(report.failures == 0 ? 0 : 1)
        }
    }

    // MARK: Names and scope

    @MainActor
    private static func namesAndScope(_ r: Report) {
        let joined = key("The Artist A") == key("artist a") && key("Artist & B") == key("Artist and B")
        let folded = key("Café Band") == key("Cafe Band") && key("Band-C") == key("Band C")
        let punctuated = key("Band: D") == key("Band:D") && key("Jim O'Rourke") == key("Jim O’Rourke")
        r.check("case, accents, “The”, “&”/“and” and punctuation all join", joined && folded && punctuated)
        let apart = key("Artist A") != key("Artist B")
        let edgeCases = key("The") == "the" && key("").isEmpty && key("!!!").isEmpty
        r.check("different artists stay apart; a name that is only “The” keeps it; empty stays empty", apart && edgeCases)
        r.check("a name in another script keeps its letters", key("日本のバンド") == "日本のバンド")

        func play(_ artist: String, _ day: Int) -> ScrobbleSnapshot {
            ScrobbleSnapshot(artistName: artist, albumName: "Album", trackName: "Track", imageURL: nil, playedAt: Date(timeIntervalSince1970: Double(day) * 86_400))
        }
        let history = [play("Artist A", 1), play("Artist A", 2), play("The Artist A", 3), play("Artist B", 3), play("Artist B", 40), play("Artist C", 41), play("Artist C", 42), play("Artist Old", 1)]
        let top2 = ArtistMapScope.top(snapshots: history, count: 2)
        let plays = top2.entries.map(\.plays)
        r.check("the top artists are ranked by plays, spellings that join counting together", plays == [3, 2] && top2.entries[0].name.hasSuffix("Artist A"), "\(top2.entries)")
        let everyone = Set(["Artist A", "Artist B", "Artist C", "Artist Old"].map(key))
        r.check("the library is every artist ever played, not just those on the map", top2.libraryKeys == everyone, "\(top2.libraryKeys)")
        let late = ArtistMapScope.top(snapshots: history, count: 5, from: Date(timeIntervalSince1970: 30 * 86_400), to: nil)
        r.check("a period counts only its plays but keeps the whole library", late.entries.map(\.name) == ["Artist C", "Artist B"] && late.libraryKeys.count == 4, "\(late.entries)")
        let none = ArtistMapScope.top(snapshots: history, count: 0).entries.isEmpty && ArtistMapScope.top(snapshots: history, count: -3).entries.isEmpty
        r.check("a count of zero or below gives an empty map", none)
        // A big history: 367,000 plays by 4,000 artists, in a few spellings each.
        var big: [ScrobbleSnapshot] = []
        big.reserveCapacity(367_000)
        for i in 0..<367_000 { big.append(play(i % 7 == 0 ? "the band \(i % 4_000)" : "Band \(i % 4_000)", i % 900)) }
        let started = Date()
        let bigTop = ArtistMapScope.top(snapshots: big, count: 200)
        let seconds = Date().timeIntervalSince(started)
        print("INFO  top 200 of 4,000 artists over 367,000 plays took \(String(format: "%.2f", seconds)) s")
        r.check("choosing the top 200 of a 367,000-play history takes well under 3 seconds", bigTop.entries.count == 200 && bigTop.libraryKeys.count == 4_000 && seconds < 3, "\(seconds) s")
    }

    // MARK: Graph

    @MainActor
    private static func graphChecks(_ r: Report) -> ArtistMapGraph {
        let names = [("Artist D", 40), ("Artist A", 100), ("Artist C", 60), ("Artist B", 80), ("Artist E", 20)]
        let scope = names.map { ArtistMapEntry(name: $0.0, plays: $0.1) }
        let library = Set(["artist a", "artist b", "artist c", "artist d", "artist e", "artist f"])
        var answers: [String: [SimilarArtist]] = [:]
        answers[key("Artist A")] = [sim("Artist B", 0.8), sim("Artist C", 0.5), sim("Artist F", 0.9), sim("Artist A", 0.7), sim("artist b", 0.85), sim("Ghost One", 0.6)]
        answers[key("Artist B")] = [sim("Artist A", 0.6), sim("Artist D", 0.3), sim("Ghost One", 0.5), sim("Ghost Two", 0.25)]
        answers[key("Artist E")] = [sim("The Artist A", 0.45)]
        let graph = ArtistMapGraph.build(scope: scope, libraryKeys: library, neighbors: answers)
        let order = graph.nodes.map(\.name)
        r.check("the busiest artist comes first, then the rest in order, then the never-played", order == ["Artist A", "Artist B", "Artist C", "Artist D", "Artist E", "Ghost One"], "\(order)")

        func edge(_ a: String, _ b: String) -> ArtistMapGraph.Edge? {
            guard let i = graph.index(ofKey: key(a)), let j = graph.index(ofKey: key(b)) else { return nil }
            return graph.edges.first { ($0.a == i && $0.b == j) || ($0.a == j && $0.b == i) }
        }
        let ab = edge("Artist A", "Artist B")
        r.check("both directions of a score are kept, and the line takes the higher", ab?.aToB == 0.85 && ab?.bToA == 0.6 && ab?.weight == 0.85, "\(String(describing: ab))")
        let ac = edge("Artist A", "Artist C"), bd = edge("Artist B", "Artist D")
        r.check("a score listed one way only still joins the two", ac?.aToB == 0.5 && ac?.bToA == 0 && bd?.weight == 0.3)
        let ae = edge("Artist A", "Artist E")
        r.check("another spelling of the same artist (“The Artist A”) is the same dot", ae?.aToB == 0 && ae?.bToA == 0.45)
        r.check("an artist is never joined to itself", !graph.edges.contains { $0.a == $0.b })
        r.check("a neighbor you have played but who isn't on the map is left off", graph.index(ofKey: key("Artist F")) == nil)
        let ghostOne = graph.index(ofKey: key("Ghost One")) != nil, ghostTwo = graph.index(ofKey: key("Ghost Two")) != nil
        r.check("a never-played neighbor is a dot only when listed strongly enough (Ghost Two at 25% is not)", ghostOne && !ghostTwo)
        let ghostLinks = graph.edges.filter { $0.b == 5 }.map(\.aToB).sorted()
        r.check("the never-played dot is joined to each artist that lists it", graph.nodes[5].isGhost && graph.nodes[5].plays == 0 && ghostLinks == [0.5, 0.6], "\(ghostLinks)")
        r.check("in all there are 6 dots and 6 lines", graph.nodes.count == 6 && graph.edges.count == 6, "\(graph.nodes.count) \(graph.edges.count)")

        let twoSpellings = [ArtistMapEntry(name: "artist a", plays: 40), ArtistMapEntry(name: "Artist A", plays: 60)]
        let merged = ArtistMapGraph.build(scope: twoSpellings, libraryKeys: library, neighbors: [:])
        r.check("two spellings of one artist become one dot with their plays added, shown as the busier spelling", merged.nodes.count == 1 && merged.nodes[0].plays == 100 && merged.nodes[0].name == "Artist A")
        r.check("no artists give an empty graph", ArtistMapGraph.build(scope: [], libraryKeys: [], neighbors: [:]).nodes.isEmpty)

        let many = (1...30).map { sim(String(format: "Ghost %02d", $0), 0.9 - Double($0) * 0.01) }
        let two = [ArtistMapEntry(name: "Artist A", plays: 9), ArtistMapEntry(name: "Artist B", plays: 8)]
        var cappedAnswers: [String: [SimilarArtist]] = [:]
        cappedAnswers[key("Artist A")] = many
        cappedAnswers[key("Artist B")] = [sim("Ghost 30", 0.9)]
        let capped = ArtistMapGraph.build(scope: two, libraryKeys: library, neighbors: cappedAnswers)
        let cappedGhosts = capped.nodes.filter(\.isGhost).map(\.name)
        r.check("never-played dots are capped at \(ArtistMapGraph.ghostCap)", cappedGhosts.count == ArtistMapGraph.ghostCap, "\(cappedGhosts.count)")
        let rankedFirst = cappedGhosts.first == "Ghost 30" && cappedGhosts.contains("Ghost 24") && !cappedGhosts.contains("Ghost 28")
        r.check("and the ones several of your artists point at rank first, even when each link is weaker", rankedFirst, "\(cappedGhosts.prefix(3)) … \(cappedGhosts.suffix(2))")
        return graph
    }

    // MARK: Slider and toggle

    @MainActor
    private static func sliderChecks(_ r: Report, _ graph: ArtistMapGraph) {
        let atForty = graph.filtered(minMatch: 0.4, showGhosts: false)
        let keepsD = atForty.nodes.contains { $0.name == "Artist D" }
        r.check("the slider hides the weaker lines and keeps every artist you play, linked or not", atForty.nodes.count == 5 && atForty.edges.count == 3 && keepsD, "\(atForty.nodes.count) \(atForty.edges.count)")
        let atFifty = graph.filtered(minMatch: 0.5, showGhosts: false)
        r.check("a line exactly at the minimum stays", atFifty.edges.contains { $0.weight == 0.5 })
        let withGhosts = graph.filtered(minMatch: 0.4, showGhosts: true)
        r.check("the never-played toggle adds the dot with its lines", withGhosts.nodes.count == 6 && withGhosts.edges.count == 5)
        let atFiftyFive = graph.filtered(minMatch: 0.55, showGhosts: true)
        r.check("only the lines that clear the slider are kept, and the dot stays while one of them reaches it", atFiftyFive.edges.count == 2 && atFiftyFive.nodes.contains { $0.isGhost })
        let atSeventy = graph.filtered(minMatch: 0.7, showGhosts: true)
        r.check("a never-played dot with no line left is dropped", !atSeventy.nodes.contains { $0.isGhost })
        let valid = atForty.edges.allSatisfy { $0.a >= 0 && $0.b < atForty.nodes.count && $0.a < $0.b }
        r.check("the filtered graph's lines point at real dots", valid)
    }

    // MARK: Groups

    @MainActor
    private static func groupChecks(_ r: Report) {
        let xs = ["X1", "X2", "X3", "X4"], ys = ["Y1", "Y2", "Y3"], pair = ["P1", "P2"]
        var answers = clique(xs).merging(clique(ys)) { a, _ in a }.merging(clique(pair)) { a, _ in a }
        answers[key("X4")]?.append(sim("Y1", 0.35))
        let plays = [90, 80, 70, 60, 50, 40, 30, 5, 4, 10]
        let scope: [ArtistMapEntry] = zip(xs + ys + pair + ["Z"], plays).map { ArtistMapEntry(name: $0, plays: $1) }
        let libraryKeys = Set(scope.map { key($0.name) })
        let graph = ArtistMapGraph.build(scope: scope, libraryKeys: libraryKeys, neighbors: answers)
        let groups = ArtistMapGroups.find(in: graph)
        func groupOf(_ name: String) -> Int { graph.index(ofKey: key(name)).map { groups.groupOfNode[$0] } ?? -9 }
        r.check("two clusters are found, the larger first", groups.names.count == 2 && groups.sizes == [4, 3], "\(groups.names) \(groups.sizes)")
        let xGroup = Set(xs.map(groupOf)), yGroup = Set(ys.map(groupOf))
        r.check("each artist is in its own cluster, a weak link between clusters doesn't merge them", xGroup == [0] && yGroup == [1])
        r.check("a cluster is named after its busiest artist", groups.names == ["X1", "Y1"])
        r.check("a pair or a lone artist is in no group", groupOf("P1") == -1 && groupOf("P2") == -1 && groupOf("Z") == -1)

        var sameEveryTime = true
        for seed in 0..<6 {
            var rng = SeededRandom(seed: UInt64(seed + 1))
            let shuffled = ArtistMapGraph.build(scope: scope.shuffled(using: &rng), libraryKeys: libraryKeys, neighbors: answers)
            let found = ArtistMapGroups.find(in: shuffled)
            for index in shuffled.nodes.indices where found.groupOfNode[index] != groupOf(shuffled.nodes[index].name) { sameEveryTime = false }
        }
        r.check("the same artists give the same groups whatever order they arrive in", sameEveryTime)

        var withGhostAnswers = answers
        withGhostAnswers[key("X1")] = (answers[key("X1")] ?? []) + [sim("Ghost One", 0.9)]
        let withGhost = ArtistMapGraph.build(scope: scope, libraryKeys: libraryKeys, neighbors: withGhostAnswers)
        let ghostGroups = ArtistMapGroups.find(in: withGhost)
        r.check("a never-played dot is never in a group", withGhost.nodes.last?.isGhost == true && ghostGroups.groupOfNode[withGhost.nodes.count - 1] == -1)
        let hidden = ArtistMapGroups.find(in: graph.filtered(minMatch: 0.4, showGhosts: false))
        r.check("groups follow the lines left on screen (the weak bridge is gone and nothing changes)", hidden.sizes == [4, 3])
    }

    // MARK: Layout

    @MainActor
    private static func layoutChecks(_ r: Report, _ container: ModelContainer) {
        var answers: [String: [SimilarArtist]] = [:]
        var scope: [ArtistMapEntry] = []
        for c in 0..<3 {
            let names = (1...5).map { "C\(c)-\($0)" }
            for (i, name) in names.enumerated() { scope.append(ArtistMapEntry(name: name, plays: 1000 - c * 100 - i * 10)) }
            answers.merge(clique(names)) { a, _ in a }
        }
        answers[key("C0-1")]?.append(sim("C1-1", 0.35))
        answers[key("C1-1")]?.append(sim("C2-1", 0.35))
        let libraryKeys = Set(scope.map { key($0.name) })
        let graph = ArtistMapGraph.build(scope: scope, libraryKeys: libraryKeys, neighbors: answers)
        let layout = ArtistMapLayout.force(graph: graph)
        let inside = layout.allSatisfy { $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 }
        r.check("every dot gets a position inside the square", layout.count == graph.nodes.count && inside)
        r.check("the same map is laid out the same way every time", layout == ArtistMapLayout.force(graph: graph))

        var closest = Double.infinity
        for i in layout.indices { for j in (i + 1)..<layout.count { closest = min(closest, points(layout[i], layout[j])) } }
        r.check("no two dots touch: each is clear of the next by the gap, across and down alike", closest >= clearance - 0.01, "closest \(closest) pt, need \(clearance)")



        // A crowded map: 30 artists all pointing at each other, with scores that differ.
        let crowdNames = (1...30).map { "Crowd \($0)" }
        var crowd: [String: [SimilarArtist]] = [:]
        for (i, name) in crowdNames.enumerated() {
            crowd[key(name)] = crowdNames.enumerated().filter { $0.offset != i }.map { sim($0.element, 0.4 + Double(($0.offset * 7 + i * 3) % 50) / 100) }
        }
        let crowdScope = crowdNames.enumerated().map { ArtistMapEntry(name: $0.element, plays: 1000 - $0.offset) }
        let crowdGraph = ArtistMapGraph.build(scope: crowdScope, libraryKeys: Set(crowdNames.map(key)), neighbors: crowd)
        let thinned = crowdGraph.filtered(minMatch: 0.4, showGhosts: false)
        let everything = crowdGraph.filtered(minMatch: 0.4, showGhosts: false, linksPerArtist: nil)
        var keepsOwnStrongest = true
        for node in crowdGraph.nodes.indices {
            let own = crowdGraph.edges.filter { $0.a == node || $0.b == node }.sorted { $0.weight != $1.weight ? $0.weight > $1.weight : ($0.a, $0.b) < ($1.a, $1.b) }.prefix(ArtistMapGraph.linksPerArtist)
            for edge in own where !thinned.edges.contains(where: { thinned.nodes[$0.a].key == crowdGraph.nodes[edge.a].key && thinned.nodes[$0.b].key == crowdGraph.nodes[edge.b].key }) { keepsOwnStrongest = false }
        }
        r.check("a crowded map keeps far fewer lines than all of them, and every artist still has its \(ArtistMapGraph.linksPerArtist) strongest", thinned.edges.count < everything.edges.count / 2 && keepsOwnStrongest && everything.edges.count == 30 * 29 / 2, "\(thinned.edges.count) of \(everything.edges.count)")
        let weakest = thinned.edges.map(\.weight).min() ?? 0
        let panelSafe = crowdGraph.nodes.indices.allSatisfy { node in
            let strongestSix = crowdGraph.edges.filter { $0.a == node || $0.b == node }.sorted { $0.weight > $1.weight }.prefix(6)
            return strongestSix.allSatisfy { e in thinned.edges.contains { thinned.nodes[$0.a].key == crowdGraph.nodes[e.a].key && thinned.nodes[$0.b].key == crowdGraph.nodes[e.b].key } }
        }
        r.check("the six closest links the panel lists are never thinned away", panelSafe && weakest > 0)
        // Dots of different sizes on a wide canvas: still clear of each other by their own radii, and the picture uses the width.
        let sizes = graph.nodes.indices.map { 6.0 + Double($0 % 5) * 3 }
        let wide = CGSize(width: 1000, height: 400)
        let wideLayout = ArtistMapLayout.force(graph: graph, canvas: wide, radii: sizes)
        var wideClear = true
        for i in wideLayout.indices {
            for j in (i + 1)..<wideLayout.count {
                let d = hypot(Double(wideLayout[i].x - wideLayout[j].x) * 1000, Double(wideLayout[i].y - wideLayout[j].y) * 400)
                if d < sizes[i] + sizes[j] + ArtistMapLayout.defaultGap - 0.01 { wideClear = false }
            }
        }
        let xs = wideLayout.map { Double($0.x) }, ys = wideLayout.map { Double($0.y) }
        let spreadX = (xs.max() ?? 0) - (xs.min() ?? 0), spreadY = (ys.max() ?? 0) - (ys.min() ?? 0)
        r.check("on a wide canvas each dot is clear of the next by its own size, and the map spreads across the width", wideClear && spreadX * 1000 > spreadY * 400, "spread \(spreadX * 1000) x \(spreadY * 400)")

        // The size the Top artists mode really draws: 60 artists with very different dot sizes, in a 700 x 450 drawing area.
        let sample = ArtistMapModel.sample(container: container, artists: 60, showGhosts: true)
        let sampleRadii = sample.shown.nodes.map { Double(sample.radius(of: $0)) }
        let drawing = CGSize(width: 700, height: 450)
        let sampleLayout = ArtistMapLayout.force(graph: sample.shown, canvas: drawing, radii: sampleRadii)
        var worstOverlap = 0.0
        for i in sampleLayout.indices {
            for j in (i + 1)..<sampleLayout.count {
                let d = hypot(Double(sampleLayout[i].x - sampleLayout[j].x) * 700, Double(sampleLayout[i].y - sampleLayout[j].y) * 450)
                worstOverlap = max(worstOverlap, sampleRadii[i] + sampleRadii[j] - d)
            }
        }
        r.check("on the real drawing area, with real dot sizes, no two dots overlap at all", worstOverlap <= 0, "worst overlap \(worstOverlap) pt across \(sample.shown.nodes.count) dots")
        var linked: [Double] = [], others: [Double] = []
        let linkedPairs = Set(graph.edges.filter { $0.weight >= 0.5 }.map { "\($0.a),\($0.b)" })
        for i in layout.indices {
            for j in (i + 1)..<layout.count {
                let d = distance(layout[i], layout[j])
                if linkedPairs.contains("\(i),\(j)") { linked.append(d) } else { others.append(d) }
            }
        }
        let linkedMean = linked.reduce(0, +) / Double(max(linked.count, 1)), otherMean = others.reduce(0, +) / Double(max(others.count, 1))
        r.check("artists that point at each other sit much closer than those that don't", linkedMean < otherMean * 0.6, "linked \(linkedMean) vs others \(otherMean)")

        var withoutBridge = answers
        withoutBridge[key("C0-1")] = (answers[key("C0-1")] ?? []).filter { $0.name != "C1-1" }
        let nudged = ArtistMapGraph.build(scope: scope, libraryKeys: libraryKeys, neighbors: withoutBridge)
        var previous: [String: CGPoint] = [:]
        for (i, node) in graph.nodes.enumerated() { previous[node.key] = layout[i] }
        let relaid = ArtistMapLayout.force(graph: nudged, previous: previous)
        var shift = 0.0
        for (i, node) in nudged.nodes.enumerated() { shift += distance(relaid[i], previous[node.key] ?? .zero) }
        let averageShift = shift / Double(nudged.nodes.count)
        r.check("changing one line moves the picture only a little (it starts from where the dots were)", averageShift < 0.08, "average move \(averageShift)")

        let single = ArtistMapGraph(nodes: [ArtistMapGraph.Node(key: "a", name: "A", plays: 1, isGhost: false)], edges: [])
        r.check("an empty map has no positions and a single artist sits in the middle", ArtistMapLayout.force(graph: ArtistMapGraph()).isEmpty && ArtistMapLayout.force(graph: single) == [CGPoint(x: 0.5, y: 0.5)])

        // 200 artists, each pointing at a few others: the size the Top artists mode can reach.
        var bigAnswers: [String: [SimilarArtist]] = [:]
        let bigScope = (0..<200).map { ArtistMapEntry(name: "Big \($0)", plays: 5000 - $0 * 10) }
        for i in 0..<200 {
            bigAnswers[key("Big \(i)")] = [1, 2, 7, 31].map { sim("Big \((i + $0 * 3) % 200)", 0.9 - Double($0) * 0.02) }
        }
        let bigGraph = ArtistMapGraph.build(scope: bigScope, libraryKeys: Set(bigScope.map { key($0.name) }), neighbors: bigAnswers)
        let startedAt = Date()
        let bigLayout = ArtistMapLayout.force(graph: bigGraph)
        let seconds = Date().timeIntervalSince(startedAt)
        var bigClosest = Double.infinity
        for i in bigLayout.indices { for j in (i + 1)..<bigLayout.count { bigClosest = min(bigClosest, points(bigLayout[i], bigLayout[j])) } }
        print("INFO  200 artists, \(bigGraph.edges.count) lines laid out in \(String(format: "%.2f", seconds)) s")
        let bigInside = bigLayout.allSatisfy { $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 }
        r.check("200 artists are laid out in under 3 seconds, inside the square, none on top of another", seconds < 3 && bigInside && bigClosest >= clearance - 0.01, "\(seconds) s, closest \(bigClosest)")
    }


    // MARK: Seed mode

    @MainActor
    private static func seedChecks(_ r: Report) {
        let ringNames = (1...30).map { "Ring \($0)" }, outerNames = (1...6).map { "Outer \($0)" }
        var library: [String: ArtistMapEntry] = [key("Seed"): ArtistMapEntry(name: "Seed", plays: 500)]
        for (i, name) in (ringNames + outerNames).enumerated() { library[key(name)] = ArtistMapEntry(name: name, plays: 300 - i) }
        var answers: [String: [SimilarArtist]] = [:]
        answers[key("Seed")] = ringNames.enumerated().map { sim($0.element, 0.9 - Double($0.offset) * 0.02) } + [sim("Never Played", 0.7), sim("Unknown Y", 0.6), sim("Seed", 0.99)]
        answers[key("Ring 1")] = [sim("Outer 1", 0.8), sim("Outer 2", 0.7), sim("Outer 3", 0.6), sim("Outer 4", 0.5), sim("The Ring 2", 0.9), sim("Seed", 0.8)]
        answers[key("Ring 2")] = [sim("Outer 1", 0.85), sim("Outer 5", 0.35), sim("Outer 6", 0.2)]

        let none = ArtistMapSeedScope.build(seed: "Seed", library: library, answers: [:], steps: 1)
        r.check("with no answer for the seed there is only the seed, and the seed is what to look up", none.scope.map(\.name) == ["Seed"] && none.lookups == ["Seed"], "\(none)")
        let one = ArtistMapSeedScope.build(seed: "Seed", library: library, answers: answers, steps: 1)
        let expectedRing = (1...ArtistMapSeedScope.ringCap).map { "Ring \($0)" }
        r.check("one step: the seed and its \(ArtistMapSeedScope.ringCap) closest artists you play, strongest first", one.scope.map(\.name) == ["Seed"] + expectedRing, "\(one.scope.count)")
        let neither = !one.scope.contains { $0.name == "Never Played" || $0.name == "Unknown Y" }
        r.check("an artist you haven't played is never in the scope (it can only be a dashed dot), and the seed isn't listed twice", neither && one.scope.filter { $0.name == "Seed" }.count == 1)
        let wanted = (3...ArtistMapSeedScope.ringCap).map { "Ring \($0)" }
        r.check("the neighbors without an answer are what to look up next (not the two that have one)", one.lookups == wanted, "\(one.lookups.count)")
        let two = ArtistMapSeedScope.build(seed: "Seed", library: library, answers: answers, steps: 2)
        let outer = two.scope.dropFirst(1 + ArtistMapSeedScope.ringCap).map(\.name)
        r.check("two steps: each neighbor adds its own closest three, ranked by match, once however many point at them", outer == ["Outer 1", "Outer 2", "Outer 3", "Outer 5"], "\(outer)")
        r.check("…and never an artist already in the ring, one below the floor, or past a neighbor's top three", !outer.contains("Outer 4") && !outer.contains("Outer 6") && !outer.contains("Ring 2"))
        r.check("looking up is still only for the seed and its neighbors, never the outer ring", two.lookups == one.lookups)
        let staleSeed = ArtistMapSeedScope.build(seed: "Seed", library: library, answers: answers, steps: 1, stale: [key("Seed"), key("Ring 1")])
        r.check("an out-of-date answer for the seed or a neighbor is looked up again, while the scope is still drawn from it", staleSeed.lookups.first == "Seed" && staleSeed.lookups.contains("Ring 1") && !staleSeed.lookups.contains("Ring 2") && staleSeed.scope == one.scope, "\(staleSeed.lookups.prefix(3))")
        let stranger = ArtistMapSeedScope.build(seed: "Not In Library", library: library, answers: [:], steps: 1)
        r.check("a seed that isn't in your library still gets a map, with no plays", stranger.scope.first?.plays == 0 && stranger.scope.first?.name == "Not In Library")

        // The seed's own links are never thinned away.
        let leaves = (1...12).map { "Leaf \($0)" }
        var starAnswers: [String: [SimilarArtist]] = [key("Hub"): leaves.map { sim($0, 0.35) }]
        for name in leaves { starAnswers[key(name)] = leaves.filter { $0 != name }.map { sim($0, 0.9) } }
        let starScope = ([ArtistMapEntry(name: "Hub", plays: 900)] + leaves.map { ArtistMapEntry(name: $0, plays: 100) })
        let star = ArtistMapGraph.build(scope: starScope, libraryKeys: Set(starScope.map { key($0.name) }), neighbors: starAnswers)
        let hub = star.index(ofKey: key("Hub")) ?? -1
        let thinnedLinks = star.filtered(minMatch: 0.3, showGhosts: false).edges.filter { star.nodes[$0.a].key == key("Hub") || star.nodes[$0.b].key == key("Hub") }.count
        let pinnedGraph = star.filtered(minMatch: 0.3, showGhosts: false, alwaysKeep: key("Hub"))
        let pinnedLinks = pinnedGraph.edges.filter { pinnedGraph.nodes[$0.a].key == key("Hub") || pinnedGraph.nodes[$0.b].key == key("Hub") }.count
        r.check("without pinning, a crowded neighbor list loses some of the seed's links; pinned, all \(leaves.count) stay", hub >= 0 && thinnedLinks < leaves.count && pinnedLinks == leaves.count, "\(thinnedLinks) vs \(pinnedLinks)")

        // The radial layout.
        let graph = ArtistMapGraph.build(scope: two.scope, libraryKeys: Set(library.keys), neighbors: answers).filtered(minMatch: 0.2, showGhosts: false, alwaysKeep: key("Seed"))
        let canvas = CGSize(width: 700, height: 450)
        let sizes = graph.nodes.indices.map { 6.0 + Double($0 % 4) * 3 }
        let radial = ArtistMapLayout.radial(graph: graph, seedKey: key("Seed"), canvas: canvas, radii: sizes)
        let seedAt = radial[graph.index(ofKey: key("Seed")) ?? 0]
        r.check("the seed sits in the middle", abs(seedAt.x - 0.5) < 0.02 && abs(seedAt.y - 0.5) < 0.02, "\(seedAt)")
        func away(_ index: Int) -> Double { hypot(Double(radial[index].x - seedAt.x) * 700, Double(radial[index].y - seedAt.y) * 450) }
        let ringIndexes = graph.nodes.indices.filter { i in graph.edges.contains { ($0.a == i && graph.nodes[$0.b].key == key("Seed")) || ($0.b == i && graph.nodes[$0.a].key == key("Seed")) } }
        let weightTo: (Int) -> Double = { i in graph.edges.first { ($0.a == i && graph.nodes[$0.b].key == key("Seed")) || ($0.b == i && graph.nodes[$0.a].key == key("Seed")) }?.weight ?? 0 }
        let byMatch = ringIndexes.sorted { weightTo($0) > weightTo($1) }
        let nearHalf = byMatch.prefix(byMatch.count / 2).map(away), farHalf = byMatch.suffix(byMatch.count / 2).map(away)
        let nearMean = nearHalf.reduce(0, +) / Double(max(nearHalf.count, 1)), farMean = farHalf.reduce(0, +) / Double(max(farHalf.count, 1))
        r.check("the stronger the match, the closer to the seed", nearMean < farMean, "near \(nearMean) far \(farMean)")
        let outerIndexes = graph.nodes.indices.filter { !ringIndexes.contains($0) && graph.nodes[$0].key != key("Seed") }
        let ringMedian = ringIndexes.map(away).sorted()[ringIndexes.count / 2]
        r.check("artists reached only through a neighbor sit beyond the ring", !outerIndexes.isEmpty && outerIndexes.allSatisfy { away($0) > ringMedian }, "\(outerIndexes.count) outer, ring median \(ringMedian)")
        var worst = 0.0
        for i in radial.indices { for j in (i + 1)..<radial.count {
            let d = hypot(Double(radial[i].x - radial[j].x) * 700, Double(radial[i].y - radial[j].y) * 450)
            worst = max(worst, sizes[i] + sizes[j] - d)
        } }
        let inside = radial.allSatisfy { $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 }
        r.check("no dots overlap and all stay inside the canvas, and the same map lays out the same way", worst <= 0 && inside && radial == ArtistMapLayout.radial(graph: graph, seedKey: key("Seed"), canvas: canvas, radii: sizes), "worst overlap \(worst)")
        let lost = ArtistMapLayout.radial(graph: graph, seedKey: key("Nobody"), canvas: canvas, radii: sizes)
        r.check("a seed that isn't on the map falls back to the ordinary layout instead of failing", lost.count == graph.nodes.count)
    }


    // MARK: Period, counts, artwork, unlinked artists

    @MainActor
    private static func refinementChecks(_ r: Report, _ container: ModelContainer) {
        // The same period list and default as Overview.
        let model = ArtistMapModel(container: container)
        let ids = model.rangeOptions.map(\.id)
        let overview = DateRangePresets.build(oldestScrobbleDate: nil).map(\.id)
        r.check("the period choices are Overview's, in the same order", ids == overview && ids.first == "alltime" && ids.contains("last30") && ids.contains("ytd"), "\(ids)")
        let from30 = model.selectedRange().from
        let near = from30.map { abs($0.timeIntervalSinceNow + 30 * 86_400) < 120 } ?? false
        r.check("the default period is Last 30 days, as on Overview", ArtistMapModel.Options().periodId == "last30" && near)
        model.options.periodId = "year-1990"
        let fellBack = model.selectedRange().from.map { abs($0.timeIntervalSinceNow + 30 * 86_400) < 120 } ?? false
        r.check("a saved period that no longer exists falls back to Last 30 days", fellBack)
        model.options.periodId = "alltime"
        r.check("All time starts at the beginning", (model.selectedRange().from ?? .now) < Date(timeIntervalSince1970: 86_400))
        r.check("the artist counts offered are 10, 25, 50, 100 and 200", ArtistMapModel.countChoices == [10, 25, 50, 100, 200])
        let old = Data(#"{"mode":"top","count":25,"period":"allTime","minMatchPercent":50,"showGhosts":true}"#.utf8)
        let decoded = try? JSONDecoder().decode(ArtistMapModel.Options.self, from: old)
        r.check("settings saved before the period change still open (period back to the default, the rest kept, artwork on)", decoded?.periodId == "last30" && decoded?.count == 25 && decoded?.minMatchPercent == 50 && decoded?.showGhosts == true && decoded?.showArtwork == true)
        var chosen = ArtistMapModel.Options()
        chosen.periodId = "year-2020"; chosen.showArtwork = false; chosen.mode = .seed; chosen.seedArtist = "Artist A"; chosen.reach = 2
        let round = (try? JSONEncoder().encode(chosen)).flatMap { try? JSONDecoder().decode(ArtistMapModel.Options.self, from: $0) }
        r.check("a chosen period, artwork setting and seed survive saving", round == chosen)

        // A map from a seed shows no artist that has no link on screen.
        let names = ["Near", "Medium", "Weak", "Weaker"]
        var answers: [String: [SimilarArtist]] = [key("Seed"): [sim("Near", 0.8), sim("Medium", 0.5), sim("Weak", 0.35), sim("Weaker", 0.2)]]
        answers[key("Near")] = [sim("Seed", 0.7)]
        let scope = ([ArtistMapEntry(name: "Seed", plays: 100)] + names.map { ArtistMapEntry(name: $0, plays: 50) })
        let graph = ArtistMapGraph.build(scope: scope, libraryKeys: Set(scope.map { key($0.name) }), neighbors: answers)
        let kept = graph.filtered(minMatch: 0.4, showGhosts: false, alwaysKeep: key("Seed"), dropUnlinked: true).nodes.map(\.name)
        r.check("from a seed, artists linked only below the minimum match are left off, not shown alone", Set(kept) == ["Seed", "Near", "Medium"], "\(kept)")
        let topMode = graph.filtered(minMatch: 0.4, showGhosts: false).nodes.map(\.name)
        r.check("in the Top artists map every artist stays, linked or not", Set(topMode) == Set(["Seed"] + names), "\(topMode)")
        let lonely = graph.filtered(minMatch: 0.95, showGhosts: false, alwaysKeep: key("Seed"), dropUnlinked: true).nodes.map(\.name)
        r.check("the seed stays even when nothing is linked to it", lonely == ["Seed"], "\(lonely)")
        var ghostAnswers = answers
        ghostAnswers[key("Weak")] = [sim("Ghost Only", 0.9)]
        let withGhost = ArtistMapGraph.build(scope: scope, libraryKeys: Set(scope.map { key($0.name) }), neighbors: ghostAnswers)
        let hiddenGhost = withGhost.filtered(minMatch: 0.3, showGhosts: false, alwaysKeep: key("Seed"), dropUnlinked: true).nodes.map(\.name)
        let shownGhost = withGhost.filtered(minMatch: 0.3, showGhosts: true, alwaysKeep: key("Seed"), dropUnlinked: true).nodes.map(\.name)
        r.check("an artist linked only to a never-played dot is left off while those are hidden, and kept once they are shown", hiddenGhost.contains("Weak") && shownGhost.contains("Ghost Only"), "\(hiddenGhost) \(shownGhost)")

        // Artwork thumbnails.
        let wide = NSImage(size: NSSize(width: 200, height: 100))
        wide.lockFocus()
        NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 100, height: 100).fill()
        NSColor.blue.setFill(); NSRect(x: 100, y: 0, width: 100, height: 100).fill()
        wide.unlockFocus()
        let thumb = ArtistMapArtwork.thumbnail(wide, side: 96)
        r.check("a picture is cut to a square of the asked size", thumb.size == NSSize(width: 96, height: 96), "\(thumb.size)")
        let empty = ArtistMapArtwork.thumbnail(NSImage(size: .zero))
        r.check("a picture with no size is handed back rather than failing", empty.size == .zero)
    }

    // MARK: Lookups

    @MainActor
    private static func lookupChecks(_ r: Report) async {
        let neverOffline: @Sendable () -> Bool = { false }
        let savedList = [sim("Artist B", 0.8)]
        let four = ["Artist A", "Artist B", "Artist C", "Artist D"]

        let provider = StubProvider(saved: ["Artist A": savedList, "Artist B": savedList], answers: ["Artist C": [sim("Artist A", 0.5)], "Artist D": []])
        let savedOnly = await ArtistMapLoader.load(artists: four, provider: provider, fetchMissing: false, isOffline: neverOffline, onUpdate: { _ in })
        let expected = ArtistMapLoader.Summary(fromSaved: 2, fetched: 0, missing: 2, failed: 0, stopped: nil)
        r.check("saved answers load with no lookups, and the artists still without one are counted", savedOnly.summary == expected && provider.calls.with { $0.isEmpty } && savedOnly.neighbors.count == 2, "\(savedOnly.summary)")
        let full = await ArtistMapLoader.load(artists: four + ["artist c"], provider: provider, fetchMissing: true, isOffline: neverOffline, onUpdate: { _ in })
        let fetchedCalls = provider.calls.with { $0 }
        r.check("the missing ones are fetched, once each, even if named twice", full.summary.fetched == 2 && full.summary.missing == 0 && fetchedCalls.sorted() == ["Artist C", "Artist D"], "\(full.summary) \(fetchedCalls)")
        r.check("a genuinely empty answer is kept as an answer, not as a gap", full.neighbors[key("Artist D")]?.isEmpty == true && full.neighbors.count == 4)

        let progressProvider = StubProvider(saved: ["Artist A": savedList], answers: ["Artist B": savedList])
        let seen = Box<[Int]>([])
        let progressed = await ArtistMapLoader.load(artists: ["Artist A", "Artist B"], provider: progressProvider, fetchMissing: true, isOffline: neverOffline, onUpdate: { update in seen.with { $0.append(update.done) } })
        r.check("progress counts up from the saved answers through the fetched ones", seen.with { $0 } == [1, 2] && progressed.summary.fetched == 1, "\(seen.with { $0 })")

        let offlineProvider = StubProvider(saved: ["Artist A": savedList], answers: ["Artist B": savedList, "Artist C": savedList])
        let offline = await ArtistMapLoader.load(artists: ["Artist A", "Artist B", "Artist C"], provider: offlineProvider, fetchMissing: true, isOffline: { true }, onUpdate: { _ in })
        let noCalls = offlineProvider.calls.with { $0.isEmpty }
        r.check("in Offline mode nothing is fetched and the rest are reported as missing", noCalls && offline.summary.stopped == .offline && offline.summary.missing == 2 && offline.summary.fromSaved == 1, "\(offline.summary)")
        let nothingSaved = offlineProvider.saved.with { $0["Artist B"] == nil && $0["Artist C"] == nil }
        r.check("…and nothing is saved for them, so a later online run asks", nothingSaved)

        let failingProvider = StubProvider(answers: ["Artist D": savedList], failing: ["Artist C"])
        let failed = await ArtistMapLoader.load(artists: ["Artist C", "Artist D"], provider: failingProvider, fetchMissing: true, isOffline: neverOffline, onUpdate: { _ in })
        let gapOnly = failed.neighbors[key("Artist C")] == nil && failed.neighbors[key("Artist D")] != nil
        r.check("a failed lookup is a gap, never an empty answer, and the others carry on", gapOnly && failed.summary.failed == 1 && failed.summary.fetched == 1 && failed.summary.missing == 1, "\(failed.summary)")
        r.check("…and it isn't saved", failingProvider.saved.with { $0["Artist C"] == nil })

        let down = (1...9).map { "Down \($0)" }
        let downProvider = StubProvider(failing: Set(down))
        let stopped = await ArtistMapLoader.load(artists: down, provider: downProvider, fetchMissing: true, isOffline: neverOffline, onUpdate: { _ in })
        let attempts = downProvider.calls.with { $0.count }
        let inFlightAtStop = ArtistMapLoader.failureLimit + ArtistMapLoader.concurrency - 1
        r.check("after \(ArtistMapLoader.failureLimit) failures in a row no new lookups start (only those already under way finish)", stopped.summary.stopped == .tooManyFailures && attempts >= ArtistMapLoader.failureLimit && attempts <= inFlightAtStop && stopped.summary.missing == 9, "\(stopped.summary) \(attempts)")


        let peak = Box<(now: Int, max: Int)>((0, 0))
        final class OverlapProvider: ArtistMapNeighborProviding, @unchecked Sendable {
            let peak: Box<(now: Int, max: Int)>
            init(_ peak: Box<(now: Int, max: Int)>) { self.peak = peak }
            func savedNeighbors(of artist: String) async -> [SimilarArtist]? { nil }
            func fetchNeighbors(of artist: String) async throws -> [SimilarArtist] {
                peak.with { $0.now += 1; $0.max = max($0.max, $0.now) }
                try await Task.sleep(nanoseconds: 20_000_000)
                peak.with { $0.now -= 1 }
                return []
            }
        }
        let many = (1...16).map { "Overlap \($0)" }
        let overlapped = await ArtistMapLoader.load(artists: many, provider: OverlapProvider(peak), fetchMissing: true, isOffline: neverOffline, onUpdate: { _ in })
        let highest = peak.with { $0.max }
        r.check("lookups overlap, a few at a time and never more than \(ArtistMapLoader.concurrency)", highest > 1 && highest <= ArtistMapLoader.concurrency && overlapped.summary.fetched == 16, "peak \(highest)")


        // Out-of-date answers still draw the map and are asked for again.
        let oldList = [sim("Old Neighbor", 0.7)], newList = [sim("New Neighbor", 0.8)]
        let staleProvider = StubProvider(stale: ["Artist A": oldList], answers: ["Artist A": newList])
        let staleRead = await ArtistMapLoader.load(artists: ["Artist A"], provider: staleProvider, fetchMissing: false, isOffline: neverOffline, onUpdate: { _ in })
        let noCallsYet = staleProvider.calls.with { $0.isEmpty }
        r.check("an out-of-date answer is used for the map and counted as waiting for a refresh, with no lookup made", staleRead.neighbors[key("Artist A")]?.first?.name == "Old Neighbor" && staleRead.summary.staleKeys == [key("Artist A")] && staleRead.summary.missing == 1 && noCallsYet, "\(staleRead.summary)")
        let refreshed = await ArtistMapLoader.load(artists: ["Artist A"], provider: staleProvider, fetchMissing: true, isOffline: neverOffline, onUpdate: { _ in })
        r.check("refreshing replaces it with the new answer and it is no longer stale", refreshed.neighbors[key("Artist A")]?.first?.name == "New Neighbor" && refreshed.summary.staleKeys.isEmpty && refreshed.summary.fetched == 1 && refreshed.summary.missing == 0, "\(refreshed.summary)")
        let staleOffline = StubProvider(stale: ["Artist A": oldList], answers: ["Artist A": newList])
        let offlineRead = await ArtistMapLoader.load(artists: ["Artist A"], provider: staleOffline, fetchMissing: true, isOffline: { true }, onUpdate: { _ in })
        let untouched = staleOffline.calls.with { $0.isEmpty }
        r.check("offline, an old answer keeps drawing and nothing is asked", offlineRead.neighbors[key("Artist A")]?.first?.name == "Old Neighbor" && untouched && offlineRead.summary.stopped == .offline && offlineRead.summary.staleKeys.count == 1)
        let staleFailing = StubProvider(stale: ["Artist A": oldList], answers: [:], failing: ["Artist A"])
        let failedRefresh = await ArtistMapLoader.load(artists: ["Artist A"], provider: staleFailing, fetchMissing: true, isOffline: neverOffline, onUpdate: { _ in })
        r.check("a refresh that fails keeps the old answer rather than losing the links", failedRefresh.neighbors[key("Artist A")]?.first?.name == "Old Neighbor" && failedRefresh.summary.failed == 1 && failedRefresh.summary.staleKeys.count == 1)
        let freshAndStale = StubProvider(saved: ["Artist B": newList], stale: ["Artist A": oldList])
        let both = await ArtistMapLoader.load(artists: ["Artist A", "Artist B"], provider: freshAndStale, fetchMissing: false, isOffline: neverOffline, onUpdate: { _ in })
        r.check("a current answer is not marked stale", both.summary.staleKeys == [key("Artist A")] && both.summary.fromSaved == 1 && both.neighbors.count == 2)

        let slow = (1...20).map { "Slow \($0)" }
        let slowAnswers = Dictionary(uniqueKeysWithValues: slow.map { ($0, savedList) })
        let slowProvider = StubProvider(answers: slowAnswers, delay: 60_000_000)
        let task = Task { await ArtistMapLoader.load(artists: slow, provider: slowProvider, fetchMissing: true, isOffline: neverOffline, onUpdate: { _ in }) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        let cancelled = await task.value
        let keptSome = cancelled.summary.fetched > 0 && cancelled.summary.fetched < 20 && cancelled.neighbors.count == cancelled.summary.fetched
        r.check("stopping the lookups keeps what has arrived", cancelled.summary.stopped == .cancelled && keptSome, "\(cancelled.summary)")
    }

    // MARK: The local answer cache

    @MainActor
    private static func cacheChecks(_ r: Report, _ container: ModelContainer) async {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_STORE_PATH"] != nil else {
            print("SKIP  the answer cache checks need SCROBLYTICS_STORE_PATH on a scratch store")
            return
        }
        let store = SimilarityCacheStore(modelContainer: container)
        let client = LastfmAPIClient(apiKey: "0123456789abcdef0123456789abcdef", username: "nobody")
        let provider = LastfmSimilarityProvider(client: client, store: store)
        let list = (0..<100).map { sim("Neighbor \($0)", 1 - Double($0) / 100) }
        await provider.saveNeighbors(list, of: "Artist Cache")
        let back = await provider.savedNeighbors(of: "Artist Cache") ?? []
        let sameAsSaved = back.count == 100 && zip(back, list).allSatisfy { $0.name == $1.name && $0.match == $1.match }
        r.check("100 neighbors are saved and read back in order, with their scores", sameAsSaved)
        let upperCase = await provider.savedNeighbors(of: "ARTIST CACHE")
        r.check("the answer is found whatever the case of the name", upperCase != nil)
        let nobody = await provider.savedNeighbors(of: "Artist Nobody")
        r.check("an artist with no saved answer has none", nobody == nil)
        let rabbitHoleKey = "artist\u{1F}artist cache"
        let rabbitHole = await store.read(rabbitHoleKey, maxAge: LastfmSimilarityProvider.maxAge)
        r.check("Rabbit Hole's own answers are separate and untouched", rabbitHole == nil && LastfmSimilarityProvider.mapCacheKey("Artist Cache") != rabbitHoleKey)
        let stale = Data("[{\"name\":\"X\",\"match\":0.5}]".utf8)
        await store.write(LastfmSimilarityProvider.mapCacheKey("Artist Old"), payload: stale, now: Date().addingTimeInterval(-40 * 86_400))
        let old = await provider.savedNeighbors(of: "Artist Old")
        r.check("an answer older than 30 days is not used", old == nil)
        let oldStale = await provider.staleNeighbors(of: "Artist Old")
        r.check("…but it is still there to draw from, as an out-of-date answer", oldStale?.first?.name == "X")
        let freshStale = await provider.staleNeighbors(of: "Artist Cache")
        let neverStale = await provider.staleNeighbors(of: "Artist Nobody")
        r.check("a current answer, or none at all, is not an out-of-date one", freshStale == nil && neverStale == nil)
    }
}

/// `SCROBLYTICS_ARTISTMAP_DUMP=1` (with `SCROBLYTICS_STORE_PATH` on a copy of a library, Offline): builds the map from the similarity
/// answers already saved on that copy (Rabbit Hole's 30-neighbor lookups stand in for the map's own) and prints every line of it, so an
/// independent reading of the same saved answers can be compared edge by edge. Reads only; asks Last.fm nothing.
enum ArtistMapDump {
    private struct Saved: Codable { let name: String; let match: Double }

    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_ARTISTMAP_DUMP"] != nil else { return }
        Task { @MainActor in
            do {
                let snapshots = try await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)
                let everyone = ArtistMapScope.top(snapshots: snapshots, count: Int.max)
                let plays = Dictionary(uniqueKeysWithValues: everyone.entries.map { (ArtistMapNames.key($0.name), $0) })
                let entries = try container.mainContext.fetch(FetchDescriptor<SimilarityLookupCacheEntry>())
                var answers: [String: [SimilarArtist]] = [:]
                var scope: [ArtistMapEntry] = []
                for entry in entries where entry.cacheKey.hasPrefix("artist\u{1F}") {
                    let name = String(entry.cacheKey.dropFirst("artist\u{1F}".count))
                    let key = ArtistMapNames.key(name)
                    guard let known = plays[key], let saved = try? JSONDecoder().decode([Saved].self, from: entry.payload) else { continue }
                    answers[key] = saved.map { SimilarArtist(name: $0.name, match: $0.match) }
                    scope.append(known)
                }
                let graph = ArtistMapGraph.build(scope: scope, libraryKeys: everyone.libraryKeys, neighbors: answers)
                print("MAP nodes=\(graph.nodes.filter { !$0.isGhost }.count) ghosts=\(graph.nodes.filter(\.isGhost).count) edges=\(graph.edges.count)")
                for edge in graph.edges {
                    let a = graph.nodes[edge.a], b = graph.nodes[edge.b]
                    print("EDGE\t\(a.key)\t\(b.key)\t\(edge.aToB)\t\(edge.bToA)\t\(b.isGhost ? "ghost" : "artist")")
                }
                let groups = ArtistMapGroups.find(in: graph.filtered(minMatch: 0.4, showGhosts: false))
                print("GROUPS \(groups.names) \(groups.sizes)")
                exit(0)
            } catch {
                print("DUMP FAILED \(error)")
                exit(1)
            }
        }
    }
}

/// `SCROBLYTICS_LAYOUT_SNAPSHOT_ARTISTMAP=<folder>`: the Artist Map screen on made-up data, dark and light, wide and narrow, with the
/// never-played dots on and off and at 200 artists, so the layout can be looked at without driving the app.
enum ArtistMapSnapshots {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        guard let folder = ProcessInfo.processInfo.environment["SCROBLYTICS_LAYOUT_SNAPSHOT_ARTISTMAP"] else { return }
        Task { @MainActor in
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            // The drawing area (points) each window width gives the map, as measured from the first renders.
            let wideArea = CGSize(width: 735, height: 449), narrowArea = CGSize(width: 393, height: 447)
            let variants: [(name: String, artists: Int, ghosts: Bool, scheme: String, width: CGFloat, area: CGSize)] = [
                ("dark-wide", 60, true, "dark", 1100, wideArea), ("light-wide", 60, true, "light", 1100, wideArea),
                ("dark-narrow", 60, false, "dark", 760, narrowArea), ("light-large", 200, false, "light", 1100, wideArea),
                ("seed-one-light", 90, true, "light", 1100, wideArea), ("seed-two-dark", 90, true, "dark", 1100, wideArea),
                ("seed-two-narrow", 90, false, "light", 760, narrowArea),
                ("waiting-light", 60, false, "light", 1100, wideArea), ("refresh-dark", 60, false, "dark", 1100, wideArea),
                ("tall-light", 100, true, "light", 1700, CGSize(width: 1300, height: 900)),
            ]
            for variant in variants {
                let model = variant.name.hasPrefix("seed")
                    ? ArtistMapModel.sampleSeed(container: container, steps: variant.name.contains("two") ? 2 : 1, showGhosts: variant.ghosts, canvas: variant.area)
                    : ArtistMapModel.sample(container: container, artists: variant.artists, showGhosts: variant.ghosts, canvas: variant.area)
                let view = NavigationStack {
                    ArtistMapView(modelContainer: container, navigation: DetailNavigationCoordinator(origin: .tools), openQuery: { _, _, _ in }, sample: model)
                }
                .environment(LovedTracksStore())
                .environment(FlaggedTracksStore())
                .environment(PopularityStore())
                .environment(TagStore())
                .environment(LibraryGapBadgeStore())
                .modelContainer(container)
                .environment(\.colorScheme, variant.scheme == "dark" ? .dark : .light)
                if variant.name.hasPrefix("waiting") { model.installSampleWaiting(count: 14, stale: false) }
                if variant.name.hasPrefix("refresh") { model.installSampleWaiting(count: 14, stale: true) }
                let height: CGFloat = variant.name.hasPrefix("tall") ? 1500 : 900
                let host = NSHostingView(rootView: view.frame(width: variant.width, height: height))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: variant.width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: variant.scheme == "dark" ? .darkAqua : .aqua)
                window.contentView = host
                window.setContentSize(NSSize(width: variant.width, height: height))
                for _ in 0..<8 { try? await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded() }
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appending(path: "artistmap-\(variant.name).png"))
                }
            }
            exit(0)
        }
    }
}
#endif
