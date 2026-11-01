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
    /// “Now” for the relative date operators (“in the last 30 days”). The engine passes the run's `asOf`, so a saved query rolls
    /// forward and a check can pin the day.
    var now: Date = Date()

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
        let types = op.operandTypes
        for (index, operand) in operands.enumerated() {
            guard let expected = op.arity == .oneOrMore ? types.first : (types.indices.contains(index) ? types[index] : nil) else { continue }
            if operand.type != expected { throw QueryError.wrongOperandType(op: op, expected: expected, got: operand.type) }
        }
        try validateRelativeOperands(op: op, operands: operands)
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

    /// The extra rules of the operators whose operands are more than a plain value: a whole count of a known unit, known days.
    private static func validateRelativeOperands(op: QueryOperator, operands: [QueryValue]) throws {
        switch op {
        case .inLast, .notInLast:
            guard case .number(let count)? = operands.first, case .text(let unit)? = operands.dropFirst().first else { return }
            guard count == count.rounded(), count >= 1, count <= Double(QueryOperator.relativeCountLimit) else {
                throw QueryError.invalidOperand("“\(op.label)” needs a whole number of at least 1 (and at most \(QueryOperator.relativeCountLimit.formatted()))")
            }
            guard QueryOperator.relativeUnits.contains(unit) else {
                throw QueryError.invalidOperand("“\(unit)” isn’t a unit of time (\(QueryOperator.relativeUnits.joined(separator: ", ")))")
            }
        case .weekdayIs, .weekdayIsNot:
            for case .text(let name) in operands where weekdayIndex(of: name) == nil {
                throw QueryError.invalidOperand("“\(name)” isn’t a day of the week (\(QueryOperator.dayNames.joined(separator: ", ")))")
            }
        default: break
        }
    }

    /// 0 = Sunday … 6 = Saturday for a day name, ignoring case and surrounding spaces; nil for anything else.
    static func weekdayIndex(of name: String) -> Int? {
        let wanted = fold(name)
        return QueryOperator.dayNames.firstIndex { fold($0) == wanted }
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
        case (.notOn, .date(let v)): return operandDate(operands, 0).map { !dateCalendar.isDate(v, inSameDayAs: $0) } ?? false
        case (.inLast, .date(let v)): return inLastWindow(operands, calendar: dateCalendar).map { v >= $0.start && v < $0.end } ?? false
        // Everything outside the window counts, including a date still to come (an unreleased album is not in the last year).
        case (.notInLast, .date(let v)): return inLastWindow(operands, calendar: dateCalendar).map { !(v >= $0.start && v < $0.end) } ?? false
        case (.weekdayIs, .date(let v)): return weekdays(operands).map { $0.contains(dateCalendar.component(.weekday, from: v) - 1) } ?? false
        case (.weekdayIsNot, .date(let v)): return weekdays(operands).map { !$0.contains(dateCalendar.component(.weekday, from: v) - 1) } ?? false
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

    /// The days “in the last N units” covers: from the day after N units ago through today, so “the last 7 days” is today and the six
    /// days before it. “Today” is the date where the person is (this matcher's calendar); `calendar` is the field's own (release dates
    /// are UTC days), and the window is built there from the same year, month and day.
    private func inLastWindow(_ operands: [QueryValue], calendar dateCalendar: Calendar) -> (start: Date, end: Date)? {
        guard case .number(let count)? = operands.first, case .text(let unit)? = operands.dropFirst().first, count >= 1, count <= Double(QueryOperator.relativeCountLimit) else { return nil }
        let component: Calendar.Component
        switch unit {
        case "days": component = .day
        case "weeks": component = .weekOfYear
        case "months": component = .month
        case "years": component = .year
        default: return nil
        }
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        guard let todayHere = dateCalendar.date(from: today),
              let back = dateCalendar.date(byAdding: component, value: -Int(count), to: todayHere) else { return nil }
        return (dayAfter(back, calendar: dateCalendar), dayAfter(todayHere, calendar: dateCalendar))
    }

    private func weekdays(_ operands: [QueryValue]) -> Set<Int>? {
        let days = operands.compactMap { operand -> Int? in
            if case .text(let name) = operand { return Self.weekdayIndex(of: name) } else { return nil }
        }
        return days.isEmpty ? nil : Set(days)
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
