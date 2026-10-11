import Foundation

/// Every operator the framework offers. Which apply to which value type is
/// defined ONCE, in `QueryValueType.operators` — the condition builder, the
/// validator and the matcher all read that, none keep their own list.
enum QueryOperator: String, Codable, CaseIterable, Sendable, Hashable {
    // Numeric
    case equals, notEquals, greaterThan, greaterThanOrEqual, lessThan, lessThanOrEqual, between
    // Text (case/diacritic-insensitive)
    case textIs, textIsNot
    case contains, doesNotContain
    case startsWith, doesNotStartWith
    case endsWith, doesNotEndWith
    case wholeWord
    // Date (calendar-day granularity)
    case before, after, on, dateBetween
    // Boolean
    case isTrue, isFalse
    // Tags — exact, autocompleted values, so is/is-not with an any/all mode,
    // deliberately NOT the substring operators.
    case tagsIsAny, tagsIsAll, tagsIsNotAny, tagsIsNotAll
    // Every type
    case hasValue, isMissing

    /// How many operands the operator takes.
    enum Arity: Equatable, Sendable {
        case none
        case one
        case two
        /// One or more (tags).
        case oneOrMore
    }

    var arity: Arity {
        switch self {
        case .hasValue, .isMissing, .isTrue, .isFalse: .none
        case .between, .dateBetween: .two
        case .tagsIsAny, .tagsIsAll, .tagsIsNotAny, .tagsIsNotAll: .oneOrMore
        default: .one
        }
    }

    /// The operand type the operator expects (nil when it takes none).
    var operandType: QueryValueType? {
        switch self {
        case .equals, .notEquals, .greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual, .between: .numeric
        case .textIs, .textIsNot, .contains, .doesNotContain, .startsWith, .doesNotStartWith,
             .endsWith, .doesNotEndWith, .wholeWord: .text
        case .before, .after, .on, .dateBetween: .date
        case .tagsIsAny, .tagsIsAll, .tagsIsNotAny, .tagsIsNotAll: .tags
        case .isTrue, .isFalse, .hasValue, .isMissing: nil
        }
    }

    var label: String {
        switch self {
        case .equals: "="
        case .notEquals: "≠"
        case .greaterThan: ">"
        case .greaterThanOrEqual: "≥"
        case .lessThan: "<"
        case .lessThanOrEqual: "≤"
        case .between: "between"
        case .textIs: "is"
        case .textIsNot: "is not"
        case .contains: "contains"
        case .doesNotContain: "does not contain"
        case .startsWith: "starts with"
        case .doesNotStartWith: "does not start with"
        case .endsWith: "ends with"
        case .doesNotEndWith: "does not end with"
        case .wholeWord: "contains whole word"
        case .before: "before"
        case .after: "after"
        case .on: "on"
        case .dateBetween: "between"
        case .isTrue: "is yes"
        case .isFalse: "is no"
        case .tagsIsAny: "is any of"
        case .tagsIsAll: "is all of"
        case .tagsIsNotAny: "is none of"
        case .tagsIsNotAll: "is not all of"
        case .hasValue: "has a value"
        case .isMissing: "is missing"
        }
    }
}

extension QueryValueType {
    /// The single source of truth for which operators a field of this type
    /// offers. `hasValue`/`isMissing` are on EVERY type from day one — the gap
    /// that was only found late (people tried `= 0` / `< 1` to find missing BPM).
    var operators: [QueryOperator] {
        let universal: [QueryOperator] = [.hasValue, .isMissing]
        switch self {
        case .numeric:
            return [.equals, .notEquals, .greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual, .between] + universal
        case .text:
            return [.textIs, .textIsNot, .contains, .doesNotContain, .startsWith, .doesNotStartWith,
                    .endsWith, .doesNotEndWith, .wholeWord] + universal
        case .date:
            return [.before, .after, .on, .dateBetween] + universal
        case .boolean:
            return [.isTrue, .isFalse] + universal
        case .tags:
            return [.tagsIsAny, .tagsIsAll, .tagsIsNotAny, .tagsIsNotAll] + universal
        }
    }
}

/// Why a condition can't be evaluated. Thrown at validation time — never
/// swallowed into "matches nothing".
enum QueryError: Error, Equatable, CustomStringConvertible {
    case unknownField(String)
    case fieldNotApplicable(field: String, target: QueryTarget)
    case operatorNotAllowed(field: String, op: QueryOperator, fieldType: QueryValueType)
    case wrongOperandCount(op: QueryOperator, expected: QueryOperator.Arity, got: Int)
    case wrongOperandType(op: QueryOperator, expected: QueryValueType, got: QueryValueType)
    case unknownParameter(field: String, parameter: String)
    case invalidParameterValue(field: String, parameter: String)
    case unsupported(String)
    case emptyTagOperand
    case emptyTextOperand
    case rangeOutOfOrder
    case scopeNotSupported(field: String)
    case invalidScope(String)
    case baselineRequired(field: String)
    case baselineNotSupported(field: String)

    var description: String {
        switch self {
        case .unknownField(let id): "Unknown field “\(id)”"
        case .fieldNotApplicable(let field, let target): "Field “\(field)” doesn’t apply to \(target.rawValue)s"
        case .operatorNotAllowed(let field, let op, let type): "“\(op.label)” isn’t available on \(type.rawValue) field “\(field)”"
        case .wrongOperandCount(let op, let expected, let got): "“\(op.label)” takes \(expected) operand(s), got \(got)"
        case .wrongOperandType(let op, let expected, let got): "“\(op.label)” needs a \(expected.rawValue) value, got \(got.rawValue)"
        case .unknownParameter(let field, let p): "Field “\(field)” has no parameter “\(p)”"
        case .invalidParameterValue(let field, let p): "Invalid value for “\(field)” parameter “\(p)”"
        case .unsupported(let what): "Not supported yet: \(what)"
        case .emptyTagOperand: "Pick at least one tag"
        case .emptyTextOperand: "Enter some text to match"
        case .rangeOutOfOrder: "The range’s start is after its end"
        case .scopeNotSupported(let field): "“\(field)” can’t be scoped to a date range"
        case .invalidScope(let why): "Invalid date scope: \(why)"
        case .baselineRequired(let field): "“\(field)” compares two periods — pick the period to compare with"
        case .baselineNotSupported(let field): "“\(field)” doesn’t compare against another period"
        }
    }
}
