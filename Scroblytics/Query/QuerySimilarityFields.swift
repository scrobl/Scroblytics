import Foundation

/// What a Similar Sounds run learned about each candidate track — a read-only copy handed to the query run, the
/// same way loved keys or tag caches are. Empty for every ordinary query.
struct SimilaritySnapshot: Sendable {
    struct Entry: Sendable {
        /// 0–100: the highest Last.fm match across every seed that surfaced the track.
        let score: Int
        /// Every seed that surfaced it, the one that matched best first, the rest alphabetical.
        let sources: [String]
    }

    var byID: [QueryEntityID: Entry] = [:]
    static let empty = SimilaritySnapshot()

    /// Separator for the readable attribution text a column holds.
    static let sourceSeparator = " · "

    static func attribution(_ entry: Entry) -> String { entry.sources.joined(separator: sourceSeparator) }
}

/// The match score and "Because you like …" attribution of a Similar Sounds candidate. These live in their OWN
/// registry (`similarSounds`), not `standard`: they only mean anything for a generated pool, so the Query tab's
/// pickers, saved sets and Ask never offer them.
extension QueryFieldRegistry {
    static let similarityFields: [QueryField] = {
        var attribution = QueryField(
            id: "similarBecause", name: "Because you like", group: .similarity, type: .text, targets: [.track],
            column: QueryColumnSpec(alignment: .leading, style: .custom("becauseYouLike"), width: 260),
            help: "The seed(s) of this search that surfaced the track, best match first. Filter on it to keep only what one seed found."
        ) { run, _, entities in
            let similarity = run.snapshots.similarity
            return Dictionary(uniqueKeysWithValues: entities.map { entity in
                (entity.id, similarity.byID[entity.id].map { .value(.text(SimilaritySnapshot.attribution($0))) } ?? .missing)
            })
        }
        attribution.askable = false

        var score = QueryField(
            id: "similarScore", name: "Match score", group: .similarity, type: .numeric, targets: [.track],
            column: QueryColumnSpec(alignment: .trailing, style: .custom("similarScore"), width: 120),
            help: "How closely Last.fm rates the track to your seeds, 0–100 — the best match across the seeds that surfaced it."
        ) { run, _, entities in
            let similarity = run.snapshots.similarity
            return Dictionary(uniqueKeysWithValues: entities.map { entity in
                (entity.id, similarity.byID[entity.id].map { .value(.number(Double($0.score))) } ?? .missing)
            })
        }
        score.askable = false
        return [score, attribution]
    }()

    /// Everything in `standard`, plus the similarity fields — what the Similar Sounds refinement editor and
    /// evaluation use.
    static let similarSounds = QueryFieldRegistry(fields: standard.fields + similarityFields)
}
