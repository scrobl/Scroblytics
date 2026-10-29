import SwiftUI
import SwiftData
import Charts

/// "Goals": set a date by which to hear every loved track at least once, and watch a burn-down chart of what's left, with forecasts for
/// how that is likely to go if you keep listening as you do, shuffle your favorites, or put aside listening for the ones you haven't heard.
struct GoalsView: View {
    let modelContainer: ModelContainer
    let navigation: DetailNavigationCoordinator
    /// A ready-made goal and its numbers, shown as they are (layout snapshots); nothing is read or saved.
    var preview: (goal: ListeningGoal, result: GoalResult)?
    /// Ready-made goals and their numbers for the landing page (layout snapshots).
    var landingPreview: [(goal: ListeningGoal, analysis: GoalAnalysis)]?

    private static let toolId = "goals"
    private static let firstRows = 40

    @Environment(\.modelContext) private var modelContext
    @State private var state = GoalsState()
    @State private var hasLoadedState = false
    @State private var result: GoalResult?
    @State private var resultGoalID: UUID?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var editor: GoalEditorRequest?
    @State private var deleting: ListeningGoal?
    /// The goal whose details are open; nil is the landing page with every goal.
    @State private var openGoalID: UUID?
    @State private var summaries: [UUID: GoalAnalysis] = [:]
    @State private var hidden: Set<GoalSeries> = []
    @State private var hoveredDate: Date?
    @State private var showAllRemaining = false
    @State private var showSetAside = false
    @State private var remainingSearch = ""
    @State private var remainingFilter: GoalRemainingFilter = .all
    @AppStorage("goals.remaining.sort") private var remainingSortRaw = GoalRemainingSort.recentlyLoved.rawValue
    @State private var imageLookup: [String: String] = [:]
    @State private var reloadTask: Task<Void, Never>?
    @AppStorage("goals.chart.range") private var chartRangeRaw = GoalChartRange.whole.rawValue

    private var calendar: Calendar { AppCalendars.listening }
    /// The goal whose details are showing, if any.
    private var selectedGoal: ListeningGoal? {
        openGoalID.flatMap { id in state.goals.first { $0.id == id } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageSettingsHeader("Goals") { header }
                if let goal = selectedGoal {
                    if let result, resultGoalID == goal.id {
                        content(goal: goal, result: result)
                    } else if let errorMessage {
                        ContentUnavailableView("Couldn't load", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                            .frame(maxWidth: .infinity, minHeight: 240)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 240)
                    }
                } else if hasLoadedState {
                    landing
                }
            }
            .padding(16)
        }
        .navigationTitle("Goals")
        .sheet(item: $editor) { request in
            GoalEditor(request: request, calendar: calendar) { saved in
                if let index = state.goals.firstIndex(where: { $0.id == saved.id }) { state.goals[index] = saved } else { state.goals.append(saved) }
            }
        }
        .confirmationDialog(
            "Delete this goal?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting
        ) { goal in
            Button("Delete “\(goal.title)”", role: .destructive) {
                state.goals.removeAll { $0.id == goal.id }
                summaries[goal.id] = nil
                if openGoalID == goal.id { openGoalID = nil; result = nil }
            }
        } message: { _ in
            Text("Only the goal is removed. Your listening history and loved tracks are not touched.")
        }
        .task {
            if let landingPreview {
                state = GoalsState(goals: landingPreview.map(\.goal), selected: nil)
                summaries = Dictionary(uniqueKeysWithValues: landingPreview.map { ($0.goal.id, $0.analysis) })
                hasLoadedState = true
                return
            }
            if let preview {
                state = GoalsState(goals: [preview.goal], selected: preview.goal.id)
                openGoalID = preview.goal.id
                result = preview.result
                resultGoalID = preview.goal.id
                hasLoadedState = true
                return
            }
            state = ToolFilterSettingsStore.load(GoalsState.self, toolId: Self.toolId, context: modelContext, default: GoalsState())
            hasLoadedState = true
            imageLookup = (try? ImageResolutionEngine.imageLookup(context: modelContext)) ?? [:]
            scheduleReload()
        }
        .onChange(of: state) { _, newValue in
            guard hasLoadedState, preview == nil, landingPreview == nil else { return }
            ToolFilterSettingsStore.save(newValue, toolId: Self.toolId, context: modelContext)
        }
        .onChange(of: state.goals) { _, _ in scheduleReload(after: .milliseconds(300)) }
        .onChange(of: openGoalID) { _, _ in scheduleReload() }
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in scheduleReload() }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { headerControls }
            VStack(alignment: .leading, spacing: 10) { headerControls }
        }
    }

    @ViewBuilder
    private var headerControls: some View {
        if let goal = selectedGoal {
            Button { openGoalID = nil } label: { Label("Goals", systemImage: "chevron.left") }
                .help("Back to all goals")
            Text(goal.title).font(AppTypography.sectionTitle)
            Text("\(Self.dayLabel(goal.start)) – \(Self.dayLabel(goal.deadline))")
                .font(AppTypography.metadata).foregroundStyle(.secondary)
            if !goal.criteria.isLovedOnly {
                Text(goal.criteria.summary).font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        if isLoading { ProgressView().controlSize(.small) }
        if let goal = selectedGoal {
            Spacer(minLength: 0)
            ShareButton(card: { shareCard(for: goal) }, isEnabled: result != nil && resultGoalID == goal.id)
            Button { scheduleReload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Work the numbers out again from your latest history and loved tracks")
                .disabled(isLoading)
            Button("Edit…") { editor = .edit(goal) }
            Button("Delete…", role: .destructive) { deleting = goal }
        } else {
            Text(state.goals.isEmpty ? "Hear a set of tracks by a date." : "Open a goal for its chart, forecasts and the tracks still to hear.")
                .font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
            Button("New Goal…") { editor = .new }
        }
    }

    // MARK: - Landing

    @ViewBuilder
    private var landing: some View {
        if state.goals.isEmpty {
            ContentUnavailableView {
                Label("Set a goal", systemImage: "target")
            } description: {
                Text("Pick a date by which to hear every loved track, or every track by an artist or with a tag, at least once. You'll get a chart of what's left and forecasts for how it's likely to go.")
            } actions: {
                Button("New Goal…") { editor = .new }.buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, minHeight: 280)
        } else {
            if let errorMessage, summaries.isEmpty {
                Text("Couldn't work out your goals: \(errorMessage)").font(AppTypography.metadata).foregroundStyle(.orange)
            }
            let sections = GoalSections.split(goals: state.goals, analyses: summaries)
            VStack(alignment: .leading, spacing: 22) {
                goalSection("Active", goals: sections.active, empty: "No active goals. New Goal… starts one.")
                goalSection("Completed", goals: sections.completed, empty: "Nothing yet: goals you achieve, or whose deadline passes, move here.")
            }
            .opacity(isLoading ? 0.6 : 1)
        }
    }

    private func goalSection(_ title: String, goals: [ListeningGoal], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(title.uppercased()) (\(goals.count.formatted()))")
                .font(AppTypography.supporting.weight(.medium))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            if goals.isEmpty {
                Text(empty).font(AppTypography.supporting).foregroundStyle(.tertiary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340, maximum: 460), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                    ForEach(goals) { goal in
                        GoalCard(
                            goal: goal, analysis: summaries[goal.id],
                            shareCard: { summaries[goal.id].flatMap { GoalShareCards.card(goal: goal, analysis: $0, result: nil) } },
                            onOpen: { openGoalID = goal.id }, onEdit: { editor = .edit(goal) }, onDelete: { deleting = goal }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(goal: ListeningGoal, result: GoalResult) -> some View {
        let analysis = result.analysis
        if analysis.membersNow == 0 {
            ContentUnavailableView(
                goal.criteria.isLovedOnly ? "No loved tracks yet" : "No tracks match", systemImage: goal.criteria.isLovedOnly ? "heart" : "line.3.horizontal.decrease",
                description: Text(goal.criteria.isLovedOnly
                    ? "A goal counts the tracks you've loved on Last.fm. Love some, or sync if you've loved some recently, and they'll appear here."
                    : "None of the tracks in your history match this goal's criteria\(result.pendingTags > 0 ? ", and \(result.pendingTags.formatted()) can't be checked until their tags are looked up" : ""). Edit the goal to change them.")
            )
            .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            Group {
                summary(goal: goal, result: result)
                chartCard(goal: goal, result: result)
                if !result.forecasts.isEmpty { scenarioCard(goal: goal, result: result) }
            }
            .opacity(isLoading ? 0.45 : 1)
            assumptionsCard(goal: goal, result: result)
            if !goal.setAside.isEmpty { setAsideCard(goal: goal) }
            remainingCard(goal: goal, result: result)
                .opacity(isLoading ? 0.45 : 1)
        }
    }

    private func summary(goal: ListeningGoal, result: GoalResult) -> some View {
        let a = result.analysis
        return VStack(alignment: .leading, spacing: 10) {
            if let completed = a.completedIndex {
                ToolHeadlineCard("Done") {
                    Text("You've heard all \(a.membersNow.formatted()) \(goal.criteria.noun). The last one on \(Self.dayLabel(date(a.startDay, plus: completed))).")
                }
            } else if a.daysUntilStart > 0 {
                ToolHeadlineCard("Not started yet") {
                    Text("Starts \(Self.dayLabel(goal.start)), in \(a.daysUntilStart.formatted()) \(a.daysUntilStart == 1 ? "day" : "days"). Plays before then don't count, so this shows the goal as it will begin, with the \(a.membersNow.formatted()) \(a.joinsOnPlay ? "tracks that match so far" : "tracks you've loved so far")\(result.leadLoves > 0 ? " and about \(result.leadLoves.formatted()) more you're expected to love before then" : "").")
                }
            } else if a.daysLeft == 0 && a.todayIndex >= a.deadlineIndex {
                ToolHeadlineCard("Deadline reached") {
                    Text("\(a.heardNow.formatted()) of \(a.membersNow.formatted()) \(goal.criteria.noun) heard by \(Self.dayLabel(goal.deadline)); \(a.remainingNow.formatted()) not.")
                }
            }
            HStack(spacing: 12) {
                stat("Heard", a.heardNow.formatted(), detail: "of \(a.membersNow.formatted()) \(goal.criteria.loved == .loved ? "loved" : "tracks")")
                stat("To hear", a.remainingNow.formatted(), detail: percentLabel(a.heardNow, a.membersNow) + " done")
                if a.daysUntilStart > 0 {
                    stat("Starts in", a.daysUntilStart.formatted(), detail: a.daysUntilStart == 1 ? "day" : "days")
                } else {
                    stat("Days left", a.completedIndex != nil ? "—" : (a.todayIndex >= a.deadlineIndex ? "0" : (a.daysLeft + 1).formatted()), detail: a.completedIndex != nil ? "goal complete" : "today counts")
                }
                stat("Needed", a.remainingNow == 0 ? "—" : String(format: "%.1f", a.requiredPerDay), detail: "a day, if none repeat")
            }
        }
    }

    private func stat(_ title: String, _ value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(AppTypography.statLabel).foregroundStyle(.secondary)
            Text(value).font(AppTypography.statValue)
            Text(detail).font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.4), lineWidth: 1) }
    }

    // MARK: - Chart

    private func chartCard(goal: ListeningGoal, result: GoalResult) -> some View {
        let a = result.analysis
        let today = date(a.startDay, plus: a.todayIndex)
        let deadlineDay = date(a.startDay, plus: a.deadlineIndex)
        let shownSeries = GoalSeries.allCases.filter { series in
            !hidden.contains(series) && series.isAvailable(in: result)
        }
        let range = GoalChartRange(rawValue: chartRangeRaw) ?? .whole
        let visibleFrom = range.firstDay(todayIndex: a.todayIndex)
        let actualFrom = min(visibleFrom, a.actual.count - 1)
        let planFrom = min(visibleFrom, a.plan.count - 1)
        let yMax = max(1.0, Double(a.actual[actualFrom...].max() ?? 1), a.plan[planFrom...].max() ?? 1,
                       result.forecasts.values.compactMap { $0.high.max() }.max() ?? 0) * 1.06
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Tracks still to hear").font(AppTypography.sectionTitle)
                Picker("Zoom", selection: $chartRangeRaw) {
                    ForEach(GoalChartRange.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .labelsHidden().fixedSize()
                .help("Zoom the chart to the recent past and the days ahead; the scale follows.")
                Spacer()
                ForEach(GoalSeries.allCases.filter { $0.isAvailable(in: result) }) { series in
                    Button {
                        if hidden.contains(series) { hidden.remove(series) } else { hidden.insert(series) }
                    } label: {
                        HStack(spacing: 5) {
                            Circle().fill(series.color).frame(width: 8, height: 8)
                            Text(series.label).font(AppTypography.compactMetadata)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(hidden.contains(series) ? Color.clear : series.color.opacity(0.14), in: Capsule())
                        .overlay { Capsule().stroke(series.color.opacity(hidden.contains(series) ? 0.25 : 0.6), lineWidth: 1) }
                        .opacity(hidden.contains(series) ? 0.55 : 1)
                    }
                    .buttonStyle(.plain)
                    .help(series.help)
                }
            }
            Chart {
                ForEach(shownSeries.filter { $0.kind != nil }) { series in
                    if let forecast = result.forecasts[series.kind!] {
                        ForEach(0..<forecast.median.count, id: \.self) { offset in
                            let x = date(today, plus: offset)
                            AreaMark(x: .value("Date", x), yStart: .value("Low", forecast.low[offset]), yEnd: .value("High", forecast.high[offset]), series: .value("Band", series.label))
                                .foregroundStyle(series.color.opacity(0.13))
                        }
                    }
                }
                if shownSeries.contains(.plan) {
                    ForEach(planFrom..<a.plan.count, id: \.self) { d in
                        LineMark(x: .value("Date", date(a.startDay, plus: d)), y: .value("Tracks", a.plan[d]), series: .value("Series", GoalSeries.plan.label))
                            .foregroundStyle(GoalSeries.plan.color)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    }
                }
                ForEach(shownSeries.filter { $0.kind != nil }) { series in
                    if let forecast = result.forecasts[series.kind!] {
                        ForEach(0..<forecast.median.count, id: \.self) { offset in
                            LineMark(x: .value("Date", date(today, plus: offset)), y: .value("Tracks", forecast.median[offset]), series: .value("Series", series.label))
                                .foregroundStyle(series.color)
                                .lineStyle(StrokeStyle(lineWidth: 2))
                        }
                    }
                }
                if shownSeries.contains(.actual) {
                    ForEach(actualFrom..<a.actual.count, id: \.self) { d in
                        LineMark(x: .value("Date", date(a.startDay, plus: d)), y: .value("Tracks", a.actual[d]), series: .value("Series", GoalSeries.actual.label))
                            .foregroundStyle(GoalSeries.actual.color)
                            .lineStyle(StrokeStyle(lineWidth: 3))
                            .interpolationMethod(.stepEnd)
                    }
                }
                RuleMark(x: .value("Today", today))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) { Text(a.daysUntilStart > 0 ? "Start" : "Today").font(AppTypography.supportingDense).foregroundStyle(.secondary) }
                RuleMark(x: .value("Deadline", deadlineDay))
                    .foregroundStyle(.red.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) { Text("Deadline").font(AppTypography.supportingDense).foregroundStyle(.red) }
                if let hoveredDate {
                    RuleMark(x: .value("Hover", hoveredDate)).foregroundStyle(.primary.opacity(0.35))
                }
            }
            .padding(.top, 16)
            .chartYScale(domain: 0...yMax)
            .chartXScale(domain: date(a.startDay, plus: visibleFrom)...max(deadlineDay, today).addingTimeInterval(86_400))
            .chartXSelection(value: $hoveredDate)
            .frame(height: 320)
            Text(hoverLine(result: result, goal: goal))
                .font(AppTypography.metadata.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 18)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.4), lineWidth: 1) }
    }

    private func hoverLine(result: GoalResult, goal: ListeningGoal) -> String {
        let a = result.analysis
        guard let hoveredDate else {
            return result.forecasts.isEmpty ? "" : "Lines are the middle estimate; the shaded band holds four runs in five. Hover the chart for numbers."
        }
        let d = max(0, calendar.dateComponents([.day], from: a.startDay, to: calendar.startOfDay(for: hoveredDate)).day ?? 0)
        var parts = [Self.dayLabel(hoveredDate)]
        if d < a.actual.count { parts.append("\(a.actual[d].formatted()) to hear") }
        if d < a.plan.count { parts.append("on target \(Int(a.plan[d].rounded()).formatted())") }
        let offset = d - a.todayIndex
        if offset >= 0 {
            for kind in GoalScenarioKind.allCases {
                if let f = result.forecasts[kind], offset < f.median.count {
                    parts.append("\(kind.label.lowercased()) ~\(Int(f.median[offset].rounded()).formatted()) (\(Int(f.low[offset].rounded()))–\(Int(f.high[offset].rounded())))")
                }
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Scenarios

    private func scenarioCard(goal: ListeningGoal, result: GoalResult) -> some View {
        let a = result.analysis
        let today = date(a.startDay, plus: a.todayIndex)
        return VStack(alignment: .leading, spacing: 10) {
            Text("If things go on like this").font(AppTypography.sectionTitle)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    ForEach(["Done by (middle estimate)", "Chance by the deadline", "Half the rest by", "Nine tenths of the rest by"], id: \.self) {
                        Text($0).font(AppTypography.statLabel).foregroundStyle(.secondary)
                    }
                }
                ForEach(GoalScenarioKind.allCases) { kind in
                    if let f = result.forecasts[kind] {
                        GridRow(alignment: .firstTextBaseline) {
                            HStack(spacing: 6) {
                                Circle().fill(GoalSeries(kind: kind).color).frame(width: 9, height: 9)
                                Text(kind.label).font(AppTypography.contentTitle)
                                if kind != .dedicated, result.dedicatedPerDay > 0 {
                                    Text("+ \(String(format: "%.1f", result.dedicatedPerDay)) a day to unheard").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                                }
                            }
                            .help(kind.explanation)
                            Text(finishText(f.finishMedian, horizon: f.horizon, today: today, deadline: a.deadlineIndex - a.todayIndex))
                            Text("\(Int((f.chanceByDeadline * 100).rounded()))%")
                                .foregroundStyle(f.chanceByDeadline >= 0.9 ? Color.green : (f.chanceByDeadline >= 0.5 ? Color.orange : Color.red))
                            Text(f.halfMedian.map { Self.dayLabel(date(today, plus: $0)) } ?? "—")
                            Text(f.ninetyMedian.map { Self.dayLabel(date(today, plus: $0)) } ?? "—")
                        }
                        .font(AppTypography.tableValue)
                    }
                }
            }
            if let shuffle = result.forecasts[.shuffle], let habits = result.forecasts[.habits] {
                Text(tailNote(shuffle: shuffle, habits: habits, analysis: a))
                    .font(AppTypography.metadata).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.4), lineWidth: 1) }
    }

    private func finishText(_ offset: Int?, horizon: Int, today: Date, deadline: Int) -> String {
        guard let offset else { return "not within \(max(horizon / 30, 1)) months" }
        let label = Self.dayLabel(date(today, plus: offset))
        return offset > deadline ? "\(label) (late)" : label
    }

    /// Spells out the pool-shrinking effect in the person's own numbers.
    private func tailNote(shuffle: GoalForecast, habits: GoalForecast, analysis a: GoalAnalysis) -> String {
        guard let half = shuffle.halfMedian, let nine = shuffle.ninetyMedian else {
            return "Each loved track you play is one fewer to find, so a random pick lands on a new one less and less often: the last few take the longest."
        }
        let tenthDays = max(nine - half, 0)
        return "Picking loved tracks at random, half of what's left is heard in about \(half.formatted()) days, nine tenths in about \(nine.formatted()). Each play makes a new one less likely, so the last tenth alone takes about \(tenthDays.formatted()) more days."
    }

    // MARK: - Assumptions

    private func assumptionsCard(goal: ListeningGoal, result: GoalResult) -> some View {
        let h = result.analysis.habits
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Assumptions").font(AppTypography.sectionTitle)
                if isLoading {
                    ProgressView().controlSize(.small)
                    Text("Recalculating…").font(AppTypography.metadata).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Text("Learn from the last")
                Picker("Lookback", selection: binding(\.lookbackDays)) {
                    ForEach(GoalEngine.lookbackChoices, id: \.self) { Text("\($0) days").tag($0) }
                }
                .labelsHidden().fixedSize()
                Text("· about \(String(format: "%.0f", h.playsPerDay)) plays a day, \(String(format: "%.1f", h.lovedPlaysPerDay)) of them \(goal.criteria.isLovedOnly ? "loved tracks" : "in this goal")")
                    .foregroundStyle(.secondary)
            }
            .font(AppTypography.metadata)

            if result.forecasts[.dedicated] != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: Binding(
                        get: { goal.dedicatedShare != nil },
                        set: { on in update { $0.dedicatedShare = on ? min(max((result.neededPerDay ?? h.playsPerDay) / max(h.playsPerDay, 1), 0.02), 1) : nil } }
                    )) {
                        Text("Choose how much of my listening goes to tracks I haven't heard")
                    }
                    if let share = goal.dedicatedShare {
                        HStack {
                            Slider(value: Binding(get: { share }, set: { v in update { $0.dedicatedShare = v } }), in: 0...1, step: 0.01)
                                .frame(maxWidth: 260)
                            Text("\(Int((share * 100).rounded()))% · about \(String(format: "%.1f", result.dedicatedPerDay)) plays a day")
                                .font(AppTypography.metadata.monospacedDigit())
                        }
                    }
                    Text(goal.dedicatedShare != nil
                         ? "That many plays a day go to \(goal.criteria.noun) you haven't heard, on top of Your habits and Shuffle your favorites. Unplayed first is the extreme: every play, before anything else."
                         : "Off: Your habits and Shuffle your favorites show your listening as it is. Unplayed first shows every play going to a track you haven't heard.")
                        .font(AppTypography.metadata).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(neededText(result: result, goal: goal)).font(AppTypography.metadata).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                if result.pendingTags > 0 {
                    Text("\(result.pendingTags.formatted()) \(result.pendingTags == 1 ? "track hasn't" : "tracks haven't") had tags looked up yet, so the tag test can't say and \(result.pendingTags == 1 ? "it isn't" : "they aren't") counted. Tags are looked up in the background; Refresh once they have been.")
                        .font(AppTypography.metadata).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if !result.analysis.joinsOnPlay {
                    Toggle("Expect more loves before the deadline", isOn: binding(\.expectNewLoves))
                }
                if goal.expectNewLoves, !result.analysis.joinsOnPlay {
                    HStack(spacing: 8) {
                        Text("Loves a month:")
                        LovesPerMonthField(value: goal.lovesPerMonth) { v in update { $0.lovesPerMonth = v } }
                            .id(goal.id)
                        Text(lovesNote(h, goal: goal, result: result)).foregroundStyle(.secondary)
                    }
                    .font(AppTypography.metadata)
                }
                Toggle(goal.criteria.loved == .loved ? "Only count loved tracks that are in my Apple Music library" : "Only count tracks that are in my Apple Music library", isOn: binding(\.inAppleLibraryOnly))
                if goal.inAppleLibraryOnly {
                    Text(libraryNote(result)).font(AppTypography.metadata)
                        .foregroundStyle(result.libraryNeverChecked ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if result.analysis.bulkLoves > 0 {
                    Toggle(isOn: binding(\.countBulkLovesFromStart)) {
                        Text("Count loves added in bulk as loved from the start")
                    }
                    Text(bulkNote(result.analysis, goal: goal)).font(AppTypography.metadata).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !h.hasLoveDates, !result.analysis.joinsOnPlay {
                    Text("Last.fm dates your loves, but this Mac hasn't saved them yet. They arrive with your next sync; until then every loved track counts from the first day and new loves can't be estimated.")
                        .font(AppTypography.metadata).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.4), lineWidth: 1) }
    }

    private func neededText(result: GoalResult, goal: ListeningGoal) -> String {
        guard let needed = result.neededPerDay else {
            return "Even giving all of your listening to tracks you haven't heard wouldn't be certain to finish by the deadline."
        }
        if needed == 0 { return "Your habits alone are likely to get you there." }
        let share = result.analysis.habits.playsPerDay > 0 ? Int((needed / result.analysis.habits.playsPerDay * 100).rounded()) : 0
        let loves = goal.expectNewLoves && result.expectedLovesPerDay > 0 ? " That includes tracks you're expected to love before the deadline, which also need hearing." : ""
        return "To be \(Int(GoalSimulator.confidence * 100))% sure of finishing by the deadline, play about \(String(format: "%.1f", needed)) of these tracks you haven't heard each day (\(share)% of your listening)." + loves
    }

    private func libraryNote(_ result: GoalResult) -> String {
        if result.libraryNeverChecked {
            return "The library hasn't been checked yet, so nothing is left out. Run Check library in Library Gaps first."
        }
        let when = result.libraryCheckedAt.map { " (checked \(Self.dayLabel($0)))" } ?? ""
        let n = result.leftOutOfLibrary
        return n == 0
            ? "None of your loved tracks are known to be missing from the library\(when). A track that was never checked stays in."
            : "\(n.formatted()) loved \(n == 1 ? "track isn't" : "tracks aren't") in the library\(when) and \(n == 1 ? "is" : "are") left out, heard or not. A track that was never checked stays in. Run Check library in Library Gaps to refresh."
    }

    private func bulkNote(_ a: GoalAnalysis, goal: ListeningGoal) -> String {
        let days = a.bulkLoveDays.prefix(3).map { Self.dayLabel($0) }.joined(separator: ", ")
        let more = a.bulkLoveDays.count > 3 ? " and \(a.bulkLoveDays.count - 3) more" : ""
        let what = "\(a.bulkLoves.formatted()) of your loves are dated \(days)\(more), \(Int(GoalEngine.bulkLoveDayThreshold)) or more on a day, which looks like an import or a sync of favorites rather than loving tracks one by one."
        return what + (goal.countBulkLovesFromStart
            ? " They count as loved from the first day, so they don't show up as a jump in what's left. Turn this off to count them from the day they are dated."
            : " They count from the day they are dated, so they appear as a jump in what's left that day.")
    }

    private func lovesNote(_ h: GoalHabits, goal: ListeningGoal, result: GoalResult) -> String {
        guard h.hasLoveDates else { return "" }
        let perMonth = h.newLovesPerDay * 30.4375
        return String(format: "you've been loving about %.1f a month; %.0f%% of them weren't played just before", perMonth, (1 - h.unplayedShareOfLoves) * 100)
    }

    // MARK: - Remaining

    private func remainingCard(goal: ListeningGoal, result: GoalResult) -> some View {
        let a = result.analysis
        let sort = GoalRemainingSort(rawValue: remainingSortRaw) ?? .recentlyLoved
        let matching = GoalRemainingList.apply(a.remaining, history: result.history, filter: remainingFilter, sort: sort, search: remainingSearch)
        let rows = showAllRemaining ? matching : Array(matching.prefix(Self.firstRows))
        let narrowed = matching.count != a.remaining.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Still to hear").font(AppTypography.sectionTitle)
                Text(narrowed ? "\(matching.count.formatted()) of \(a.remaining.count.formatted())" : a.remaining.count.formatted())
                    .font(AppTypography.metadata.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
            }
            if !a.remaining.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { remainingControls(joinsOnPlay: a.joinsOnPlay) }
                    VStack(alignment: .leading, spacing: 8) { remainingControls(joinsOnPlay: a.joinsOnPlay) }
                }
            }
            if a.remaining.isEmpty {
                Text("Nothing left to hear.").font(AppTypography.metadata).foregroundStyle(.secondary)
            } else if rows.isEmpty {
                Text("No tracks match.").font(AppTypography.metadata).foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.key) { love in
                        let info = result.history[love.key]
                        let url = ImageResolutionEngine.effectiveImageURL(
                            for: ImageTarget(kind: .track, artist: love.artist, album: info?.album, track: love.track), lookup: imageLookup, fallbackURL: info?.imageURL
                        ) ?? ImageResolutionEngine.effectiveImageURL(for: ImageTarget(kind: .artist, artist: love.artist, album: nil, track: nil), lookup: imageLookup)
                        HStack(spacing: 4) {
                            Button {
                                navigation.goToTrack(TrackIdentity(artist: love.artist, name: love.track, album: info?.album, imageURL: url))
                            } label: {
                                HStack(spacing: 12) {
                                    EntityThumbnail(url: url, entity: .track)
                                        .frame(width: AppArtworkSizing.thumbnail, height: AppArtworkSizing.thumbnail)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(love.track).font(AppTypography.contentTitle).lineLimit(1)
                                        Text(love.artist).font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    VStack(alignment: .trailing, spacing: 2) {
                                        if let lovedAt = love.lovedAt {
                                            Text("\(result.analysis.joinsOnPlay ? "first played" : "loved") \(Self.dayLabel(lovedAt))")
                                        }
                                        Text(Self.playedLabel(info))
                                    }
                                    .font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .padding(.vertical, 8).padding(.horizontal, 4)
                                .contentShape(Rectangle())
                            }
                            .drillDownHighlight()
                            Button { setAside(love, in: goal) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                                .help("Set aside from this goal: it stops counting, heard or not. You can put it back below.")
                        }
                        .contextMenu {
                            Button("Set Aside from This Goal") { setAside(love, in: goal) }
                        }
                        Divider()
                    }
                }
                if matching.count > Self.firstRows {
                    Button(showAllRemaining ? "Show Fewer" : "Show All \(matching.count.formatted())") { showAllRemaining.toggle() }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.4), lineWidth: 1) }
    }

    @ViewBuilder
    private func remainingControls(joinsOnPlay: Bool) -> some View {
        TextField("Search", text: $remainingSearch)
            .textFieldStyle(.roundedBorder).frame(minWidth: 120, maxWidth: 200)
        Picker("Show", selection: $remainingFilter) {
            ForEach(GoalRemainingFilter.allCases) { Text($0.label).tag($0) }
        }
        .labelsHidden().fixedSize()
        .help("Show every track, only those you've played before, or only those with no plays at all")
        Picker("Sort", selection: $remainingSortRaw) {
            ForEach(GoalRemainingSort.allCases) { Text($0.label(joinsOnPlay: joinsOnPlay)).tag($0.rawValue) }
        }
        .labelsHidden().fixedSize()
        .help("Order the list")
    }

    private static func playedLabel(_ info: GoalTrackHistory?) -> String {
        guard let info, info.plays > 0 else { return "no plays" }
        let plays = info.plays == 1 ? "1 play" : "\(info.plays.formatted()) plays"
        guard let last = info.lastPlayed else { return plays }
        return "\(plays) · last \(dayLabel(last))"
    }

    // MARK: - Share

    /// The open goal as a card: the chart as the page has it, with its forecasts.
    private func shareCard(for goal: ListeningGoal) -> ShareCard? {
        guard let result, resultGoalID == goal.id else { return nil }
        return GoalShareCards.card(goal: goal, analysis: result.analysis, result: result)
    }

    // MARK: - Set aside

    private func setAside(_ love: GoalLove, in goal: ListeningGoal) {
        update { goal in
            guard !goal.setAside.contains(where: { $0.key == love.key }) else { return }
            goal.setAside.append(GoalSetAside(key: love.key, artist: love.artist, track: love.track))
        }
    }

    private func setAsideCard(goal: ListeningGoal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showSetAside.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(showSetAside ? 90 : 0)).foregroundStyle(.secondary).imageScale(.small)
                    Text("Set aside").font(AppTypography.sectionTitle)
                    Text(goal.setAside.count.formatted()).font(AppTypography.metadata.monospacedDigit()).foregroundStyle(.secondary)
                    Text("not counted in this goal").font(AppTypography.metadata).foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showSetAside {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(goal.setAside) { item in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.track).font(AppTypography.contentTitle).lineLimit(1)
                                Text(item.artist).font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Button("Put Back") { update { $0.setAside.removeAll { $0.key == item.key } } }
                                .help("Count this track in the goal again")
                        }
                        .padding(.vertical, 6)
                        Divider()
                    }
                    if goal.setAside.count > 1 {
                        Button("Put All Back") { update { $0.setAside = [] } }.buttonStyle(.bordered).padding(.top, 8)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.4), lineWidth: 1) }
    }

    // MARK: - Loading

    /// Starts a recalculation; a change made while one is waiting or running replaces it. Settings changed in quick succession
    /// (a slider drag, typing a number) wait `delay` so only the last one is worked out.
    private func scheduleReload(after delay: Duration = .zero) {
        guard preview == nil, landingPreview == nil else { return }
        reloadTask?.cancel()
        isLoading = true
        reloadTask = Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            if Task.isCancelled { return }
            await reload()
        }
    }

    private func reload() async {
        // A replaced run leaves the busy state to the one that replaced it.
        defer { if !Task.isCancelled { isLoading = false } }
        guard let goal = selectedGoal else { await reloadSummaries(); return }
        errorMessage = nil
        do {
            let stored = try modelContext.fetch(FetchDescriptor<LovedTrackEntry>())
            let loves = stored.map { GoalLove(key: $0.cacheKey, artist: $0.artist, track: $0.track, lovedAt: $0.lovedAt) }
            let plays = try await ScrobbleHistoryCache.shared.snapshots(container: modelContainer)
            let presence = goal.inAppleLibraryOnly ? LibraryPresenceSnapshot.load(context: modelContext) : nil
            let tags = goal.criteria.tags.isEmpty ? EntityTagsSnapshot.empty : EntityTagsEngine.loadSnapshot(context: modelContext)
            let calendar = self.calendar
            let computed = await Task.detached(priority: .userInitiated) {
                let members = GoalMembership.members(for: [goal], loved: loves, plays: plays, tags: tags)[goal.id] ?? GoalMembers(loves: [])
                return GoalCompute.run(goal: goal, members: members, plays: plays, presence: presence, now: .now, calendar: calendar)
            }.value
            if Task.isCancelled { return }
            result = computed
            resultGoalID = goal.id
        } catch {
            if !Task.isCancelled { errorMessage = "\(error)" }
        }
    }

    /// The numbers behind every goal's card: the burn-down only, so a page of several goals stays quick.
    private func reloadSummaries() async {
        let goals = state.goals
        guard !goals.isEmpty else { summaries = [:]; return }
        do {
            let stored = try modelContext.fetch(FetchDescriptor<LovedTrackEntry>())
            let loves = stored.map { GoalLove(key: $0.cacheKey, artist: $0.artist, track: $0.track, lovedAt: $0.lovedAt) }
            let plays = try await ScrobbleHistoryCache.shared.snapshots(container: modelContainer)
            let presence = goals.contains { $0.inAppleLibraryOnly } ? LibraryPresenceSnapshot.load(context: modelContext) : nil
            let tags = goals.contains { !$0.criteria.tags.isEmpty } ? EntityTagsEngine.loadSnapshot(context: modelContext) : EntityTagsSnapshot.empty
            let calendar = self.calendar
            let computed = await Task.detached(priority: .userInitiated) {
                let members = GoalMembership.members(for: goals, loved: loves, plays: plays, tags: tags)
                return Dictionary(uniqueKeysWithValues: goals.map { goal in
                    (goal.id, GoalCompute.analysis(goal: goal, members: members[goal.id] ?? GoalMembers(loves: []), plays: plays, presence: presence, now: .now, calendar: calendar))
                })
            }.value
            if Task.isCancelled { return }
            summaries = computed
        } catch {
            if !Task.isCancelled { errorMessage = "\(error)" }
        }
    }

    // MARK: - Helpers

    /// A setting of the chosen goal, changed in place.
    private func binding<Value>(_ keyPath: WritableKeyPath<ListeningGoal, Value>) -> Binding<Value> {
        Binding(
            get: { selectedGoal![keyPath: keyPath] },
            set: { value in update { $0[keyPath: keyPath] = value } }
        )
    }

    private func update(_ change: (inout ListeningGoal) -> Void) {
        guard let goal = selectedGoal, let index = state.goals.firstIndex(where: { $0.id == goal.id }) else { return }
        change(&state.goals[index])
    }

    private func date(_ base: Date, plus days: Int) -> Date {
        calendar.date(byAdding: .day, value: days, to: base) ?? base
    }

    private func percentLabel(_ part: Int, _ whole: Int) -> String {
        whole > 0 ? "\(Int((Double(part) / Double(whole) * 100).rounded()))%" : "0%"
    }

    static func dayLabel(_ date: Date) -> String {
        let sameYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
        return date.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }
}

/// Names as removable chips plus a text box (Return or a comma adds one), with suggestions from what the app already knows.
private struct GoalChipsField: View {
    let title: String
    let placeholder: String
    @Binding var items: [String]
    let suggestions: [String]
    /// Tags are compared lowercased; artist names keep their case.
    let lowercase: Bool

    @State private var text = ""

    private var matches: [String] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let taken = Set(items.map { $0.lowercased() })
        return Array(suggestions.lazy.filter { !taken.contains($0.lowercased()) && $0.localizedStandardContains(query) }.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(AppTypography.metadata).foregroundStyle(.secondary)
            if !items.isEmpty {
                TagFlowLayout(spacing: 6) {
                    ForEach(items, id: \.self) { item in
                        Button { items.removeAll { $0 == item } } label: {
                            HStack(spacing: 4) { Text(item); Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.tint.opacity(0.2), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Remove “\(item)”")
                    }
                }
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit(text) }
                .onChange(of: text) { _, new in if lowercase, new.contains(",") { commit(new) } }
            if !matches.isEmpty {
                TagFlowLayout(spacing: 6) {
                    ForEach(matches, id: \.self) { name in
                        Button(name) { commit(name) }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
    }

    private func commit(_ raw: String) {
        // Artist names can hold a comma, so only tags are split at one.
        for part in lowercase ? raw.split(separator: ",").map(String.init) : [raw] {
            var name = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if lowercase { name = name.lowercased() }
            // An artist typed in another case is the same artist; keep the spelling the app uses.
            if !lowercase, let known = suggestions.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { name = known }
            guard !name.isEmpty, !items.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
            items.append(name)
        }
        text = ""
    }
}

/// The "loves a month" box. It applies as you type (a plain number field only does at Return) and empty means "work it out from my history".
private struct LovesPerMonthField: View {
    let value: Double?
    let commit: (Double?) -> Void
    @State private var text = ""

    var body: some View {
        TextField("auto", text: $text)
            .frame(width: 80).textFieldStyle(.roundedBorder)
            .onAppear { text = Self.format(value) }
            .onChange(of: text) { _, new in
                let trimmed = new.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
                if trimmed.isEmpty {
                    if value != nil { commit(nil) }
                } else if let number = Double(trimmed), number >= 0, number != value {
                    commit(number)
                }
            }
    }

    private static func format(_ value: Double?) -> String {
        guard let value else { return "" }
        return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// The lines on the chart.
enum GoalSeries: String, CaseIterable, Identifiable {
    case actual, plan, habits, shuffle, dedicated

    var id: String { rawValue }

    init(kind: GoalScenarioKind) {
        switch kind {
        case .habits: self = .habits
        case .shuffle: self = .shuffle
        case .dedicated: self = .dedicated
        }
    }

    var kind: GoalScenarioKind? {
        switch self {
        case .habits: .habits
        case .shuffle: .shuffle
        case .dedicated: .dedicated
        default: nil
        }
    }

    var label: String {
        switch self {
        case .actual: "Actual"
        case .plan: "On target"
        default: kind!.label
        }
    }

    var color: Color {
        switch self {
        case .actual: .primary
        case .plan: .gray
        case .habits: .blue
        case .shuffle: .orange
        case .dedicated: .green
        }
    }

    var help: String {
        switch self {
        case .actual: "Tracks in the goal you haven't played since it began, at the end of each day."
        case .plan: "A straight line from the tracks there were on the first day to none at the end of the deadline day."
        default: kind!.explanation
        }
    }

    func isAvailable(in result: GoalResult) -> Bool {
        guard let kind else { return true }
        return result.forecasts[kind] != nil
    }
}

/// How much of the goal's history the chart shows.
enum GoalChartRange: String, CaseIterable, Identifiable {
    case whole, back90, back30, back7, ahead

    var id: String { rawValue }

    var label: String {
        switch self {
        case .whole: "Whole goal"
        case .back90: "90 days back"
        case .back30: "30 days back"
        case .back7: "7 days back"
        case .ahead: "From today"
        }
    }

    /// The first day shown, as a day index from the goal's start.
    func firstDay(todayIndex: Int) -> Int {
        switch self {
        case .whole: 0
        case .back90: max(0, todayIndex - 90)
        case .back30: max(0, todayIndex - 30)
        case .back7: max(0, todayIndex - 7)
        case .ahead: todayIndex
        }
    }
}

enum GoalEditorRequest: Identifiable {
    case new
    case edit(ListeningGoal)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let goal): goal.id.uuidString
        }
    }
}

/// Creates or edits a goal.
struct GoalEditor: View {
    let request: GoalEditorRequest
    let calendar: Calendar
    let onSave: (ListeningGoal) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var title = "Hear all my loved tracks"
    @State private var titleEdited = false
    @State private var criteria = GoalCriteria()
    @State private var artistSuggestions: [String] = []
    @State private var tagSuggestions: [String] = []
    @State private var start = Date()
    @State private var deadline = Date()
    @State private var existing: ListeningGoal?
    @State private var libraryOnly = false

    private var criteriaNote: String {
        var text = criteria.loved == .loved
            ? "Counts the tracks you've loved on Last.fm, including ones you've never played."
            : "Counts tracks in your play history (played at least once, ever). A track you play for the first time after the start counts as heard at once."
        if !criteria.tags.isEmpty {
            text += " Tags are Last.fm community tags already looked up plus your own; a track whose tags haven't been looked up yet isn't counted until they are."
        }
        return text
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && calendar.startOfDay(for: deadline) > calendar.startOfDay(for: start)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "New Goal" : "Edit Goal").font(AppTypography.pageTitle)
            Text("Hear every track in the goal at least once, between these dates. A play before the start date doesn't count, and the start can be in the future.")
                .font(AppTypography.metadata).foregroundStyle(.secondary)
            TextField("Name", text: Binding(get: { title }, set: { title = $0; titleEdited = true })).textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 8) {
                Picker("Tracks", selection: $criteria.loved) {
                    ForEach(GoalCriteria.LovedStatus.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                GoalChipsField(title: "Artists (any of)", placeholder: "Add an artist", items: $criteria.artists, suggestions: artistSuggestions, lowercase: false)
                GoalChipsField(title: "Tags (any of)", placeholder: "Add a tag, e.g. shoegaze", items: $criteria.tags, suggestions: tagSuggestions, lowercase: true)
                Text(criteriaNote).font(AppTypography.metadata).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                DatePicker("Start", selection: $start, displayedComponents: .date).fixedSize()
                Button("Today") { start = Date() }
                Button("Start of year") { start = calendar.date(from: DateComponents(year: calendar.component(.year, from: Date()), month: 1, day: 1)) ?? start }
                Button("Next year") {
                    let year = calendar.component(.year, from: Date()) + 1
                    start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? start
                    deadline = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) ?? deadline
                }
            }
            HStack {
                DatePicker("Deadline", selection: $deadline, in: start..., displayedComponents: .date).fixedSize()
                Button("End of year") { deadline = Self.endOfYear(calendar, now: max(start, Date())) }
                Button("90 days") { deadline = calendar.date(byAdding: .day, value: 90, to: max(start, Date())) ?? deadline }
            }
            Toggle("Only count tracks that are in my Apple Music library", isOn: $libraryOnly)
            Text("Leaves out tracks known to be missing from your library, such as ones that are no longer available to stream, as of the last check in Library Gaps. A track that was never checked stays in.")
                .font(AppTypography.metadata).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if calendar.startOfDay(for: deadline) <= calendar.startOfDay(for: start) {
                Text("The deadline needs to be after the start.").font(AppTypography.metadata).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    var goal = existing ?? ListeningGoal(title: title, start: start, deadline: deadline)
                    goal.title = title.trimmingCharacters(in: .whitespaces)
                    goal.start = calendar.startOfDay(for: start)
                    goal.deadline = calendar.startOfDay(for: deadline)
                    goal.inAppleLibraryOnly = libraryOnly
                    goal.criteria = criteria
                    onSave(goal)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            switch request {
            case .new:
                start = calendar.startOfDay(for: Date())
                deadline = Self.endOfYear(calendar)
                title = criteria.suggestedTitle
            case .edit(let goal):
                existing = goal
                title = goal.title
                start = goal.start
                deadline = goal.deadline
                libraryOnly = goal.inAppleLibraryOnly
                criteria = goal.criteria
                titleEdited = true
            }
        }
        .onChange(of: criteria) { _, new in
            if !titleEdited { title = new.suggestedTitle }
        }
        .task {
            artistSuggestions = ((try? modelContext.fetch(FetchDescriptor<Artist>())) ?? []).map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            tagSuggestions = EntityTagsEngine.loadSnapshot(context: modelContext).vocabulary.prefix(2000).map(\.tag)
        }
    }

    /// December 31 of this year, or of next year when this one is nearly over.
    static func endOfYear(_ calendar: Calendar, now: Date = Date()) -> Date {
        let year = calendar.component(.year, from: now)
        let thisYear = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) ?? now
        if thisYear.timeIntervalSince(now) < 14 * 86_400 {
            return calendar.date(from: DateComponents(year: year + 1, month: 12, day: 31)) ?? thisYear
        }
        return thisYear
    }
}
