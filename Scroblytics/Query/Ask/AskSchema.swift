#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// The schemas the model's output is constrained to, generated from `QueryFieldRegistry`. Guided
/// generation makes the model choose ONLY from these: a field id that isn't a real field for the
/// target, an operator the field's type doesn't accept, or a parameter value that isn't one of the
/// field's options cannot be produced at all. Each field gets its own condition shape (its own
/// operand kind), joined with `anyOf`.
@available(macOS 26.0, *)
enum AskSchema {
    typealias K = AskWire.Key

    /// Stage 1a: which kind of thing is being asked for, and whether the request names a time window, absence or tags —
    /// plain questions a small model answers reliably, which then decide what stage 2 is allowed to contain.
    static func intro() throws -> GenerationSchema {
        let root = DynamicGenerationSchema(name: "AskIntro", properties: [
            .init(name: K.target, description: "What the request is about",
                  schema: DynamicGenerationSchema(name: "TargetChoice", anyOf: QueryTarget.allCases.map(\.rawValue))),
            .init(name: K.scoped, description: "true only if the request limits plays or activity to a time window: in 2023, the last 30 days, this month, last year, since March…",
                  schema: DynamicGenerationSchema(type: Bool.self)),
            .init(name: K.absence, description: "true only if the request asks about something that has no value: missing, blank, unknown, not set, never…",
                  schema: DynamicGenerationSchema(type: Bool.self)),
            .init(name: K.tagged, description: "true only if the request refers to a genre, style or tag: indie, folk, workout, 90s…",
                  schema: DynamicGenerationSchema(type: Bool.self)),
        ])
        return try GenerationSchema(root: root, dependencies: [])
    }

    /// Stage 1b: does the request ask for an order, and for how many results — asked on its own.
    static func shape() throws -> GenerationSchema {
        let root = DynamicGenerationSchema(name: "AskShape", properties: [
            .init(name: K.ordered, description: "true if the request asks for the top, most, least, best, newest, oldest or biggest of something",
                  schema: DynamicGenerationSchema(type: Bool.self)),
            .init(name: K.count, description: "the number of results the request asks for (\"top 10\", \"the 5 …\", \"25 most played\"), if it gives one",
                  schema: DynamicGenerationSchema(type: Int.self), isOptional: true),
        ])
        return try GenerationSchema(root: root, dependencies: [])
    }

    /// Stage 2: the query, for one target.
    static func query(target: QueryTarget, ordered: Bool, scoped: Bool, absence: Bool, registry: QueryFieldRegistry) throws -> GenerationSchema {
        let fields = registry.askFields(for: target)
        let conditions = fields.flatMap { conditionSchemas(for: $0, scoped: scoped, absence: absence) }
        let sortable = fields.filter { $0.type != .tags }

        var properties: [DynamicGenerationSchema.Property] = [
            .init(name: K.groups, description: "Alternatives (OR); each is a list of conditions that must all hold (AND). Empty when nothing can be expressed.",
                  schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(
                    arrayOf: DynamicGenerationSchema(name: "Condition", anyOf: conditions), minimumElements: 1, maximumElements: 5),
                    maximumElements: 3)),
        ]
        // Ordering exists only when stage 1 found the request asks for it; the number of results is applied from stage 1.
        if ordered, !sortable.isEmpty {
            properties.append(.init(
                name: K.sorts, description: "How to order the results",
                schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(name: "Sort", anyOf: sortable.map { sortSchema(for: $0, scoped: scoped) }), maximumElements: 2)))
        }
        properties.append(.init(name: K.unsupported, description: "Parts of the request that cannot be expressed with the available fields, in plain words; empty when everything could be",
                                schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self))))
        return try GenerationSchema(root: DynamicGenerationSchema(name: "AskQuery", properties: properties), dependencies: [])
    }

    // MARK: - Pieces

    private static func choice(_ name: String, _ values: [String]) -> DynamicGenerationSchema {
        DynamicGenerationSchema(name: name, anyOf: values)
    }

    private static func property(_ name: String, _ schema: DynamicGenerationSchema, optional: Bool = false, description: String? = nil) -> DynamicGenerationSchema.Property {
        .init(name: name, description: description, schema: schema, isOptional: optional)
    }

    /// One condition shape per (field, operand shape): a numeric field's `>` carries a required `value`, its
    /// `between` carries `value` and `valueTo`, its `hasValue` carries neither — so an operator with the wrong
    /// operands, or a missing operand, cannot be produced.
    private static func conditionSchemas(for field: QueryField, scoped: Bool, absence: Bool) -> [DynamicGenerationSchema] {
        // Group the field's operators by how many operands they take (and of what kind).
        var byShape: [(shape: String, ops: [QueryOperator])] = []
        // "has a value" / "is missing" are offered only when stage 1 saw the request ask about absence.
        for op in field.type.operators where (absence || (op != .hasValue && op != .isMissing))
            && (field.choices == nil || op == .textIs || op == .textIsNot || op == .hasValue || op == .isMissing) {
            let shape = "\(op.arity)"
            if let index = byShape.firstIndex(where: { $0.shape == shape }) { byShape[index].ops.append(op) } else { byShape.append((shape, [op])) }
        }
        return byShape.map { shape, ops in
            var props: [DynamicGenerationSchema.Property] = [
                property(K.field, choice("Field_\(field.id)_\(shape)", [field.id])),
                property(K.op, choice("Op_\(field.id)_\(shape)", ops.map(\.rawValue))),
            ]
            let arity = ops[0].arity
            switch (field.type, arity) {
            case (_, .none): break
            case (.numeric, .one): props.append(property(K.value, DynamicGenerationSchema(type: Double.self), description: "The number to compare with"))
            case (.numeric, _):
                props.append(property(K.value, DynamicGenerationSchema(type: Double.self), description: "Lower end"))
                props.append(property(K.valueTo, DynamicGenerationSchema(type: Double.self), description: "Upper end"))
            case (.text, _):
                props.append(property(K.text, field.choices.map { choice("Text_\(field.id)", $0) } ?? DynamicGenerationSchema(type: String.self)))
            case (.date, .one): props.append(property(K.date, DynamicGenerationSchema(type: String.self), description: "A day, \(AskWire.dateFormat)"))
            case (.date, _):
                props.append(property(K.date, DynamicGenerationSchema(type: String.self), description: "First day, \(AskWire.dateFormat)"))
                props.append(property(K.dateTo, DynamicGenerationSchema(type: String.self), description: "Last day, \(AskWire.dateFormat)"))
            case (.tags, _):
                props.append(property(K.tags, DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self), minimumElements: 1)))
            case (.boolean, _): break
            }
            props += modifierProperties(for: field, scoped: scoped, idSuffix: shape)
            return DynamicGenerationSchema(name: "Cond_\(field.id)_\(shape)", description: field.name, properties: props)
        }
    }

    private static func sortSchema(for field: QueryField, scoped: Bool) -> DynamicGenerationSchema {
        var props: [DynamicGenerationSchema.Property] = [
            property(K.field, choice("SortField_\(field.id)", [field.id])),
            property(K.direction, choice("Dir_\(field.id)", ["ascending", "descending"])),
        ]
        props += modifierProperties(for: field, scoped: scoped, idSuffix: "sort")
        return DynamicGenerationSchema(name: "Sort_\(field.id)", description: field.name, properties: props)
    }

    /// Parameters, a date scope and a comparison baseline — only where the field supports them. A field that
    /// compares two periods REQUIRES both.
    private static func modifierProperties(for field: QueryField, scoped: Bool, idSuffix: String) -> [DynamicGenerationSchema.Property] {
        var props: [DynamicGenerationSchema.Property] = []
        if !field.parameters.isEmpty {
            let inner = field.parameters.map { parameter in
                property(parameter.id, choice("Param_\(field.id)_\(parameter.id)_\(idSuffix)", parameter.options.map { parameter.display($0) }),
                         optional: true, description: parameter.label)
            }
            props.append(property(K.parameters, DynamicGenerationSchema(name: "Params_\(field.id)_\(idSuffix)", properties: inner), optional: true))
        }
        // A period is offered only when stage 1 saw a time window in the request — a comparison always needs one.
        if field.supportsScope, scoped || field.comparesPeriods {
            props.append(property(K.scope, scopeSchema(named: "Scope_\(field.id)_\(idSuffix)", allowsShift: !field.comparesPeriods),
                                  optional: !field.comparesPeriods,
                                  description: field.comparesPeriods ? "The recent period" : "The period this field is measured over"))
        }
        if field.comparesPeriods {
            // The earlier period is the recent one moved back, so it is asked for as "how long before" — the model
            // never has to write a second period out.
            let units = QueryScope.Unit.allCases.map(\.rawValue)
            props.append(property(K.comparedAgo, DynamicGenerationSchema(name: "ComparedAgo_\(field.id)_\(idSuffix)", properties: [
                property(K.count, DynamicGenerationSchema(type: Int.self), description: "how many units"),
                property(K.unit, choice("ComparedAgo_\(field.id)_\(idSuffix)_Unit", units)),
            ]), description: "How long before the recent period to compare with (\"a year ago\" = 1 year)"))
        }
        return props
    }

    /// A period, one shape per kind so each carries exactly what it needs: "last N days" always has its N,
    /// "this month/week/…" always has its unit, fixed dates always have both ends.
    private static func scopeSchema(named name: String, allowsShift: Bool = true) -> DynamicGenerationSchema {
        let units = QueryScope.Unit.allCases.map(\.rawValue)
        func kind(_ k: QueryScope.Kind) -> DynamicGenerationSchema.Property { property(K.kind, choice("\(name)_\(k.rawValue)_Kind", [k.rawValue])) }
        func shift() -> [DynamicGenerationSchema.Property] {
            guard allowsShift else { return [] }
            return [property(K.shiftCount, DynamicGenerationSchema(type: Int.self), optional: true, description: "how many shiftUnits back to move the whole period (\"a year ago\" = 1 year)"),
             property(K.shiftUnit, choice("\(name)_ShiftUnit", units), optional: true)]
        }
        return DynamicGenerationSchema(name: name, anyOf: [
            DynamicGenerationSchema(name: "\(name)_allTime", properties: [kind(.allTime)]),
            DynamicGenerationSchema(name: "\(name)_upToNow", properties: [kind(.upToNow)] + shift()),
            DynamicGenerationSchema(name: "\(name)_trailing", properties: [kind(.trailing), property(K.days, DynamicGenerationSchema(type: Int.self), description: "how many days")] + shift()),
            DynamicGenerationSchema(name: "\(name)_calendar", properties: [kind(.calendar), property(K.unit, choice("\(name)_Unit", units))] + shift()),
            DynamicGenerationSchema(name: "\(name)_absolute", properties: [
                kind(.absolute),
                property(K.from, DynamicGenerationSchema(type: String.self), description: "first day, \(AskWire.dateFormat)"),
                property(K.to, DynamicGenerationSchema(type: String.self), description: "last day, \(AskWire.dateFormat)"),
            ]),
        ])
    }
}
#endif
