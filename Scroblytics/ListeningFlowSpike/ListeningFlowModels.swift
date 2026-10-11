import SwiftUI

enum FlowNodeRole {
    case starter
    case ender
}

struct FlowNode: Identifiable {
    let id: String
    let plays: Int
    let cluster: Int
    let inDegree: Int
    let outDegree: Int
    let inWeight: Int
    let outWeight: Int
    let role: FlowNodeRole?
}

enum FlowEdgeStatus {
    case normal
    case new
    case dropped
}

struct FlowEdge {
    let source: String
    let target: String
    let count: Int
    let status: FlowEdgeStatus
}

struct FlowData {
    let nodes: [FlowNode]
    let edges: [FlowEdge]
    let enoughData: Bool
    let sessionCount: Int
    let totalTransitions: Int
    let compare: Bool
}

/// Cluster palette — cycled by connected-component index (biggest cluster first),
/// a fixed palette.
let clusterColors: [Color] = [
    .blue, .purple, .green, .orange, .pink, .red, .yellow,
]
