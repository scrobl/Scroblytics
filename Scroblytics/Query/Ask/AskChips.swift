import Foundation

/// A short, human-readable piece of an interpreted query — what the user confirms before anything runs.
struct AskChip: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case target, condition, alternative, sort, limit }
    let id = UUID()
    let kind: Kind
    let text: String
    /// The field's own `help`, for the chip's tooltip.
    var help: String? = nil
    /// The field's caveat, if it has one.
    var caveat: String? = nil
}

/// Describes a `QuerySpec` in words, from the same titles and labels the builder itself shows: a field's
/// title (which already carries its parameters and date scope), the operator's label, and each operand in
/// the unit a person would say it in.
enum AskChips {
    /// Whether weather has been turned on, a place chosen and something downloaded: a weather filter can match nothing before that.
    static var weatherReady: Bool {
        WeatherSettings.isEnabled() && WeatherSettings.place() != nil && UserDefaults.standard.object(forKey: WeatherSettings.lastUpdateKey) != nil
    }

    /// Whether a home place is set with weather on: a city filter can match nothing before that (it needs no download).
    static var cityReady: Bool { WeatherSettings.isEnabled() && WeatherSettings.place() != nil }

    static func describe(_ spec: QuerySpec, registry: QueryFieldRegistry, weatherReady: Bool = AskChips.weatherReady, cityReady: Bool = AskChips.cityReady) -> [AskChip] {
        var chips = [AskChip(kind: .target, text: spec.target.rawValue.capitalized + "s")]
        for (index, group) in spec.groups.enumerated() {
            if index > 0 { chips.append(AskChip(kind: .alternative, text: "or")) }
            for condition in group {
                let field = try? registry.field(condition.field.id)
                chips.append(AskChip(kind: .condition, text: describe(condition, target: spec.target, registry: registry), help: field?.help, caveat: field?.caveat))
            }
        }
        if let filter = spec.playFilter, !filter.isEmpty {
            chips.append(AskChip(
                kind: .condition, text: "Only plays: " + filter.label,
                help: "Only the plays made then are counted, so plays, ranks and dates use just those plays.",
                caveat: filter.usesWeather && !weatherReady ? "This needs weather, which is off or not downloaded yet, so no plays can match. Turn it on in Settings › Weather."
                    : (filter.usesCity && !cityReady ? "This needs a home place, which isn't set yet (weather is off), so no plays can match. Set one in Settings › Weather." : nil)
            ))
        }
        for sort in spec.sorts {
            switch sort.key {
            case .shuffle: chips.append(AskChip(kind: .sort, text: "Random order"))
            case .field(let ref):
                let title = (try? registry.resolve(ref, target: spec.target).title) ?? ref.id
                chips.append(AskChip(kind: .sort, text: "Sorted by \(title) \(sort.direction == .descending ? "↓" : "↑")"))
            }
        }
        if spec.breakdown != nil { chips.append(AskChip(kind: .limit, text: "For each calendar year" + (spec.breakdown?.showsNewestFirst == true ? " (newest first)" : ""))) }
        if let limit = spec.limit { chips.append(AskChip(kind: .limit, text: "Top \(limit.formatted())" + (spec.breakdown != nil ? " per year" : ""))) }
        // How the picked results are shown, when it differs from the sort order above.
        if let order = spec.resultSorts?.first {
            switch order.key {
            case .shuffle: chips.append(AskChip(kind: .sort, text: "Shown in random order"))
            case .field(let ref):
                let title = (try? registry.resolve(ref, target: spec.target).title) ?? ref.id
                chips.append(AskChip(kind: .sort, text: "Shown by \(title) \(order.direction == .descending ? "↓" : "↑")"))
            }
        } else if spec.groupLimit?.perReleaseYear != nil, spec.showInRankOrder != true {
            chips.append(AskChip(kind: .sort, text: "Shown by release year ↑"))
        }
        if let perArtist = spec.groupLimit?.perArtist { chips.append(AskChip(kind: .limit, text: "≤\(perArtist) per artist")) }
        if let perAlbum = spec.groupLimit?.perAlbum { chips.append(AskChip(kind: .limit, text: "≤\(perAlbum) per album")) }
        if let perYear = spec.groupLimit?.perReleaseYear { chips.append(AskChip(kind: .limit, text: "≤\(perYear) per release year")) }
        return chips
    }

    static func describe(_ condition: QueryCondition, target: QueryTarget, registry: QueryFieldRegistry) -> String {
        guard let resolved = try? registry.resolve(condition.field, target: target) else { return condition.field.id }
        let operands = condition.operands.map { display($0, field: resolved.field) }
        let value: String
        switch condition.op.arity {
        case .none: value = ""
        case .two: value = operands.joined(separator: " and ")
        default: value = operands.joined(separator: ", ")
        }
        return [resolved.title, condition.op.label, value].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func display(_ value: QueryValue, field: QueryField) -> String {
        switch value {
        case .number(let stored):
            if case .percent = field.column.style { return (stored * 100).formatted(.number.precision(.fractionLength(0...1))) + "%" }
            let shown = AskOperand.shown(stored, for: field)
            if case .year = field.column.style { return String(Int(shown.rounded())) }
            if case .temperature = field.column.style { return WeatherSettings.temperatureUnit().text(shown: shown, places: 1) }
            let text = shown.formatted(.number.precision(.fractionLength(0...2)))
            return field.inputUnit.map { "\(text) \($0.label)" } ?? text
        case .text(let s): return "“\(s)”"
        case .bool(let b): return b ? "yes" : "no"
        case .date(let d): return d.formatted(date: .abbreviated, time: .omitted)
        case .tags(let t): return t.map { "“\($0)”" }.joined(separator: ", ")
        }
    }
}
