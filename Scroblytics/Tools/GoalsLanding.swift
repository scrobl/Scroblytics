import SwiftUI
import Charts

/// Where a goal stands, in the words and numbers its summary card shows.
struct GoalCardStatus: Equatable {
    enum Kind: Equatable { case empty, notStarted, ahead, onPlan, behind, complete, missed }

    var kind: Kind
    /// "12 ahead of plan", "Starts in 9 days", …
    var headline: String
    /// The share of the goal's loved tracks that has been heard, and the share the straight-line plan would have had heard by today.
    var heardShare: Double
    var planShare: Double
    /// Where "Your habits" has it ending up: "About 500 short at your pace" or "On pace to finish Nov 20"; nil when there is no forecast.
    var outlook: String?
    /// The habits forecast leaves tracks to hear at the deadline, however the goal stands against the plan today.
    var fallsShort = false

    /// `includingOutlook: false` leaves the forecast out (a shared card shows the standing, with the forecasts as its own option).
    init(_ a: GoalAnalysis, includingOutlook: Bool = true) {
        heardShare = a.membersNow > 0 ? Double(a.heardNow) / Double(a.membersNow) : 0
        let planToday = a.plan.isEmpty ? 0 : a.plan[min(max(a.todayIndex, 0), a.plan.count - 1)]
        planShare = a.membersNow > 0 && a.remainingNow > 0 && a.daysUntilStart == 0 ? min(max(1 - planToday / Double(a.membersNow), 0), 1) : 0
        if a.membersNow == 0 {
            kind = .empty
            headline = "No loved tracks yet"
        } else if a.remainingNow == 0 {
            kind = .complete
            headline = "Achieved"
        } else if a.daysUntilStart > 0 {
            kind = .notStarted
            headline = "Starts in \(a.daysUntilStart.formatted()) \(a.daysUntilStart == 1 ? "day" : "days")"
        } else if a.todayIndex >= a.deadlineIndex {
            kind = .missed
            headline = "Deadline passed"
        } else {
            let gap = Int((planToday - Double(a.remainingNow)).rounded())
            if gap >= 1 {
                kind = .ahead
                headline = "\(gap.formatted()) ahead of plan"
            } else if gap <= -1 {
                kind = .behind
                headline = "\((-gap).formatted()) behind plan"
            } else {
                kind = .onPlan
                headline = "On plan"
            }
            if includingOutlook, let o = a.outlook {
                fallsShort = o.fallsShort
                outlook = Self.describe(o)
            }
        }
    }

    static func describe(_ o: GoalOutlook) -> String {
        o.finishDate.map { "On pace to finish \(GoalsView.dayLabel($0))" } ?? "About \(o.shortfall.formatted()) short at your pace"
    }

    /// The whole percent heard; never 100 while something is left, so "5 to hear" doesn't sit beside "100%".
    static func percent(_ a: GoalAnalysis) -> Int {
        guard a.membersNow > 0 else { return 0 }
        let rounded = Int((Double(a.heardNow) / Double(a.membersNow) * 100).rounded())
        return a.remainingNow == 0 ? 100 : min(rounded, 99)
    }

    /// The goal is over: it was achieved, or its deadline passed with tracks left.
    var isFinished: Bool { kind == .complete || kind == .missed }

    /// The colour of an achieved goal.
    static let gold = Color(red: 0.96, green: 0.74, blue: 0.22)

    var color: Color {
        // Ahead of the plan so far, but not on course to finish: the colour follows the forecast.
        if fallsShort && (kind == .ahead || kind == .onPlan) { return .orange }
        return switch kind {
        case .complete: Self.gold
        case .ahead: .green
        case .behind: .orange
        case .missed: .red
        case .onPlan: .accentColor
        case .notStarted, .empty: .secondary
        }
    }

    var symbol: String {
        switch kind {
        case .complete: "checkmark.seal.fill"
        case .ahead: "arrow.up.right.circle.fill"
        case .behind: "arrow.down.right.circle.fill"
        case .missed: "exclamationmark.circle.fill"
        case .onPlan: "equal.circle.fill"
        case .notStarted: "clock.fill"
        case .empty: "heart.slash"
        }
    }
}

/// The landing page's two lists.
enum GoalSections {
    /// Active goals (running, or not started yet) and finished ones (achieved, or past the deadline), each newest start first. A goal whose
    /// numbers aren't worked out yet is listed as active.
    static func split(goals: [ListeningGoal], analyses: [UUID: GoalAnalysis]) -> (active: [ListeningGoal], completed: [ListeningGoal]) {
        let ordered = goals.sorted { a, b in
            a.start != b.start ? a.start > b.start : a.createdAt > b.createdAt
        }
        let finished = Set(ordered.filter { goal in analyses[goal.id].map { GoalCardStatus($0).isFinished } ?? false }.map(\.id))
        return (ordered.filter { !finished.contains($0.id) }, ordered.filter { finished.contains($0.id) })
    }
}

/// One goal on the landing page: its name and dates, how far along it is (a bar with a tick where the plan says you'd be today), the
/// numbers that matter, and the shape of the burn-down so far. Every card is the same size; an achieved goal is gold.
struct GoalCard: View {
    /// The same for every card, so a page of goals reads as a grid.
    static let height: CGFloat = 276

    let goal: ListeningGoal
    let analysis: GoalAnalysis?
    /// The goal as a card to share (its burn-down and plan; the forecasts belong to the goal's own page).
    let shareCard: () -> ShareCard?
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    /// Whether the goal is one of those on the Overview, whether another can still be added, and the toggle; nil leaves the choice out.
    var isOnOverview = false
    var overviewHasRoom = true
    var onToggleOverview: (() -> Void)? = nil
    /// The "…" menu (open, edit, delete): left off where the card is only a summary (the Overview).
    var showsMenu = true
    @State private var hovering = false

    private var status: GoalCardStatus? { analysis.map { GoalCardStatus($0) } }
    private var achieved: Bool { status?.kind == .complete }
    private var tint: Color { status?.color ?? .secondary }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 12) {
                    titleRow
                    if let analysis, let status {
                        progress(analysis, status)
                        figures(analysis, status)
                        sparkline(analysis, status)
                    } else {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .drillDownHighlight()
            HStack(spacing: 10) {
                ShareButton(title: goal.title, iconOnly: true, card: shareCard, isEnabled: analysis != nil)
                    .buttonStyle(.borderless).foregroundStyle(.secondary).imageScale(.large)
                if showsMenu {
                    Menu {
                        Button("Open", action: onOpen)
                        Button("Edit…", action: onEdit)
                        overviewItem
                        Divider()
                        Button("Delete…", role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis.circle").imageScale(.large).foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Open, edit or delete this goal")
                }
            }
            .padding(12)
        }
        .frame(height: Self.height)
        .background(.regularMaterial, in: shape)
        // A wash of the goal's colour from the top left; stronger for an achieved goal.
        .background(LinearGradient(colors: [tint.opacity(achieved ? 0.22 : 0.08), .clear], startPoint: .topLeading, endPoint: .center), in: shape)
        .overlay {
            if achieved {
                // A glow just inside the edge (clipped to the card, so it never spills onto its neighbours) and a thin gold rim.
                ZStack {
                    shape.strokeBorder(GoalCardStatus.gold.opacity(0.55), lineWidth: 8).blur(radius: 7)
                    shape.strokeBorder(LinearGradient(colors: [GoalCardStatus.gold, GoalCardStatus.gold.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
                }
            } else {
                shape.stroke(.separator.opacity(0.4), lineWidth: 1)
            }
        }
        .clipShape(shape)
        .shadow(color: .black.opacity(hovering ? 0.25 : 0), radius: 8, y: 2)
        .scaleEffect(hovering ? 1.008 : 1)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open", action: onOpen)
            if showsMenu {
                Button("Edit…", action: onEdit)
                overviewItem
                Divider()
                Button("Delete…", role: .destructive, action: onDelete)
            }
        }
    }

    /// Show on the Overview, or take off it; refused while the Overview's row is full.
    @ViewBuilder
    private var overviewItem: some View {
        if let onToggleOverview {
            Button(isOnOverview ? "Remove from Overview" : "Show on Overview", action: onToggleOverview)
                .disabled(!isOnOverview && !overviewHasRoom)
                .help(!isOnOverview && !overviewHasRoom ? "The Overview shows up to \(GoalsState.overviewLimit) goals. Remove one first." : "")
        }
    }

    private var titleRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(goal.title).font(AppTypography.sectionTitle).lineLimit(1)
            HStack(spacing: 5) {
                Text("\(GoalsView.dayLabel(goal.start)) – \(GoalsView.dayLabel(goal.deadline))").lineLimit(1)
                if isOnOverview && showsMenu {
                    Image(systemName: "pin.fill").font(.caption2).help("Shown on the Overview")
                }
            }
            .font(AppTypography.metadata).foregroundStyle(.secondary)
            Text(goal.criteria.summary).font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.trailing, 70)
    }

    private func progress(_ a: GoalAnalysis, _ status: GoalCardStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(a.membersNow == 0 ? "—" : "\(GoalCardStatus.percent(a))%")
                    .font(AppTypography.statValue.monospacedDigit())
                Text(a.membersNow == 0 ? "" : "\(a.heardNow.formatted()) of \(a.membersNow.formatted()) heard")
                    .font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Label(status.headline, systemImage: status.symbol)
                    .font(status.kind == .complete ? AppTypography.metadata.weight(.semibold) : AppTypography.metadata)
                    .foregroundStyle(status.color).lineLimit(1)
            }
            GoalProgressBar(heard: status.heardShare, plan: status.planShare, color: status.color)
                .frame(height: 10)
            if let outlook = status.outlook {
                Label(outlook, systemImage: status.fallsShort ? "chart.line.downtrend.xyaxis" : "chart.line.uptrend.xyaxis")
                    .font(AppTypography.metadata)
                    .foregroundStyle(status.fallsShort ? Color.orange : Color.secondary)
                    .lineLimit(1)
                    .help("Where \"Your habits\" ends up if you keep listening as you have lately (the middle estimate)")
            }
        }
    }

    private func figures(_ a: GoalAnalysis, _ status: GoalCardStatus) -> some View {
        HStack(spacing: 18) {
            switch status.kind {
            case .complete:
                figure(a.membersNow.formatted(), "tracks heard")
                if let done = a.completedIndex {
                    let finished = AppCalendars.listening.date(byAdding: .day, value: done, to: a.startDay) ?? a.startDay
                    figure(GoalsView.dayLabel(finished), "finished")
                    if a.deadlineIndex - done > 0 { figure("\(a.deadlineIndex - done)", a.deadlineIndex - done == 1 ? "day early" : "days early") }
                }
            case .notStarted:
                figure(a.remainingNow.formatted(), "to hear")
                figure(a.daysUntilStart.formatted(), "days until it starts")
            case .missed, .empty:
                figure(a.remainingNow.formatted(), "to hear")
            default:
                figure(a.remainingNow.formatted(), "to hear")
                figure((a.daysLeft + 1).formatted(), "days left")
                figure(String(format: "%.1f", a.requiredPerDay), "a day needed")
            }
            Spacer(minLength: 0)
        }
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(AppTypography.contentTitle.monospacedDigit())
            Text(label).font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    @ViewBuilder
    private func sparkline(_ a: GoalAnalysis, _ status: GoalCardStatus) -> some View {
        let top = max(1.0, Double(a.actual.max() ?? 1), a.plan.max() ?? 1)
        let line: Color = status.kind == .notStarted ? .secondary : (status.kind == .complete ? status.color : .accentColor)
        Chart {
            ForEach(Array(a.plan.enumerated()), id: \.offset) { day, value in
                LineMark(x: .value("Day", day), y: .value("Plan", value), series: .value("Series", "Plan"))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            if status.kind != .notStarted {
                ForEach(Array(a.actual.enumerated()), id: \.offset) { day, value in
                    AreaMark(x: .value("Day", day), y: .value("Left", value), series: .value("Series", "Area"))
                        .foregroundStyle(LinearGradient(colors: [line.opacity(0.28), line.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.stepEnd)
                }
            }
            ForEach(Array(a.actual.enumerated()), id: \.offset) { day, value in
                LineMark(x: .value("Day", day), y: .value("Left", value), series: .value("Series", "Left"))
                    .foregroundStyle(line)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.stepEnd)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...(top * 1.05))
        // A goal past its deadline keeps counting days after it, so the axis runs to whichever is later.
        .chartXScale(domain: 0...max(a.deadlineIndex, a.todayIndex, 1))
        .frame(maxWidth: .infinity, minHeight: 40, maxHeight: .infinity)
        .clipped()
        .accessibilityHidden(true)
    }
}

/// A thin bar: the heard share filled in, and a small tick where a steady pace to the deadline would have you by today.
struct GoalProgressBar: View {
    let heard: Double
    let plan: Double
    let color: Color
    /// The plan's tick, in points (drawn larger on a share card).
    var tickWidth: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.18))
                Capsule().fill(LinearGradient(colors: [color.opacity(0.7), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(heard > 0 ? proxy.size.height : 0, width * min(max(heard, 0), 1)))
                if plan > 0 && plan < 1 {
                    Rectangle().fill(.primary.opacity(0.75))
                        .frame(width: tickWidth, height: proxy.size.height + tickWidth * 3)
                        .offset(x: width * plan - tickWidth / 2, y: 0)
                        .help("Where a steady pace to the deadline would have you today")
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((heard * 100).rounded())) percent heard")
    }
}
