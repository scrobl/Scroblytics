import Foundation

/// Picker ordering: "by how commonly they'd actually be reached for", then
/// concept groups within numerics — `filter-conditions-fixit-prompt.md`.
///
/// Keep every field selector (conditions, sorts, and both column pickers) in
/// this group order and in the registry's order within each group. A selector
/// may omit fields that do not apply, but must not reorder the remaining ones.
/// Every selectable field must also show its required `QueryField.help` tooltip.
enum QueryFieldGroup: Int, CaseIterable, Sendable, Comparable {
    case identity, scrobble, flags, tags, volume, ranking, engagement, recency, sentiment, dates, context, duration, tempo, metadata, similarity

    var title: String {
        switch self {
        case .identity: "Name"
        case .scrobble: "Scrobble"
        case .flags: "Flags"
        case .tags: "Tags"
        case .volume: "Volume"
        case .ranking: "Rank & momentum"
        case .engagement: "Engagement pattern"
        case .recency: "Recency"
        case .sentiment: "Sentiment"
        case .dates: "Dates"
        case .context: "Context"
        case .duration: "Duration"
        case .tempo: "Tempo"
        case .metadata: "Album metadata"
        case .similarity: "Similar sounds"
        }
    }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

enum QueryAlignment: Sendable { case leading, trailing, center }

/// How a field's value is drawn as a table column. `custom` names a renderer
/// the table resolves in ONE place (`peakBadge`, `popularityDiamond`, …), which
/// is how a tool's distinctive visual identity lives inside the shared table
/// instead of forking it. Kept SwiftUI-free so the registry stays testable.
enum QueryCellStyle: Sendable, Hashable {
    case text
    case integer
    case decimal(Int)
    /// A 0…1 fraction shown as a percentage.
    case percent
    case date
    case boolean
    /// A calendar year: no thousands separator.
    case year
    /// Seconds shown as a track runtime, "3:45" / "1:03:45".
    case runtime
    /// Seconds shown as an aggregate listening time, "2d 4h 12m 9s".
    case listeningTime
    /// Beats per minute, "128" or "127.9".
    case tempo
    /// Degrees in the unit chosen in Settings › Weather, "12.3 °C" / "54.1 °F".
    case temperature
    case custom(String)
}

/// The existing background pipeline that can fill in a background-resolved
/// field's unresolved values — what the results header's "Resolve" button starts.
enum QueryResolverKind: Sendable, Hashable { case duration, bpm, releaseDate, albumTracklists, tags }

/// How a numeric field's stored unit is presented when the user TYPES a value:
/// stored in seconds, entered in minutes. `perUnit` is how many stored units make one shown unit.
struct QueryInputUnit: Sendable, Hashable {
    let label: String
    let perUnit: Double
}

struct QueryColumnSpec: Sendable {
    let alignment: QueryAlignment
    let style: QueryCellStyle
    let width: Double

    /// Numeric right-aligns, text/date left-aligns, boolean/icon centers.
    static func standard(for type: QueryValueType, style: QueryCellStyle? = nil, width: Double? = nil) -> QueryColumnSpec {
        switch type {
        case .numeric: QueryColumnSpec(alignment: .trailing, style: style ?? .integer, width: width ?? 90)
        case .text: QueryColumnSpec(alignment: .leading, style: style ?? .text, width: width ?? 160)
        case .date: QueryColumnSpec(alignment: .leading, style: style ?? .date, width: width ?? 120)
        case .boolean: QueryColumnSpec(alignment: .center, style: style ?? .boolean, width: width ?? 80)
        case .tags: QueryColumnSpec(alignment: .leading, style: style ?? .text, width: width ?? 200)
        }
    }
}

/// A knob on a field that changes what it computes (e.g. the fading window).
/// Parameters are part of a field's identity: `Peak plays @ 90d` and
/// `Peak plays @ 180d` are different values with different cached results.
struct QueryFieldParameter: Sendable {
    let id: String
    let label: String
    let options: [QueryValue]
    let defaultValue: QueryValue
    /// Appended when the value is shown, e.g. "d" → "180d".
    var suffix: String = ""
    /// False keeps the header short when the value is the default ("Play rank", not "Play rank · broken").
    var showsDefaultInTitle = true
    /// What changing this knob does — shown as its tooltip (falls back to the field's own help).
    var help = ""

    func display(_ value: QueryValue) -> String {
        switch value {
        case .number(let n): (n == n.rounded() ? String(Int(n)) : String(n)) + suffix
        case .text(let s): s
        case .bool(let b): b ? "yes" : "no"
        case .date(let d): d.formatted(date: .abbreviated, time: .omitted)
        case .tags(let t): t.joined(separator: ", ")
        }
    }
}

/// Names a field plus concrete parameter values — what conditions, sorts and
/// columns actually store. Parameters left out take the field's defaults.
struct QueryFieldRef: Codable, Hashable, Sendable {
    let id: String
    var parameters: [String: QueryValue] = [:]
    /// The date range this field is computed over. nil = the query's own period. Only fields that
    /// declare scope support accept one (see `QueryField.supportsScope`).
    var scope: QueryScope?
    /// The period a COMPARISON field measures `scope` against ("Plays change: this month vs a year
    /// ago"). Required by fields that compare, rejected by every other field.
    var baseline: QueryScope?

    /// True for a column that is just the field at its defaults — no date scope, no comparison, no setting changed
    /// from its default. Everything else is a "customised" column that gets its own row in the builder.
    func isPlain(in registry: QueryFieldRegistry) -> Bool {
        guard scope == nil, baseline == nil else { return false }
        guard let field = try? registry.field(id) else { return true }
        return parameters.allSatisfy { key, value in field.parameters.first { $0.id == key }?.defaultValue == value }
    }

    /// A ref for `field` with the starting scopes the builder offers: plain fields take the query's
    /// period; comparison fields start at "last 30 days vs the same 30 days a year earlier".
    static func starting(_ field: QueryField) -> QueryFieldRef {
        guard field.comparesPeriods else { return QueryFieldRef(field.id) }
        return QueryFieldRef(field.id, scope: .trailing(days: 30), baseline: QueryScope.trailing(days: 30).shifted(back: 1, .year))
    }

    init(_ id: String, parameters: [String: QueryValue] = [:], scope: QueryScope? = nil, baseline: QueryScope? = nil) {
        self.id = id
        self.parameters = parameters
        self.scope = scope
        self.baseline = baseline
    }
}

/// One queryable / sortable / displayable attribute — the single declaration
/// the condition builder, the evaluation engine and the table's column picker
/// all read.
struct QueryField: Sendable {
    let id: String
    let name: String
    let group: QueryFieldGroup
    let type: QueryValueType
    /// Entity kinds it applies to. Fields that don't apply to a target are
    /// hidden from that target's picker — never offered-then-silently-failing.
    let targets: Set<QueryTarget>
    let parameters: [QueryFieldParameter]
    let column: QueryColumnSpec
    /// What the field means, in plain words. Required: it's the tooltip on every column header and
    /// in every field list, so no field can ship without a definition.
    let help: String
    /// True for background-resolved fields that can be `.pending`.
    let isBackgroundResolved: Bool
    /// Present when the stored unit is awkward to type (seconds → minutes).
    let inputUnit: QueryInputUnit?
    /// A text field with a fixed vocabulary: the builder offers these to pick from instead of free text.
    var choices: [String]?
    /// How to read this field in one line, where its name alone could mislead — shown when Ask interprets a request with it.
    var caveat: String?
    /// False keeps a field out of what Ask shows the model. The on-device model's context is small, so a field it is
    /// unlikely to be asked for by name (used by Trends, and by hand in the builder) stays out of its vocabulary.
    var askable = true
    /// Offered to the larger models (Claude, OpenAI, Gemini, a local server) even though `askable` is false: they have the
    /// context to carry a field the on-device model would only misuse. Meaningless when `askable` is true.
    var askableByLargeModels = false
    /// Set on a field of a single play that is another kind's field for the track, album or artist the play is of: which kind. The
    /// engine then reports the item (not the play) to the lookup that fills a pending value in.
    var itemLevel: QueryTarget?
    /// The pipeline that resolves this field's pending values, if the user can start one.
    let resolver: QueryResolverKind?
    /// Batch compute — one call gives the answer for many entities at once,
    /// because the engines this wraps (fading stats, popularity percentiles)
    /// are inherently whole-library computations. The body must CALL the
    /// existing engine, never re-derive its values.
    let compute: @Sendable (_ run: QueryRun, _ parameters: [String: QueryValue], _ entities: [QueryEntity]) -> [QueryEntityID: QueryCell]
    /// Present on fields that can be computed over a chosen date range. It receives the (unresolved)
    /// scope — nil meaning "the query's own period" — and reads its scrobbles through the run
    /// (`run.scopedAggregates`, `run.scopedScrobblesByEntity`), never the raw arrays.
    let scopedCompute: (@Sendable (_ run: QueryRun, _ parameters: [String: QueryValue], _ scope: QueryScope?, _ entities: [QueryEntity]) -> [QueryEntityID: QueryCell])?

    /// Present on fields that compare two date ranges (`scope` against `baseline`).
    let comparedCompute: (@Sendable (_ run: QueryRun, _ parameters: [String: QueryValue], _ scope: QueryScope?, _ baseline: QueryScope, _ entities: [QueryEntity]) -> [QueryEntityID: QueryCell])?

    var supportsScope: Bool { scopedCompute != nil || comparedCompute != nil }
    var comparesPeriods: Bool { comparedCompute != nil }

    /// A field that compares one date range with another (both default-able scopes).
    init(
        id: String, name: String, group: QueryFieldGroup, type: QueryValueType, targets: Set<QueryTarget>,
        parameters: [QueryFieldParameter] = [], column: QueryColumnSpec? = nil, help: String,
        comparedCompute: @escaping @Sendable (QueryRun, [String: QueryValue], QueryScope?, QueryScope, [QueryEntity]) -> [QueryEntityID: QueryCell]
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.type = type
        self.targets = targets
        self.parameters = parameters
        self.column = column ?? .standard(for: type)
        self.help = help
        self.isBackgroundResolved = false
        self.inputUnit = nil
        self.resolver = nil
        self.compute = { _, _, _ in preconditionFailure("a comparison field is computed with a baseline") }
        self.scopedCompute = nil
        self.comparedCompute = comparedCompute
    }

    /// A field that can be scoped to a date range.
    init(
        id: String, name: String, group: QueryFieldGroup, type: QueryValueType, targets: Set<QueryTarget>,
        parameters: [QueryFieldParameter] = [], column: QueryColumnSpec? = nil, help: String,
        isBackgroundResolved: Bool = false, inputUnit: QueryInputUnit? = nil, resolver: QueryResolverKind? = nil,
        scopedCompute: @escaping @Sendable (QueryRun, [String: QueryValue], QueryScope?, [QueryEntity]) -> [QueryEntityID: QueryCell]
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.type = type
        self.targets = targets
        self.parameters = parameters
        self.column = column ?? .standard(for: type)
        self.help = help
        self.isBackgroundResolved = isBackgroundResolved
        self.inputUnit = inputUnit
        self.resolver = resolver
        self.compute = { run, parameters, entities in scopedCompute(run, parameters, nil, entities) }
        self.scopedCompute = scopedCompute
        self.comparedCompute = nil
    }

    init(
        id: String, name: String, group: QueryFieldGroup, type: QueryValueType, targets: Set<QueryTarget>,
        parameters: [QueryFieldParameter] = [], column: QueryColumnSpec? = nil, help: String,
        isBackgroundResolved: Bool = false, inputUnit: QueryInputUnit? = nil, resolver: QueryResolverKind? = nil,
        compute: @escaping @Sendable (QueryRun, [String: QueryValue], [QueryEntity]) -> [QueryEntityID: QueryCell]
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.type = type
        self.targets = targets
        self.parameters = parameters
        self.column = column ?? .standard(for: type)
        self.help = help
        self.isBackgroundResolved = isBackgroundResolved
        self.inputUnit = inputUnit
        self.resolver = resolver
        self.compute = compute
        self.scopedCompute = nil
        self.comparedCompute = nil
    }
}

/// A field ref whose target applicability and parameters have been validated
/// and completed with defaults.
struct ResolvedField: Sendable {
    let field: QueryField
    let parameters: [String: QueryValue]
    let scope: QueryScope?
    let baseline: QueryScope?

    /// "Peak plays · 180d" / "Plays · Last 7 days, 1 year earlier" — the name plus its parameter
    /// values and scope, so two columns of the same field are told apart.
    var title: String {
        var shown = field.parameters.compactMap { parameter -> String? in
            guard let value = parameters[parameter.id] else { return nil }
            if !parameter.showsDefaultInTitle, value == parameter.defaultValue { return nil }
            return parameter.display(value)
        }
        if let baseline {
            shown.append("\(scope?.label ?? "Query period") vs \(baseline.label)")
        } else if let scope {
            shown.append(scope.label)
        }
        return shown.isEmpty ? field.name : field.name + " · " + shown.joined(separator: ", ")
    }

    /// Distinct per (field, parameters, scope) — the cache key for computed columns.
    var cacheKey: String {
        field.id + "|" + parameters.keys.sorted().map { "\($0)=\(parameters[$0]!)" }.joined(separator: ",")
            + (scope.map { "|scope=" + $0.cacheKey } ?? "") + (baseline.map { "|baseline=" + $0.cacheKey } ?? "")
    }
}

struct QueryFieldRegistry: Sendable {
    let fields: [QueryField]
    private let byID: [String: QueryField]

    /// A duplicate ID is a programming error in a static definition, so it
    /// traps immediately rather than letting one field silently shadow another.
    init(fields: [QueryField]) {
        var map: [String: QueryField] = [:]
        for field in fields {
            precondition(map[field.id] == nil, "Duplicate query field id “\(field.id)”")
            map[field.id] = field
        }
        self.fields = fields
        self.byID = map
    }

    func field(_ id: String) throws -> QueryField {
        guard let field = byID[id] else { throw QueryError.unknownField(id) }
        return field
    }

    /// The picker list for a target, in the shared group order (alphabetical
    /// only as the tiebreak within a group).
    func fields(for target: QueryTarget) -> [QueryField] {
        fields.filter { $0.targets.contains(target) }
            .sorted { a, b in
                a.group != b.group ? a.group < b.group : a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    /// Canonically ordered fields for one picker section. Apply any
    /// selector-specific eligibility filter to this result without reordering it.
    func fields(for target: QueryTarget, in group: QueryFieldGroup) -> [QueryField] {
        fields(for: target).filter { $0.group == group }
    }

    func resolve(_ ref: QueryFieldRef, target: QueryTarget) throws -> ResolvedField {
        let field = try field(ref.id)
        guard field.targets.contains(target) else {
            throw QueryError.fieldNotApplicable(field: field.id, target: target)
        }
        for (key, value) in ref.parameters {
            guard let parameter = field.parameters.first(where: { $0.id == key }) else {
                throw QueryError.unknownParameter(field: field.id, parameter: key)
            }
            guard parameter.options.contains(value) else {
                throw QueryError.invalidParameterValue(field: field.id, parameter: key)
            }
        }
        if let scope = ref.scope {
            guard field.supportsScope else { throw QueryError.scopeNotSupported(field: field.name) }
            try scope.validate()
        }
        if field.comparesPeriods {
            guard let baseline = ref.baseline else { throw QueryError.baselineRequired(field: field.name) }
            try baseline.validate()
        } else if ref.baseline != nil {
            throw QueryError.baselineNotSupported(field: field.name)
        }
        var resolved: [String: QueryValue] = [:]
        for parameter in field.parameters { resolved[parameter.id] = ref.parameters[parameter.id] ?? parameter.defaultValue }
        return ResolvedField(field: field, parameters: resolved, scope: ref.scope, baseline: ref.baseline)
    }
}
