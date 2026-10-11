import SwiftUI

/// A small button showing a field's date scope ("Last 7 days, 1 year earlier", or "Default" when it
/// just follows the query's period) that opens the scope editor.
struct QueryScopeButton: View {
    @Binding var scope: QueryScope?
    /// "Now" for previews — the query's own `asOf`, or the present.
    var asOf: Date = Date()
    var compact = false
    var symbol = "calendar"

    @State private var isEditing = false

    var body: some View {
        Group {
            if compact {
                Button { isEditing = true } label: {
                    Image(systemName: symbol).help("Date scope: \(scope?.label ?? "the query’s period")")
                }
                .buttonStyle(.borderless)
            } else {
                Button { isEditing = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: symbol)
                        Text(scope?.label ?? "Query period").lineLimit(1)
                    }
                }
                .buttonStyle(.bordered)
                .help(scope.map { "Date range: \($0.label). Click to change." } ?? "Uses the query’s own period. Click to give this field its own date range.")
            }
        }
        .controlSize(.small)
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            QueryScopeEditor(scope: $scope, asOf: asOf).padding(14).frame(width: 300)
        }
    }
}

/// Edits one scope: a preset, or a base period plus how far back to move it, with a live preview of
/// the exact dates it means right now.
struct QueryScopeEditor: View {
    @Binding var scope: QueryScope?
    let asOf: Date

    /// The base period choices, including "follow the query's period" (no scope at all).
    private enum Choice: String, CaseIterable, Identifiable {
        case queryPeriod, allTime, upToNow, trailing, calendar, absolute
        var id: String { rawValue }
        var title: String {
            switch self {
            case .queryPeriod: "Query period"
            case .allTime: "All time"
            case .upToNow: "Up to now"
            case .trailing: "Last N days"
            case .calendar: "Calendar period"
            case .absolute: "Fixed dates"
            }
        }
    }

    private static let presets: [(String, QueryScope?)] = [
        ("Query period (default)", nil),
        ("All time", .allTime),
        ("Last 7 days", .trailing(days: 7)),
        ("Last 30 days", .trailing(days: 30)),
        ("This month", .calendar(.month)),
        ("This year", .calendar(.year)),
        ("Last month", QueryScope.calendar(.month).shifted(back: 1, .month)),
        ("Last year", QueryScope.calendar(.year).shifted(back: 1, .year)),
        ("Same 7 days last year", QueryScope.trailing(days: 7).shifted(back: 1, .year)),
        ("Same month last year", QueryScope.calendar(.month).shifted(back: 1, .year)),
        ("Up to a year ago", QueryScope.upToNow.shifted(back: 1, .year)),
    ]

    private var choice: Choice {
        guard let scope else { return .queryPeriod }
        return switch scope.kind {
        case .allTime: .allTime
        case .upToNow: .upToNow
        case .trailing: .trailing
        case .calendar: .calendar
        case .absolute: .absolute
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Date scope").font(AppTypography.sectionTitle)
            Menu("Presets") {
                ForEach(Array(Self.presets.enumerated()), id: \.offset) { _, preset in
                    Button(preset.0) { scope = preset.1 }
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Choose a commonly used date scope.")

            Picker("Period", selection: Binding(get: { choice }, set: choose)) {
                ForEach(Choice.allCases) { Text($0.title).tag($0) }
            }
            .help("Choose how this field’s date range is defined.")

            if let current = scope {
                switch current.kind {
                case .trailing:
                    Stepper(value: Binding(get: { current.days ?? 7 }, set: { new in update { $0.days = max(1, new) } }), in: 1...3650) {
                        Text("Days: \(current.days ?? 7)")
                    }
                    .help("Set the number of trailing days included in this field’s date range.")
                case .calendar:
                    Picker("Unit", selection: Binding(get: { current.unit ?? .month }, set: { new in update { $0.unit = new } })) {
                        ForEach(QueryScope.Unit.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .help("Choose whether the scope covers the current day, week, month, or year.")
                case .absolute:
                    optionalDate("From", current.from) { value in update { $0.from = value } }
                    optionalDate("To", current.to) { value in update { $0.to = value } }
                case .allTime, .upToNow:
                    EmptyView()
                }

                if current.canShift {
                    Divider()
                    HStack {
                        Stepper(value: Binding(get: { current.shiftCount }, set: { new in update { $0.shiftCount = max(0, new) } }), in: 0...200) {
                            Text("Move back \(current.shiftCount)")
                        }
                        .help("Move the selected date range backward for historical comparisons.")
                        Picker("", selection: Binding(get: { current.shiftUnit }, set: { new in update { $0.shiftUnit = new } })) {
                            ForEach(QueryScope.Unit.allCases, id: \.self) { Text($0.rawValue + (current.shiftCount == 1 ? "" : "s")).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        .help("Choose the unit used to move the date range backward.")
                    }
                }
            }

            Divider()
            preview
        }
        .font(AppTypography.metadata)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(scope?.label ?? "Follows the query’s own period").fontWeight(.medium)
            if let scope, let range = try? scope.resolve(asOf: asOf, calendar: .current) {
                Text(Self.describe(range)).foregroundStyle(.secondary)
            } else if scope != nil {
                Text("These settings aren’t valid yet.").foregroundStyle(.red)
            }
        }
    }

    private static func describe(_ range: ResolvedScope) -> String {
        let f = { (d: Date) in d.formatted(date: .abbreviated, time: .omitted) }
        switch (range.from, range.to) {
        case (let a?, let b?): return "\(f(a)) – \(f(b))"
        case (nil, let b?): return "Everything up to \(f(b))"
        case (let a?, nil): return "Everything from \(f(a))"
        case (nil, nil): return "Every scrobble"
        }
    }

    private func optionalDate(_ label: String, _ value: Date?, set: @escaping (Date?) -> Void) -> some View {
        HStack {
            Toggle(label, isOn: Binding(get: { value != nil }, set: { on in set(on ? (value ?? asOf) : nil) }))
                .help("Include a \(label.lowercased()) boundary in the fixed date range.")
            if let value {
                DatePicker("", selection: Binding(get: { value }, set: { set($0) }), displayedComponents: .date).labelsHidden()
                    .help("Choose the \(label.lowercased()) date for the fixed range.")
            }
        }
    }

    /// Changes the base period, keeping the "move back" shift when the new period can take one.
    private func choose(_ new: Choice) {
        let shift = scope.map { ($0.shiftCount, $0.shiftUnit) } ?? (0, .year)
        var next: QueryScope?
        switch new {
        case .queryPeriod: next = nil
        case .allTime: next = .allTime
        case .upToNow: next = .upToNow
        case .trailing: next = .trailing(days: scope?.days ?? 7)
        case .calendar: next = .calendar(scope?.unit ?? .month)
        case .absolute: next = .absolute(from: scope?.from ?? asOf.addingTimeInterval(-30 * 86400), to: scope?.to ?? asOf)
        }
        if var n = next, n.canShift { n.shiftCount = shift.0; n.shiftUnit = shift.1; next = n }
        scope = next
    }

    private func update(_ change: (inout QueryScope) -> Void) {
        guard var current = scope else { return }
        change(&current)
        scope = current
    }
}

/// A field's setting (its window in days, how ties are broken…) as a compact pull-down — the same options
/// the condition editor offers, for use beside a sort or a column.
struct QueryParameterMenu: View {
    let parameter: QueryFieldParameter
    @Binding var selection: QueryValue
    var fieldHelp: String = ""

    var body: some View {
        Menu {
            ForEach(parameter.options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    if option == selection { Label(parameter.display(option), systemImage: "checkmark") } else { Text(parameter.display(option)) }
                }
            }
        } label: {
            Text("\(parameter.label): \(parameter.display(selection))").lineLimit(1)
        }
        .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
        .help(parameter.help.isEmpty ? fieldHelp : parameter.help)
    }
}
