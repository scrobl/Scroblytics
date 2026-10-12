import Foundation

struct RabbitHoleTrack: Codable, Hashable, Identifiable, Sendable {
    let artist: String
    let track: String
    let album: String?
    let imageURL: String?
    let playCount: Int
    let lastPlayed: Date?
    let matchScore: Int
    let source: String
    /// Why it is offered, for the "why this track?" lines. Absent in paths saved before they existed.
    var reasons: [RabbitHoleReason]? = nil

    var id: String {
        TextNormalization.lovedKey(artist: artist, track: track)
    }
}

struct RabbitHoleNode: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let track: RabbitHoleTrack
    let parentID: UUID?
    var candidates: [RabbitHoleTrack]?
    var childIDs: [UUID]
}

struct RabbitHoleTree: Codable, Equatable, Sendable {
    var rootID: UUID?
    var nodes: [UUID: RabbitHoleNode]
    var currentID: UUID?

    static let empty = RabbitHoleTree(rootID: nil, nodes: [:], currentID: nil)

    func path(to nodeID: UUID? = nil) -> [RabbitHoleNode] {
        var result: [RabbitHoleNode] = []
        var cursor = nodeID ?? currentID
        while let id = cursor, let node = nodes[id] {
            result.append(node)
            cursor = node.parentID
        }
        return result.reversed()
    }
}

struct RabbitHoleGeneration: Sendable {
    let candidates: [RabbitHoleTrack]
    /// How many tracks could be offered before the conditions were applied (path tracks already left out).
    let totalBeforeConditions: Int
    /// How many were still allowed after the conditions and the per-artist/album limits' own reach: the pool the three were drawn from.
    let poolSize: Int
}

@MainActor
enum RabbitHoleEngine {
    static let candidatesPerStep = 3
    /// The step's own track counts fully; the two before it count for less.
    static let seedWeights: [Double] = [1, 0.5, 0.25]

    static func generate(
        from seed: RabbitHoleTrack,
        path: [RabbitHoleNode],
        groups: [[QueryCondition]],
        perArtist: Int,
        perAlbum: Int,
        knobs: RabbitHoleKnobs = RabbitHoleKnobs(),
        memory: RabbitHoleMemory = RabbitHoleMemory(),
        library: RabbitHoleLibrary,
        scrobbles: [ScrobbleSnapshot],
        snapshots: QuerySnapshots,
        provider: any RabbitHoleSimilarityProviding
    ) async throws -> RabbitHoleGeneration {
        var rng = SystemRandomNumberGenerator()
        return try await generate(
            from: seed, path: path, groups: groups, perArtist: perArtist, perAlbum: perAlbum, knobs: knobs, memory: memory,
            library: library, scrobbles: scrobbles, snapshots: snapshots, provider: provider, now: Date(), using: &rng
        )
    }

    static func generate(
        from seed: RabbitHoleTrack,
        path: [RabbitHoleNode],
        groups: [[QueryCondition]],
        perArtist: Int,
        perAlbum: Int,
        knobs: RabbitHoleKnobs,
        memory: RabbitHoleMemory,
        library: RabbitHoleLibrary,
        scrobbles: [ScrobbleSnapshot],
        snapshots: QuerySnapshots,
        provider: any RabbitHoleSimilarityProviding,
        now: Date,
        using rng: inout some RandomNumberGenerator
    ) async throws -> RabbitHoleGeneration {
        // The step's track first, then the ones before it on this path.
        var seedTracks = [seed]
        seedTracks += path.reversed().map(\.track).filter { $0.id != seed.id }
        let seeds = zip(seedTracks, seedWeights).map {
            RabbitHoleCandidates.Seed(artist: $0.artist, track: $0.track, weight: $1)
        }
        let pathIndexes = Set(path.compactMap { library.index(artist: $0.track.artist, track: $0.track.track) })
        let pathKeys = Set(path.map(\.track.id))

        let scored = try await RabbitHoleCandidates.build(
            seeds: seeds, excluding: pathIndexes, library: library, tags: snapshots.entityTags, bpm: snapshots.bpm,
            lovedKeys: snapshots.lovedKeys, provider: provider, now: now
        ).filter { !pathKeys.contains(library.tracks[$0.trackIndex].key) }

        // The person's own conditions, evaluated by the same query engine as everywhere else.
        let recommended = scored.map { candidate -> RecommendedCandidate in
            let track = library.tracks[candidate.trackIndex]
            let labels = candidate.reasons.map { Self.label(for: $0.kind) }
            return RecommendedCandidate(
                track: track.name, artist: track.artist, album: track.album, totalPlaycount: track.plays, lastPlayed: track.lastPlayed,
                matchScore: Int(candidate.score.rounded()), sources: labels.isEmpty ? [candidate.topSource] : labels, topSource: candidate.topSource,
                imageURL: track.imageURL
            )
        }
        let pool = SimilarSoundsTool.pool(candidates: recommended, seedResults: [])
        let evaluated = try SimilarSoundsTool.evaluate(
            pool: pool, groups: groups, columns: SimilarSoundsTool.defaultColumns, scrobbles: scrobbles, snapshots: snapshots,
            arrangement: SimilarSoundsArrangement(sort: .shuffled, shuffleSeed: 1, songLimit: nil, perArtist: nil, perAlbum: nil)
        )
        let allowed = Set(evaluated.rows.map(\.id))

        var items: [RabbitHoleSelector.Item] = []
        var byKey: [String: RabbitHoleScoredCandidate] = [:]
        for candidate in scored {
            let track = library.tracks[candidate.trackIndex]
            guard allowed.contains(QueryEntityID(target: .track, artist: track.artist, name: track.name)) else { continue }
            items.append(RabbitHoleSelector.Item(
                key: track.key, artistKey: normalized(track.artist), albumKey: albumKey(artist: track.artist, album: track.album),
                topTag: snapshots.entityTags.tags(forArtist: track.artist)?.first?.lowercased(),
                score: candidate.score, plays: track.plays, lastPlayed: track.lastPlayed, loved: snapshots.lovedKeys.contains(track.key)
            ))
            byKey[track.key] = candidate
        }

        let pathArtistCounts = Dictionary(grouping: path, by: { normalized($0.track.artist) }).mapValues(\.count)
        let pathAlbumCounts = Dictionary(grouping: path, by: { albumKey(artist: $0.track.artist, album: $0.track.album) }).mapValues(\.count)
        let picked = RabbitHoleSelector.pick(
            items, count: candidatesPerStep, knobs: knobs, memory: memory, pathArtistCounts: pathArtistCounts,
            pathAlbumCounts: pathAlbumCounts, perArtist: perArtist, perAlbum: perAlbum, now: now, using: &rng
        )

        let candidates: [RabbitHoleTrack] = picked.compactMap { item in
            guard let candidate = byKey[item.key] else { return nil }
            let track = library.tracks[candidate.trackIndex]
            return RabbitHoleTrack(
                artist: track.artist, track: track.name, album: track.album, imageURL: track.imageURL, playCount: track.plays,
                lastPlayed: track.lastPlayed, matchScore: Int(candidate.score.rounded()), source: candidate.topSource,
                reasons: Self.topReasons(candidate.reasons)
            )
        }
        return RabbitHoleGeneration(candidates: candidates, totalBeforeConditions: scored.count, poolSize: items.count)
    }

    /// The reasons worth showing, most telling first, at most three.
    static func topReasons(_ reasons: [RabbitHoleReason]) -> [RabbitHoleReason] {
        let order: [RabbitHoleReason.Kind] = [.playedNext, .similar, .viaStep, .similarArtist, .sharedTags, .forgotten, .loved, .tempo]
        let ranked = reasons.sorted { (order.firstIndex(of: $0.kind) ?? 99) < (order.firstIndex(of: $1.kind) ?? 99) }
        return Array(ranked.prefix(3))
    }

    private static func label(for kind: RabbitHoleReason.Kind) -> String {
        switch kind {
        case .similar: "Last.fm similar"
        case .similarArtist: "Similar artist"
        case .viaStep: "Two steps away"
        case .sharedTags: "Shared tags"
        case .playedNext: "You play it next"
        case .tempo: "Close tempo"
        case .loved: "Loved"
        case .forgotten: "Forgotten favourite"
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func albumKey(artist: String, album: String?) -> String {
        "\(normalized(artist))\u{0}\(normalized(album ?? ""))"
    }
}

struct RabbitHoleTreeLayout {
    struct Node: Identifiable {
        let id: UUID
        let node: RabbitHoleNode
        let origin: CGPoint
        let isOnPath: Bool
    }

    struct Candidate: Identifiable {
        let id: String
        let parentID: UUID
        let track: RabbitHoleTrack
        let origin: CGPoint
    }

    struct Edge: Identifiable {
        let id: String
        let start: CGPoint
        let end: CGPoint
        let isSuggestion: Bool
    }

    let nodes: [Node]
    let candidates: [Candidate]
    let edges: [Edge]
    let size: CGSize

    static let cardSize = CGSize(width: 300, height: 100)
    private static let horizontalGap: CGFloat = 28
    private static let verticalGap: CGFloat = 42
    private static let padding: CGFloat = 18

    static func make(tree: RabbitHoleTree, compact: Bool = false) -> RabbitHoleTreeLayout {
        guard let rootID = tree.rootID, let root = tree.nodes[rootID] else {
            return RabbitHoleTreeLayout(nodes: [], candidates: [], edges: [], size: .zero)
        }
        let path = tree.path()
        guard !path.isEmpty else {
            return RabbitHoleTreeLayout(nodes: [], candidates: [], edges: [], size: .zero)
        }
        if compact {
            return compactLayout(tree: tree, path: path)
        }
        let pathIDs = Set(path.map(\.id))
        let rows = path.map { units(tree: tree, node: $0) }
        let maxColumns = max(1, rows.map(\.count).max() ?? 1)
        let contentWidth = CGFloat(maxColumns) * cardSize.width
            + CGFloat(maxColumns - 1) * horizontalGap
        let width = contentWidth + padding * 2
        let rootX = padding + (contentWidth - cardSize.width) / 2
        var placedNodes = [Node(
            id: root.id,
            node: root,
            origin: CGPoint(x: rootX, y: padding),
            isOnPath: true
        )]
        var placedCandidates: [Candidate] = []
        var edges: [Edge] = []
        var origins: [UUID: CGPoint] = [root.id: CGPoint(x: rootX, y: padding)]
        var maxDepth = 0

        for (pathIndex, parent) in path.enumerated() {
            let units = rows[pathIndex]
            guard !units.isEmpty, let parentOrigin = origins[parent.id] else { continue }
            let depth = pathIndex + 1
            maxDepth = max(maxDepth, depth)
            let y = padding + CGFloat(depth) * (cardSize.height + verticalGap)

            for (column, unit) in units.enumerated() {
                let origin = CGPoint(
                    x: padding + CGFloat(column) * (cardSize.width + horizontalGap),
                    y: y
                )
                switch unit {
                case .node(let child):
                    origins[child.id] = origin
                    let onPath = pathIDs.contains(child.id)
                    placedNodes.append(Node(id: child.id, node: child, origin: origin, isOnPath: onPath))
                    if onPath {
                        edges.append(edge(
                            id: "\(parent.id)-\(child.id)",
                            from: parentOrigin,
                            to: origin,
                            suggestion: false
                        ))
                    }
                case .candidate(let track, let index):
                    let id = "\(parent.id)-candidate-\(index)"
                    placedCandidates.append(Candidate(id: id, parentID: parent.id, track: track, origin: origin))
                    if parent.id == tree.currentID {
                        edges.append(edge(id: id, from: parentOrigin, to: origin, suggestion: true))
                    }
                }
            }
        }

        let height = padding * 2 + CGFloat(maxDepth + 1) * cardSize.height
            + CGFloat(maxDepth) * verticalGap
        return RabbitHoleTreeLayout(
            nodes: placedNodes,
            candidates: placedCandidates,
            edges: edges,
            size: CGSize(width: width, height: height)
        )
    }

    /// Compact-width presentation: preserve the active path as one centered column,
    /// omit earlier unchosen songs, and stack only the current step's choices below it.
    private static func compactLayout(
        tree: RabbitHoleTree,
        path: [RabbitHoleNode]
    ) -> RabbitHoleTreeLayout {
        let x = padding
        var nodes: [Node] = []
        var candidates: [Candidate] = []
        var edges: [Edge] = []

        for (index, node) in path.enumerated() {
            let origin = CGPoint(
                x: x,
                y: padding + CGFloat(index) * (cardSize.height + verticalGap)
            )
            nodes.append(Node(id: node.id, node: node, origin: origin, isOnPath: true))
            if index > 0 {
                let parentOrigin = nodes[index - 1].origin
                edges.append(edge(
                    id: "\(path[index - 1].id)-\(node.id)",
                    from: parentOrigin,
                    to: origin,
                    suggestion: false
                ))
            }
        }

        if let current = path.last {
            let exploredKeys = Set(current.childIDs.compactMap { tree.nodes[$0]?.track.id })
            let openSuggestions = (current.candidates ?? []).enumerated().filter {
                !exploredKeys.contains($0.element.id)
            }
            for (offset, item) in openSuggestions.enumerated() {
                let depth = path.count + offset
                let origin = CGPoint(
                    x: x,
                    y: padding + CGFloat(depth) * (cardSize.height + verticalGap)
                )
                let id = "\(current.id)-candidate-\(item.offset)"
                candidates.append(Candidate(
                    id: id,
                    parentID: current.id,
                    track: item.element,
                    origin: origin
                ))
                edges.append(edge(
                    id: id,
                    from: nodes.last?.origin ?? origin,
                    to: origin,
                    suggestion: true
                ))
            }
        }

        let itemCount = nodes.count + candidates.count
        let height = padding * 2 + CGFloat(itemCount) * cardSize.height
            + CGFloat(max(0, itemCount - 1)) * verticalGap
        return RabbitHoleTreeLayout(
            nodes: nodes,
            candidates: candidates,
            edges: edges,
            size: CGSize(width: cardSize.width + padding * 2, height: height)
        )
    }

    private enum Unit {
        case node(RabbitHoleNode)
        case candidate(RabbitHoleTrack, Int)
    }

    private static func units(tree: RabbitHoleTree, node: RabbitHoleNode) -> [Unit] {
        let children = node.childIDs.compactMap { tree.nodes[$0] }
        let childByTrack = Dictionary(uniqueKeysWithValues: children.map { ($0.track.id, $0) })
        var used = Set<UUID>()
        var result: [Unit] = []

        for (index, candidate) in (node.candidates ?? []).enumerated() {
            if let child = childByTrack[candidate.id] {
                used.insert(child.id)
                result.append(.node(child))
            } else {
                result.append(.candidate(candidate, index))
            }
        }
        result.append(contentsOf: children.filter { !used.contains($0.id) }.map(Unit.node))
        return result
    }

    private static func edge(
        id: String,
        from parent: CGPoint,
        to child: CGPoint,
        suggestion: Bool
    ) -> Edge {
        Edge(
            id: id,
            start: CGPoint(x: parent.x + cardSize.width / 2, y: parent.y + cardSize.height),
            end: CGPoint(x: child.x + cardSize.width / 2, y: child.y),
            isSuggestion: suggestion
        )
    }
}
