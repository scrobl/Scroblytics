import Foundation

/// Cheap, mechanical checks on an on-device interpretation that catch the mistakes that model makes most often — each
/// one visible in the evaluation set — and say so, rather than letting a plausible-looking wrong query through.
/// They only ever REMOVE or MERGE things the model added; they never invent a condition. A cloud or local-server
/// model doesn't need them (and they would only get in its way), so they run on the on-device path alone.
enum AskGuard {
    static func apply(_ interpretation: AskInterpretation, request: String, registry: QueryFieldRegistry) -> AskInterpretation {
        var result = interpretation
        let text = request.lowercased().replacingOccurrences(of: "’", with: "'")
        let words = Set(text.split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init))

        // 1. A name or artist the request never says isn't in the request ("top 20 songs from 2023" → artist is "The Beatles").
        var groups: [[QueryCondition]] = []
        for group in result.spec.groups {
            var kept: [QueryCondition] = []
            for condition in group {
                if let invented = inventedText(in: condition, request: text, registry: registry) {
                    result.dropped.append(.init(what: "“\(invented)” in the request", reason: "it isn’t something the request says"))
                } else {
                    kept.append(condition)
                }
            }
            if !kept.isEmpty { groups.append(kept) }
        }

        // 2. "Or" only when the request says so: separate alternatives for what is plainly one list of requirements are
        // merged into one group (one of each condition), which is what the screenshot's tripled "Loved is yes" needed.
        if groups.count > 1, !words.contains("or"), !words.contains("either") {
            var merged: [QueryCondition] = []
            var seen = Set<String>()
            for condition in groups.flatMap({ $0 }) {
                let key = condition.field.id + "|" + condition.op.rawValue
                if seen.insert(key).inserted { merged.append(condition) }
            }
            groups = [merged]
            result.dropped.append(.init(what: "alternatives (“or”)", reason: "the request doesn’t say “or”, so they were combined into one set of requirements"))
        }
        result.spec.groups = groups
        return result
    }

    /// The text operand of a name/artist condition when it doesn't occur in the request.
    private static func inventedText(in condition: QueryCondition, request: String, registry: QueryFieldRegistry) -> String? {
        guard let field = try? registry.field(condition.field.id), field.type == .text, field.choices == nil else { return nil }
        for operand in condition.operands {
            guard case .text(let value) = operand else { continue }
            let needle = value.lowercased().replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespaces)
            if !needle.isEmpty, !request.contains(needle) { return value }
        }
        return nil
    }
}
