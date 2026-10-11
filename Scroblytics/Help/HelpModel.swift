import Foundation

enum HelpCalloutKind: Sendable {
    case note, tip, warning
}

struct HelpDefinition: Hashable, Sendable {
    let term: String
    let detail: String
}

/// One piece of an article. Text is inline Markdown (bold, code, and `help://article-id` links to another article).
enum HelpBlock: Sendable {
    case heading(String)
    case paragraph(String)
    case bullets([String])
    case steps([String])
    case callout(HelpCalloutKind, String)
    case table(headers: [String], rows: [[String]])
    case definitions([HelpDefinition])
    /// Every Query field in one picker group, drawn from the Field Registry with the hand-written definitions.
    case fieldGroup(QueryFieldGroup)
}

struct HelpArticle: Identifiable, Sendable {
    /// Lowercase, hyphenated: it is also the host of the `help://` link that points here.
    let id: String
    let title: String
    let summary: String
    let blocks: [HelpBlock]
    var keywords: [String] = []

    /// Everything searchable, lowercased.
    var searchText: String {
        var parts = [title, summary] + keywords
        for block in blocks {
            switch block {
            case .heading(let s), .paragraph(let s), .callout(_, let s): parts.append(s)
            case .bullets(let items), .steps(let items): parts += items
            case .table(let headers, let rows): parts += headers + rows.flatMap { $0 }
            case .definitions(let defs): parts += defs.flatMap { [$0.term, $0.detail] }
            case .fieldGroup(let group):
                for field in HelpFields.fields(in: group) {
                    parts.append(field.name)
                    parts.append(HelpFieldDefinitions.definition(for: field.id) ?? field.help)
                }
            }
        }
        return parts.joined(separator: "\n").lowercased()
    }
}

struct HelpSection: Identifiable, Sendable {
    let id: String
    let title: String
    let articles: [HelpArticle]
}

/// The field list behind the Field reference articles.
enum HelpFields {
    /// The Similar Sounds fields live in a separate registry that also includes every standard field.
    static func fields(in group: QueryFieldGroup) -> [QueryField] {
        QueryFieldRegistry.similarSounds.fields
            .filter { $0.group == group }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

enum HelpContent {
    static let sections: [HelpSection] = [
        welcomeSection,
        accountsSection,
        syncSection,
        conceptsSection,
        screensSection,
        toolsSection,
        askQuerySection,
        fieldsSection,
        metricsSection,
        dataSection,
    ]

    static let allArticles: [HelpArticle] = sections.flatMap(\.articles)

    static func article(_ id: String?) -> HelpArticle? {
        guard let id else { return nil }
        return allArticles.first { $0.id == id }
    }

    static var firstArticleID: String? { allArticles.first?.id }

    static func search(_ query: String) -> [HelpArticle] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return allArticles.filter { article in
            let haystack = article.searchText
            return words.allSatisfy { haystack.contains($0) }
        }
    }
}
