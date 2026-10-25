import Foundation

/// What a query runs over. Matches the three entity kinds the app already has
/// (`PopularityKind`, `TopChartsEntity`); kept separate so the query layer has
/// no dependency on either.
enum QueryTarget: String, Codable, CaseIterable, Sendable, Hashable {
    case artist, album, track, scrobble, session

    /// What the on-device model can find: items, not single plays (its context is too small for the play fields).
    static var askTargets: [QueryTarget] { [.artist, .album, .track] }

    /// What the larger models (Claude, OpenAI, Gemini, a local server) can find: also single plays.
    static var modelAskTargets: [QueryTarget] { [.artist, .album, .track, .scrobble, .session] }
}

enum QueryValueType: String, Codable, Sendable {
    case numeric, text, boolean, date, tags
}

/// A concrete value a field can hold, or an operand a condition compares with.
/// "No value" is NOT a `QueryValue` — it's `QueryCell.missing` / `.pending`.
enum QueryValue: Sendable, Hashable {
    case number(Double)
    case text(String)
    case bool(Bool)
    case date(Date)
    /// Lowercased, trimmed, de-duplicated tag names.
    case tags([String])

    var type: QueryValueType {
        switch self {
        case .number: .numeric
        case .text: .text
        case .bool: .boolean
        case .date: .date
        case .tags: .tags
        }
    }

    static func tags(normalizing raw: [String]) -> QueryValue {
        var seen = Set<String>()
        var out: [String] = []
        for tag in raw {
            let t = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !t.isEmpty, seen.insert(t).inserted { out.append(t) }
        }
        return .tags(out)
    }
}

extension QueryValue: Codable {
    private enum CodingKeys: String, CodingKey { case type, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(QueryValueType.self, forKey: .type) {
        case .numeric: self = .number(try c.decode(Double.self, forKey: .value))
        case .text: self = .text(try c.decode(String.self, forKey: .value))
        case .boolean: self = .bool(try c.decode(Bool.self, forKey: .value))
        case .date: self = .date(Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .value)))
        case .tags: self = .tags(try c.decode([String].self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        switch self {
        case .number(let v): try c.encode(v, forKey: .value)
        case .text(let v): try c.encode(v, forKey: .value)
        case .bool(let v): try c.encode(v, forKey: .value)
        case .date(let v): try c.encode(v.timeIntervalSince1970, forKey: .value)
        case .tags(let v): try c.encode(v, forKey: .value)
        }
    }
}

/// One field's answer for one entity.
///
/// `.pending` vs `.missing` is the whole point of the resolution-status
/// requirement: a background-resolved field (release date, popularity…) that is
/// still queued is NOT the same as one that was looked up and genuinely has no
/// value. "Is missing" must match only the latter — otherwise "find tracks with
/// no release date" would list everything the warmer hasn't reached yet.
enum QueryCell: Sendable, Equatable {
    case value(QueryValue)
    /// Resolved: there is genuinely no value (or the field doesn't apply).
    case missing
    /// Not resolved yet — unknown, not absent.
    case pending
}
