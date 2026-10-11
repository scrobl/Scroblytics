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
    let totalBeforeConditions: Int
}

@MainActor
enum RabbitHoleEngine {
    static let candidatesPerStep = 3

    static func generate(
        from seed: RabbitHoleTrack,
        path: [RabbitHoleNode],
        groups: [[QueryCondition]],
        perArtist: Int,
        perAlbum: Int,
        scrobbles: [ScrobbleSnapshot],
        snapshots: QuerySnapshots,
        client: LastfmAPIClient
    ) async throws -> RabbitHoleGeneration {
        let similarSeed = SimilarSeed(
            kind: .track,
            artist: seed.artist,
            album: seed.album,
            track: seed.track
        )
        let pool = try await SimilarSoundsTool.generate(
            seeds: [similarSeed],
            scrobbles: scrobbles,
            client: client
        )
        let pathKeys = Set(path.map(\.track.id))
        let availableBeforeConditions = pool.candidates.filter {
            !pathKeys.contains(TextNormalization.lovedKey(artist: $0.artist, track: $0.track))
        }

        let evaluated = try SimilarSoundsTool.evaluate(
            pool: pool,
            groups: groups,
            columns: SimilarSoundsTool.defaultColumns,
            scrobbles: scrobbles,
            snapshots: snapshots,
            arrangement: SimilarSoundsArrangement(
                sort: .shuffled,
                shuffleSeed: UInt64.random(in: 1...UInt64.max),
                songLimit: nil,
                perArtist: nil,
                perAlbum: nil
            )
        )
        let allowed = Set(evaluated.rows.map(\.id))
        let pathArtistCounts = Dictionary(grouping: path, by: { normalized($0.track.artist) }).mapValues(\.count)
        let pathAlbumCounts = Dictionary(grouping: path, by: {
            albumKey(artist: $0.track.artist, album: $0.track.album)
        }).mapValues(\.count)
        var roundArtistCounts: [String: Int] = [:]
        var roundAlbumCounts: [String: Int] = [:]
        var candidates: [RabbitHoleTrack] = []

        for candidate in pool.candidates.shuffled() {
            let id = QueryEntityID(target: .track, artist: candidate.artist, name: candidate.track)
            let key = TextNormalization.lovedKey(artist: candidate.artist, track: candidate.track)
            guard allowed.contains(id), !pathKeys.contains(key) else { continue }

            let artistKey = normalized(candidate.artist)
            let candidateAlbumKey = albumKey(artist: candidate.artist, album: candidate.album)
            if perArtist > 0,
               pathArtistCounts[artistKey, default: 0] + roundArtistCounts[artistKey, default: 0] >= perArtist {
                continue
            }
            if perAlbum > 0,
               pathAlbumCounts[candidateAlbumKey, default: 0] + roundAlbumCounts[candidateAlbumKey, default: 0] >= perAlbum {
                continue
            }

            roundArtistCounts[artistKey, default: 0] += 1
            roundAlbumCounts[candidateAlbumKey, default: 0] += 1
            candidates.append(RabbitHoleTrack(
                artist: candidate.artist,
                track: candidate.track,
                album: candidate.album,
                imageURL: candidate.imageURL,
                playCount: candidate.totalPlaycount,
                lastPlayed: candidate.lastPlayed,
                matchScore: candidate.matchScore,
                source: candidate.topSource
            ))
            if candidates.count == candidatesPerStep { break }
        }

        return RabbitHoleGeneration(
            candidates: candidates,
            totalBeforeConditions: availableBeforeConditions.count
        )
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
