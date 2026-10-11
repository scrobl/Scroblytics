import SwiftUI

/// Layout constants and layout pass: baseline-graph geometry and
/// spacing/arc-height rules.
enum ListeningFlowLayoutConstants {
    static let height: CGFloat = 380
    static let topPad: CGFloat = 24
    static let baseY: CGFloat = height - 96
    static let sidePad: CGFloat = 44
    static let minSpacing: CGFloat = 48
    static let maxSpacing: CGFloat = 130
    static let rMin: CGFloat = 4
    static let rMax: CGFloat = 15
    static let arcMinPeak: CGFloat = 16
}

struct LaidOutNode: Identifiable {
    let node: FlowNode
    let x: CGFloat
    let r: CGFloat
    let color: Color
    var id: String { node.id }
}

struct FlowLayout {
    let laidOut: [LaidOutNode]
    let posById: [String: LaidOutNode]
    let edges: [FlowEdge]
    let svgWidth: CGFloat
    let maxCount: Int
    let maxDist: CGFloat
    let focusedId: String?
}

private func radiusFor(plays: Int, maxPlays: Int) -> CGFloat {
    guard maxPlays > 0 else { return ListeningFlowLayoutConstants.rMin }
    let ratio = min(Double(plays), Double(maxPlays)) / Double(maxPlays)
    return ListeningFlowLayoutConstants.rMin
        + CGFloat(ratio.squareRoot()) * (ListeningFlowLayoutConstants.rMax - ListeningFlowLayoutConstants.rMin)
}

func computeFlowLayout(data: FlowData, width: CGFloat, nodeCap: Int, focusId: String?) -> FlowLayout? {
    guard data.enoughData else { return nil }

    var clusterSize: [Int: Int] = [:]
    for n in data.nodes { clusterSize[n.cluster, default: 0] += 1 }
    let clusterRank: [Int: Int] = Dictionary(
        uniqueKeysWithValues: clusterSize
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .enumerated()
            .map { (offset, entry) in (entry.key, offset) }
    )

    let byId = Dictionary(uniqueKeysWithValues: data.nodes.map { ($0.id, $0) })
    let focusActive = focusId != nil && byId[focusId!] != nil

    var edges: [FlowEdge]
    var ordered: [FlowNode]

    if focusActive, let focusId {
        edges = data.edges.filter { $0.source == focusId || $0.target == focusId }
        var beforeW: [String: Int] = [:]
        var afterW: [String: Int] = [:]
        for e in edges {
            if e.target == focusId && e.source != focusId {
                beforeW[e.source, default: 0] += e.count
            }
            if e.source == focusId && e.target != focusId {
                afterW[e.target, default: 0] += e.count
            }
        }
        // A bidirectional neighbour is placed on the "after" (right) side only.
        for id in afterW.keys { beforeW.removeValue(forKey: id) }
        let before = beforeW.keys
            .sorted { (beforeW[$0] ?? 0) < (beforeW[$1] ?? 0) }
            .compactMap { byId[$0] }
        let after = afterW.keys
            .sorted { (afterW[$0] ?? 0) > (afterW[$1] ?? 0) }
            .compactMap { byId[$0] }
        ordered = before + [byId[focusId]!] + after
    } else {
        var capped = data.nodes
        if data.nodes.count > nodeCap {
            capped = data.nodes.sorted {
                if $0.plays != $1.plays { return $0.plays > $1.plays }
                return ($0.inWeight + $0.outWeight) > ($1.inWeight + $1.outWeight)
            }
            capped = Array(capped.prefix(nodeCap))
        }
        let keep = Set(capped.map(\.id))
        edges = data.edges.filter { keep.contains($0.source) && keep.contains($0.target) }
        var connected = Set<String>()
        for e in edges {
            connected.insert(e.source)
            connected.insert(e.target)
        }
        ordered = capped
            .filter { connected.contains($0.id) }
            .sorted {
                let rankA = clusterRank[$0.cluster] ?? 0
                let rankB = clusterRank[$1.cluster] ?? 0
                if rankA != rankB { return rankA < rankB }
                if $0.plays != $1.plays { return $0.plays > $1.plays }
                return $0.id < $1.id
            }
    }

    let n = ordered.count
    guard n > 0 else { return nil }

    let svgWidth = max(width, ListeningFlowLayoutConstants.sidePad * 2 + CGFloat(n - 1) * ListeningFlowLayoutConstants.minSpacing)
    let rawGap = n > 1 ? (svgWidth - ListeningFlowLayoutConstants.sidePad * 2) / CGFloat(n - 1) : 0
    let gapX = min(rawGap, ListeningFlowLayoutConstants.maxSpacing)
    let startX = n > 1 ? (svgWidth - gapX * CGFloat(n - 1)) / 2 : svgWidth / 2
    let maxPlays = max(1, ordered.map(\.plays).max() ?? 1)

    let laidOut: [LaidOutNode] = ordered.enumerated().map { i, node in
        let x = n > 1 ? startX + CGFloat(i) * gapX : svgWidth / 2
        let r = radiusFor(plays: node.plays, maxPlays: maxPlays)
        let rank = clusterRank[node.cluster] ?? 0
        let color = clusterColors[rank % clusterColors.count]
        return LaidOutNode(node: node, x: x, r: r, color: color)
    }
    let posById = Dictionary(uniqueKeysWithValues: laidOut.map { ($0.id, $0) })
    let maxCount = max(1, edges.map(\.count).max() ?? 1)

    var maxDist: CGFloat = 0
    for e in edges {
        if let s = posById[e.source], let t = posById[e.target] {
            maxDist = max(maxDist, abs(t.x - s.x))
        }
    }

    return FlowLayout(
        laidOut: laidOut,
        posById: posById,
        edges: edges,
        svgWidth: svgWidth,
        maxCount: maxCount,
        maxDist: maxDist,
        focusedId: focusActive ? focusId : nil
    )
}
