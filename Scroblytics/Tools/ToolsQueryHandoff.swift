import Foundation

/// The shared "hand a `QuerySpec` to the Query tab" mechanism every tab that opens Query from elsewhere
/// uses — Trends' charts today, every Category A tool's "Advanced" button from here on. One builder, one
/// results table: this never opens a second, embedded condition-builder instance of its own.
enum QueryHandoff {
    /// - Parameters:
    ///   - source: the originating tab's name, shown in the breadcrumb ("Trends", "Tools").
    ///   - detail: what was clicked/handed off, shown in the crumb's tooltip and the Query header.
    ///   - action: `.run` to execute immediately (a chart's drill-down), `.edit` to load it ready for
    ///     further editing without running it yet (a Tool's "Advanced" escape hatch).
    ///   - suggestedName: defaults the Save As sheet to this name if the user saves the spec from Query —
    ///     never saves anything by itself, and never creates a `SavedConditionSet` on its own.
    @MainActor
    static func request(
        spec: QuerySpec, source: String, detail: String, action: AskQueryRequest.Action = .edit,
        suggestedName: String? = nil, onReturn: @escaping @MainActor @Sendable () -> Void
    ) -> AskQueryRequest {
        AskQueryRequest(spec: spec, action: action, cameFrom: DetailPredecessor(source: source, detail: detail, onReturn: onReturn), suggestedName: suggestedName)
    }
}
