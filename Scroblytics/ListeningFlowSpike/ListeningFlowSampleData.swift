import Foundation

/// Synthetic listening-session data for spiking the Canvas rendering approach
/// before the real sync layer/API exist. Deterministic (fixed seed) so runs
/// are comparable.
enum ListeningFlowSampleData {
    private struct RNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    static func generate(artistCount: Int, includeCompare: Bool) -> FlowData {
        var rng = RNG(state: 42)
        let pool = [
            "Radiohead", "Boards of Canada", "Aphex Twin", "Sufjan Stevens", "The National",
            "Bon Iver", "Fleet Foxes", "Grizzly Bear", "Beach House", "Tame Impala",
            "Four Tet", "Burial", "Jamie xx", "Caribou", "Floating Points",
            "Kendrick Lamar", "Frank Ocean", "Tyler, the Creator", "Vince Staples", "Earl Sweatshirt",
            "Fiona Apple", "PJ Harvey", "Cat Power", "Angel Olsen", "Big Thief",
            "LCD Soundsystem", "Talking Heads", "Arcade Fire", "Broken Social Scene", "Spoon",
            "Kamasi Washington", "Robert Glasper", "Thundercat", "Flying Lotus", "Moses Sumney",
        ]
        let names = Array(pool.prefix(min(artistCount, pool.count)))
        let clusterCount = max(1, names.count / 6)

        let nodes: [FlowNode] = names.enumerated().map { i, name in
            let plays = Int.random(in: 8...400, using: &rng)
            let cluster = i % clusterCount
            let outDegree = Int.random(in: 0...4, using: &rng)
            let inDegree = Int.random(in: 0...4, using: &rng)
            let role: FlowNodeRole? = i == 0 ? .starter : (i == names.count - 1 ? .ender : nil)
            return FlowNode(
                id: name,
                plays: plays,
                cluster: cluster,
                inDegree: inDegree,
                outDegree: outDegree,
                inWeight: inDegree * Int.random(in: 1...6, using: &rng),
                outWeight: outDegree * Int.random(in: 1...6, using: &rng),
                role: role
            )
        }

        var edges: [FlowEdge] = []
        for i in names.indices {
            let edgeCount = Int.random(in: 1...3, using: &rng)
            for _ in 0..<edgeCount {
                var j = Int.random(in: 0..<names.count, using: &rng)
                if j == i { j = (j + 1) % names.count }
                let count = Int.random(in: 1...60, using: &rng)
                var status: FlowEdgeStatus = .normal
                if includeCompare {
                    let roll = Int.random(in: 0...9, using: &rng)
                    status = roll < 2 ? .new : (roll < 4 ? .dropped : .normal)
                }
                edges.append(FlowEdge(source: names[i], target: names[j], count: count, status: status))
            }
        }

        return FlowData(
            nodes: nodes,
            edges: edges,
            enoughData: true,
            sessionCount: Int.random(in: 200...900, using: &rng),
            totalTransitions: edges.reduce(0) { $0 + $1.count },
            compare: includeCompare
        )
    }
}
