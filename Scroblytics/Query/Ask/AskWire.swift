import Foundation

/// The shape of what the language model writes — one place that names every key, so the schema the
/// model is constrained to (`AskSchema`) and the reader of its answer (`AskInterpreter`) can never
/// disagree about a spelling. The model writes JSON in this shape; nothing here is executable.
enum AskWire {
    enum Key {
        static let target = "target"
        static let groups = "groups"
        static let sorts = "sorts"
        static let limit = "limit"
        static let perArtist = "perArtist"
        static let perAlbum = "perAlbum"
        static let perReleaseYear = "perReleaseYear"
        static let unsupported = "unsupported"
        // a condition / sort key
        static let field = "field"
        static let op = "op"
        static let direction = "direction"
        static let value = "value"
        static let valueTo = "valueTo"
        static let text = "text"
        static let date = "date"
        static let dateTo = "dateTo"
        static let tags = "tags"
        static let parameters = "parameters"
        static let scope = "scope"
        static let baseline = "baseline"
        static let comparedAgo = "comparedAgo"
        static let ordered = "ordered"
        static let scoped = "scoped"
        static let absence = "absence"
        static let tagged = "tagged"
        static let count = "count"
        // a scope
        static let kind = "kind"
        static let days = "days"
        static let unit = "unit"
        static let from = "from"
        static let to = "to"
        static let shiftCount = "shiftCount"
        static let shiftUnit = "shiftUnit"
    }

    /// Calendar days as `yyyy-MM-dd` — the only date format the model is asked for.
    static let dateFormat = "yyyy-MM-dd"

    /// Stage 1: what kind of thing, and whether the request asks for an order / a number of results.
    struct Intro: Codable, Sendable, Equatable {
        var target: String
        var scoped: Bool = false
        var absence: Bool = false
        var tagged: Bool = false
        var ordered: Bool = false
        var count: Int?
    }

    /// What stage 1a returns: the kind, and the three "does it mention …" flags.
    struct IntroPart: Codable, Sendable, Equatable {
        var target: String
        var scoped: Bool
        var absence: Bool
        var tagged: Bool
    }

    /// Asked separately from the rest of stage 1 — whether the request wants an order or a number of results is the
    /// question a small model loses track of when it is one of six in a long request.
    struct Shape: Codable, Sendable, Equatable {
        var ordered: Bool
        var count: Int?
    }

    /// "How long before": the earlier period of a comparison is the recent period moved back by this.
    struct Shift: Codable, Sendable, Equatable {
        var count: Int
        var unit: String
    }

    struct Scope: Codable, Sendable, Equatable {
        var kind: String
        var days: Int?
        var unit: String?
        var from: String?
        var to: String?
        var shiftCount: Int?
        var shiftUnit: String?
    }

    struct Condition: Codable, Sendable, Equatable {
        var field: String
        var op: String
        var value: Double?
        var valueTo: Double?
        var text: String?
        var date: String?
        var dateTo: String?
        var tags: [String]?
        var parameters: [String: String]?
        var scope: Scope?
        var baseline: Scope?
        var comparedAgo: Shift?
    }

    struct Sort: Codable, Sendable, Equatable {
        var field: String
        var direction: String
        var parameters: [String: String]?
        var scope: Scope?
        var baseline: Scope?
        var comparedAgo: Shift?
    }

    struct Query: Codable, Sendable, Equatable {
        var groups: [[Condition]]
        var sorts: [Sort]?
        var limit: Int?
        var unsupported: [String]?
        /// Diversity caps (`QueryGroupLimit`): at most N results sharing an artist / an album / a release year.
        var perArtist: Int?
        var perAlbum: Int?
        var perReleaseYear: Int?
    }
}
