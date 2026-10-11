import Foundation

/// The one place a single condition is tested against a single field value.
/// Everything that filters — the evaluation engine, saved sets, any future
/// preset UI or natural-language translator — goes through here.
///
/// **Null semantics** (deliberate, and the same for every field):
/// - `hasValue` matches only a resolved value; `isMissing` matches only a
///   *resolved* absence. A `.pending` cell matches NEITHER — unknown isn't absent.
/// - Every other operator, **negations included** ("is not", "does not
///   contain", `≠`), is false for a missing or pending cell. "Album does not
///   contain live" therefore excludes tracks with no album; add an
///   `isMissing` leaf in a second OR group to include them. (SQL-style, so a
///   condition never quietly widens to cover absent data.)
/// - One exception, tags: for the tag operators a `.missing` cell counts as an
///   EMPTY tag list, so "is none of [folk]" includes untagged entities.
///   `.pending` still matches nothing.
///
/// **Why these are deliberate**
/// - *Pending matches neither side.* A value that hasn't resolved yet (BPM,
///   duration, release date, popularity) is unknown, not absent: counting it as
///   "missing" would report a data gap that's only a not-yet-finished lookup,
///   and letting it satisfy a comparison would invent a value. Rows are
///   therefore left out until resolved, and that is never silent — the results
///   header shows "N still resolving <field>" (`QueryEngine.pendingReport`,
///   surfaced in `QueryView`) — counting only the items whose place in the result actually
///   hinges on that value, and telling Resolve which ones those are.
/// - *Negations exclude no-value rows for scalar fields.* A missing scalar
///   (no album, no BPM) means "nothing to compare", so asserting "≠ X" or
///   "does not contain X" about it would claim a fact the data doesn't hold.
/// - *Tags differ because a tag list is a set, and "no tags" is a real, valid
///   set — the empty one.* An untagged track genuinely IS "not tagged folk".
///   A (possibly empty) tag array is evaluated, and "not tagged" returns `!has`.
///   Neither PRD specifies either behaviour; they were chosen deliberately.
struct QueryMatcher: Sendable {
    /// Calendar-day comparisons use this (the user's local calendar in the app).
    var calendar: Calendar = AppCalendars.listening

    /// Throws for a condition that could never be evaluated meaningfully.
    static func validate(fieldID: String, fieldType: QueryValueType, op: QueryOperator, operands: [QueryValue]) throws {
        guard fieldType.operators.contains(op) else {
            throw QueryError.operatorNotAllowed(field: fieldID, op: op, fieldType: fieldType)
        }
        switch (op.arity, operands.count) {
        case (.none, 0), (.one, 1), (.two, 2): break
        case (.oneOrMore, let n) where n >= 1: break
        default: throw QueryError.wrongOperandCount(op: op, expected: op.arity, got: operands.count)
        }
        if let expected = op.operandType {
            for operand in operands where operand.type != expected {
                throw QueryError.wrongOperandType(op: op, expected: expected, got: operand.type)
            }
        }
        if case .tags(let tags)? = operands.first, tags.isEmpty { throw QueryError.emptyTagOperand }
        if op.operandType == .text, case .text(let text)? = operands.first,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw QueryError.emptyTextOperand
        }
        switch (op, operands.first, operands.dropFirst().first) {
        case (.between, .number(let lo)?, .number(let hi)?) where lo > hi: throw QueryError.rangeOutOfOrder
        case (.dateBetween, .date(let lo)?, .date(let hi)?) where lo > hi: throw QueryError.rangeOutOfOrder
        default: break
        }
    }

    func matches(
        _ cell: QueryCell,
        op: QueryOperator,
        operands: [QueryValue],
        calendar comparisonCalendar: Calendar? = nil
    ) -> Bool {
        let dateCalendar = comparisonCalendar ?? calendar
        switch op {
        case .hasValue: if case .value = cell { return true } else { return false }
        case .isMissing: return cell == .missing
        default: break
        }

        // Tags: a resolved absence is an empty list.
        if [.tagsIsAny, .tagsIsAll, .tagsIsNotAny, .tagsIsNotAll].contains(op), cell == .missing {
            return matchesTags(have: [], op: op, operands: operands)
        }
        guard case .value(let value) = cell else { return false }

        switch (op, value) {
        case (.equals, .number(let v)): return operandNumber(operands, 0).map { v == $0 } ?? false
        case (.notEquals, .number(let v)): return operandNumber(operands, 0).map { v != $0 } ?? false
        case (.greaterThan, .number(let v)): return operandNumber(operands, 0).map { v > $0 } ?? false
        case (.greaterThanOrEqual, .number(let v)): return operandNumber(operands, 0).map { v >= $0 } ?? false
        case (.lessThan, .number(let v)): return operandNumber(operands, 0).map { v < $0 } ?? false
        case (.lessThanOrEqual, .number(let v)): return operandNumber(operands, 0).map { v <= $0 } ?? false
        case (.between, .number(let v)):
            guard let lo = operandNumber(operands, 0), let hi = operandNumber(operands, 1) else { return false }
            return v >= lo && v <= hi

        case (.textIs, .text(let v)): return withText(v, operands) { $0 == $1 }
        case (.textIsNot, .text(let v)): return withText(v, operands) { $0 != $1 }
        case (.contains, .text(let v)): return withText(v, operands) { $0.contains($1) }
        case (.doesNotContain, .text(let v)): return withText(v, operands) { !$0.contains($1) }
        case (.startsWith, .text(let v)): return withText(v, operands) { $0.hasPrefix($1) }
        case (.doesNotStartWith, .text(let v)): return withText(v, operands) { !$0.hasPrefix($1) }
        case (.endsWith, .text(let v)): return withText(v, operands) { $0.hasSuffix($1) }
        case (.doesNotEndWith, .text(let v)): return withText(v, operands) { !$0.hasSuffix($1) }
        case (.wholeWord, .text(let v)): return withText(v, operands) { Self.containsWholeWord($0, word: $1) }

        case (.before, .date(let v)): return operandDate(operands, 0).map { v < dateCalendar.startOfDay(for: $0) } ?? false
        case (.after, .date(let v)): return operandDate(operands, 0).map { v >= dayAfter($0, calendar: dateCalendar) } ?? false
        case (.on, .date(let v)): return operandDate(operands, 0).map { dateCalendar.isDate(v, inSameDayAs: $0) } ?? false
        case (.dateBetween, .date(let v)):
            guard let lo = operandDate(operands, 0), let hi = operandDate(operands, 1) else { return false }
            return v >= dateCalendar.startOfDay(for: lo) && v < dayAfter(hi, calendar: dateCalendar)

        case (.isTrue, .bool(let v)): return v
        case (.isFalse, .bool(let v)): return !v

        case (.tagsIsAny, .tags(let have)), (.tagsIsAll, .tags(let have)),
             (.tagsIsNotAny, .tags(let have)), (.tagsIsNotAll, .tags(let have)):
            return matchesTags(have: have, op: op, operands: operands)

        default:
            // Operator/value-type mismatch. `validate` rejects these up front;
            // reaching here means a field returned the wrong value type.
            return false
        }
    }

    // MARK: - Helpers

    private func operandNumber(_ operands: [QueryValue], _ i: Int) -> Double? {
        guard operands.indices.contains(i), case .number(let n) = operands[i] else { return nil }
        return n
    }

    private func operandDate(_ operands: [QueryValue], _ i: Int) -> Date? {
        guard operands.indices.contains(i), case .date(let d) = operands[i] else { return nil }
        return d
    }

    private func dayAfter(_ date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date
    }

    private func withText(_ value: String, _ operands: [QueryValue], _ test: (String, String) -> Bool) -> Bool {
        guard case .text(let needle)? = operands.first else { return false }
        return test(Self.fold(value), Self.fold(needle))
    }

    private func matchesTags(have: [String], op: QueryOperator, operands: [QueryValue]) -> Bool {
        guard case .tags(let wanted)? = operands.first else { return false }
        let haveSet = Set(have)
        let wantedSet = Set(wanted)
        guard !wantedSet.isEmpty else { return false }
        switch op {
        case .tagsIsAny: return !haveSet.isDisjoint(with: wantedSet)
        case .tagsIsAll: return wantedSet.isSubset(of: haveSet)
        case .tagsIsNotAny: return haveSet.isDisjoint(with: wantedSet)
        case .tagsIsNotAll: return !wantedSet.isSubset(of: haveSet)
        default: return false
        }
    }

    /// Case-, diacritic- and width-insensitive, trimmed.
    static func fold(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// True when `word` appears in `text` bounded by non-letter/digit characters.
    static func containsWholeWord(_ text: String, word: String) -> Bool {
        guard !word.isEmpty else { return false }
        let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}_])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
