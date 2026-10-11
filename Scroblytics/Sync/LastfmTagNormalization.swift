import Foundation

/// Client-side tag text handling shared by every tag-write call site —
/// specified once in tags-feature-prompt.md, implemented here for Track
/// Actions to actually call. Covers tag-name
/// normalization, list normalization and the per-call tag limit.
enum LastfmTagNormalization {
    /// Last.fm's documented hard cap on tags per `addTags` call.
    static let maxTagsPerCall = 10

    /// Trim + lowercase — reduces near-duplicate tags cluttering the user's
    /// own list, even though Last.fm's backend does its own normalization too.
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Splits free-text (comma- or newline-separated) into normalized,
    /// deduplicated tags, preserving first-seen order. Empty fragments are
    /// dropped silently (e.g. a trailing comma), not treated as errors.
    static func normalizeList(_ rawTags: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for raw in rawTags {
            for part in raw.split(whereSeparator: { $0 == "," || $0.isNewline }) {
                let t = normalize(String(part))
                guard !t.isEmpty, !seen.contains(t) else { continue }
                seen.insert(t)
                out.append(t)
            }
        }
        return out
    }
}
