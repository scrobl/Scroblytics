import AppKit
import Charts
import SwiftUI

/// A goal as something to share, dressed like its card in the app: the percentage heard, the progress bar with its tick for where the
/// plan would have you, the status in its colour, the figures, and the burn-down with its fill (and, from the goal's own page, the
/// forecasts). An achieved goal is gold. Drawn for the card at its own size (`ShareNativeChart`).
enum GoalShareCards {
    /// nil when the goal has no tracks to speak of.
    static func card(
        goal: ListeningGoal, analysis a: GoalAnalysis, result: GoalResult?, calendar: Calendar = AppCalendars.listening, now: Date = Date()
    ) -> ShareCard? {
        guard a.membersNow > 0 else { return nil }
        let status = GoalCardStatus(a)
        let forecasts = result?.forecasts ?? [:]
        let kinds = GoalScenarioKind.allCases.filter { forecasts[$0] != nil }
        var controls = [ShareNativeControl(id: "plan", label: "Show the on-target line", kind: .toggle(defaultValue: true))]
        if !kinds.isEmpty {
            controls.append(ShareNativeControl(id: "forecasts", label: "Show the forecasts", kind: .toggle(defaultValue: true)))
            controls.append(ShareNativeControl(id: "bands", label: "Show the range around each forecast", kind: .toggle(defaultValue: false)))
        }
        controls.append(ShareNativeControl(id: "legend", label: "Show the key", kind: .toggle(defaultValue: true)))

        var lines = [
            "Heard: \(a.heardNow.formatted()) of \(a.membersNow.formatted())",
            "To hear: \(a.remainingNow.formatted())",
        ]
        if a.completedIndex == nil, a.daysUntilStart == 0, a.todayIndex < a.deadlineIndex { lines.append("Days left: \((a.daysLeft + 1).formatted())") }
        if a.remainingNow > 0 { lines.append("Needed: \(String(format: "%.1f", a.requiredPerDay)) a day if none repeat") }
        for kind in kinds {
            if let chance = forecasts[kind]?.chanceByDeadline { lines.append("\(kind.label): \(Int((chance * 100).rounded()))% chance of finishing by the deadline") }
        }

        let model = GoalShareModel(analysis: a, status: status, stats: figures(a, status, calendar: calendar), forecasts: forecasts, calendar: calendar)
        let native = ShareNativeChart(
            id: "goal.burndown",
            caption: caption(goal: goal, analysis: a, status: status, calendar: calendar),
            footnote: "Tracks still to hear at the end of each day. On target is a straight line to none by the deadline."
                + (kinds.isEmpty ? "" : " Forecasts are the middle of 300 simulated runs from your recent listening."),
            preferredSize: .wide, controls: controls, textLines: lines,
            // The card already says where the goal stands in its figures; the sentence is there to be switched on.
            defaultFlags: ["caption": false],
            fullCard: { card, options, identity, _ in
                AnyView(GoalShareCardView(card: card, options: options, identity: identity, model: model))
            },
            make: { _, _, _ in AnyView(EmptyView()) }
        )
        return ShareCard(
            title: goal.title, period: "\(GoalsView.dayLabel(goal.start)) – \(GoalsView.dayLabel(goal.deadline))", measure: goal.criteria.summary,
            rows: [], valueLabel: "", hasMovement: false, generatedAt: now, kindID: "goal.burndown", native: native
        )
    }

    /// The tiles under the bar: the same figures as the goal's card in the app.
    static func figures(_ a: GoalAnalysis, _ status: GoalCardStatus, calendar: Calendar) -> [ShareStat] {
        switch status.kind {
        case .complete:
            var stats = [ShareStat(label: "Tracks heard", value: a.membersNow.formatted())]
            if let done = a.completedIndex {
                let finished = calendar.date(byAdding: .day, value: done, to: a.startDay) ?? a.startDay
                stats.append(ShareStat(label: "Finished", value: GoalsView.dayLabel(finished)))
                let early = a.deadlineIndex - done
                if early > 0 { stats.append(ShareStat(label: early == 1 ? "Day early" : "Days early", value: early.formatted())) }
            }
            return stats
        case .notStarted:
            return [ShareStat(label: "To hear", value: a.remainingNow.formatted()), ShareStat(label: "Starts in", value: "\(a.daysUntilStart.formatted()) \(a.daysUntilStart == 1 ? "day" : "days")")]
        case .missed, .empty:
            return [ShareStat(label: "To hear", value: a.remainingNow.formatted())]
        case .ahead, .onPlan, .behind:
            return [
                ShareStat(label: "To hear", value: a.remainingNow.formatted()),
                ShareStat(label: "Days left", value: (a.daysLeft + 1).formatted()),
                ShareStat(label: "A day needed", value: String(format: "%.1f", a.requiredPerDay)),
            ]
        }
    }

    /// Where the goal stands, in a sentence.
    static func caption(goal: ListeningGoal, analysis a: GoalAnalysis, status: GoalCardStatus, calendar: Calendar) -> String {
        let noun = goal.criteria.noun
        switch status.kind {
        case .complete:
            var text = "Achieved: all \(a.membersNow.formatted()) \(noun) heard"
            if let done = a.completedIndex {
                let finished = calendar.date(byAdding: .day, value: done, to: a.startDay) ?? a.startDay
                text += " by \(GoalsView.dayLabel(finished))"
                let early = a.deadlineIndex - done
                if early > 0 { text += ", \(early) \(early == 1 ? "day" : "days") early" }
            }
            return text + "."
        case .notStarted:
            return "Starts \(GoalsView.dayLabel(goal.start)): \(a.membersNow.formatted()) \(noun) to hear by \(GoalsView.dayLabel(goal.deadline))."
        case .missed:
            return "Deadline passed: \(a.heardNow.formatted()) of \(a.membersNow.formatted()) \(noun) heard."
        case .empty:
            return ""
        case .ahead, .onPlan, .behind:
            let days = a.daysLeft + 1
            return "\(a.heardNow.formatted()) of \(a.membersNow.formatted()) \(noun) heard (\(GoalCardStatus.percent(a))%): \(a.remainingNow.formatted()) to go, \(days.formatted()) \(days == 1 ? "day" : "days") left. \(status.headline)."
        }
    }
}

/// What the card draws, handed in.
struct GoalShareModel: Sendable {
    let analysis: GoalAnalysis
    let status: GoalCardStatus
    let stats: [ShareStat]
    let forecasts: [GoalScenarioKind: GoalForecast]
    let calendar: Calendar
}

/// The whole card, in the dark design of the other share cards with the goal card's own touches: a wash of the status colour, the
/// bar and its tick, and (when achieved) a gold rim.
struct GoalShareCardView: View {
    let card: ShareCard
    let options: ShareOptions
    let identity: ShareIdentity
    let model: GoalShareModel

    private var a: GoalAnalysis { model.analysis }
    private var status: GoalCardStatus { model.status }
    private var achieved: Bool { status.kind == .complete }
    private var color: Color { achieved ? GoalCardStatus.gold : status.color }
    private var size: CGSize { options.size.points }
    private var isWide: Bool { options.size == .wide }
    private let margin: CGFloat = 64

    var body: some View {
        ZStack {
            ShareCardBackground(size: size, imageURL: nil, images: [:])
            // A wash of the goal's colour from the top left, stronger for an achieved goal (as on its card in the app).
            LinearGradient(colors: [color.opacity(achieved ? 0.34 : 0.18), .clear], startPoint: .topLeading, endPoint: UnitPoint(x: 0.7, y: 0.6))
                .frame(width: size.width, height: size.height)
            if achieved { rim }
            VStack(alignment: .leading, spacing: 0) {
                if isWide { wideBody } else { narrowBody }
                if ShareCardFooter.isShown(identity) { ShareCardFooter(identity: identity).padding(.top, 18) }
            }
            .padding(margin + (achieved ? 14 : 0))
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    /// The gold edge of an achieved goal: a thin rim with a glow just inside it.
    private var rim: some View {
        let shape = RoundedRectangle(cornerRadius: 44, style: .continuous)
        return ZStack {
            shape.strokeBorder(GoalCardStatus.gold.opacity(0.55), lineWidth: 34).blur(radius: 26)
            shape.strokeBorder(LinearGradient(colors: [GoalCardStatus.gold, GoalCardStatus.gold.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 5)
        }
        .padding(18)
        .frame(width: size.width, height: size.height)
    }

    // MARK: Layouts

    private var narrowBody: some View {
        let square = options.size == .square
        return VStack(alignment: .leading, spacing: square ? 22 : 30) {
            kicker
            heading(titleSize: square ? 78 : 88)
            hero(percentSize: square ? 120 : 150, barHeight: square ? 34 : 40)
            ShareStatGrid(stats: model.stats, columns: max(1, min(model.stats.count, 3)), valueSize: square ? 40 : 46)
            caption
            chartPanel
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var wideBody: some View {
        HStack(alignment: .top, spacing: 56) {
            VStack(alignment: .leading, spacing: 0) {
                kicker
                Spacer(minLength: 20)
                heading(titleSize: 76)
                Spacer(minLength: 20)
                hero(percentSize: 128, barHeight: 34)
                Spacer(minLength: 20)
                ShareStatGrid(stats: model.stats, columns: max(1, min(model.stats.count, 3)), valueSize: 38)
                caption.padding(.top, 20)
                Spacer(minLength: 0)
            }
            .frame(width: (size.width - margin * 2) * 0.40, alignment: .topLeading)
            chartPanel
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Pieces

    private var kicker: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(card.period.uppercased())
                .font(.system(size: 26, weight: .bold)).tracking(3)
                .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
            Spacer(minLength: 16)
            if options.showDate {
                Text(card.generatedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 26, weight: .semibold)).foregroundStyle(Color.white.opacity(0.62)).lineLimit(1)
            }
        }
    }

    /// What the goal counts ("Loved tracks by …"), or what the person typed instead. (A chart card's own subtitle is its comparison, which a
    /// goal doesn't have.)
    private var subtitle: String {
        let typed = options.customSubtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? card.measure : typed
    }

    private func heading(titleSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.displayTitle(for: options))
                .font(.system(size: titleSize, weight: .heavy, design: .rounded))
                .foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.5)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 32, weight: .medium)).foregroundStyle(Color.white.opacity(0.68)).lineLimit(1).minimumScaleFactor(0.6)
            }
        }
    }

    /// The percentage, how many that is, the status in its colour, and the bar with the plan's tick.
    private func hero(percentSize: CGFloat, barHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text("\(GoalCardStatus.percent(a))%")
                    .font(.system(size: percentSize, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(achieved ? GoalCardStatus.gold : .white)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("\(a.heardNow.formatted()) of \(a.membersNow.formatted()) heard")
                    .font(.system(size: 30, weight: .medium)).foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            Label(status.headline, systemImage: status.symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(color.opacity(0.18), in: Capsule())
                .lineLimit(1).minimumScaleFactor(0.6)
            GoalProgressBar(heard: status.heardShare, plan: status.planShare, color: color, tickWidth: 6)
                .frame(height: barHeight)
        }
    }

    @ViewBuilder
    private var caption: some View {
        let native = card.native
        if options.showsCaption, let native, !native.displayCaption(for: options).isEmpty {
            Text(native.displayCaption(for: options))
                .font(.system(size: 28, weight: .medium)).foregroundStyle(Color.white.opacity(0.85))
                .lineLimit(3).minimumScaleFactor(0.7).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var chartPanel: some View {
        GeometryReader { geometry in
            let zoom: CGFloat = isWide ? 1.7 : 1.9
            let inset: CGFloat = 22
            let inner = CGSize(width: max(40, geometry.size.width - inset * 2), height: max(40, geometry.size.height - inset * 2))
            let logical = CGSize(width: inner.width / zoom, height: inner.height / zoom)
            let legend = options.flag("legend", true)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.white.opacity(0.06))
                RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1)
                GoalShareChartView(
                    analysis: a, forecasts: options.flag("forecasts", true) ? model.forecasts : [:], calendar: model.calendar,
                    showsPlan: options.flag("plan", true), showsBands: options.flag("bands", false), showsLegend: legend,
                    achieved: achieved, tint: color, height: max(100, logical.height - (legend ? 34 : 4))
                )
                .frame(width: logical.width, height: logical.height, alignment: .topLeading)
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(width: inner.width, height: inner.height, alignment: .topLeading)
                .clipped()
                .padding(inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The burn-down on a share card: light on dark, sized from the card, with the area under the line filled like the cards in the app.
struct GoalShareChartView: View {
    let analysis: GoalAnalysis
    let forecasts: [GoalScenarioKind: GoalForecast]
    let calendar: Calendar
    let showsPlan: Bool
    let showsBands: Bool
    let showsLegend: Bool
    let achieved: Bool
    /// The colour of the goal's own line when no forecast is drawn beside it.
    var tint: Color = .white
    let height: CGFloat

    private func date(_ day: Int) -> Date { calendar.date(byAdding: .day, value: day, to: analysis.startDay) ?? analysis.startDay }
    private var kinds: [GoalScenarioKind] { GoalScenarioKind.allCases.filter { forecasts[$0] != nil } }
    /// Forecasts are blue, orange and green, so the goal's own line is white beside them, and in the goal's colour alone.
    private var actualColor: Color { achieved ? GoalCardStatus.gold : (kinds.isEmpty ? tint : .white) }
    private var muted: Color { .white.opacity(0.7) }

    var body: some View {
        let a = analysis
        let today = date(a.todayIndex)
        let yMax = max(1.0, Double(a.actual.max() ?? 1), a.plan.max() ?? 1, forecasts.values.compactMap { $0.high.max() }.max() ?? 0) * 1.06
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                if showsPlan {
                    ForEach(Array(a.plan.enumerated()), id: \.offset) { day, value in
                        LineMark(x: .value("Date", date(day)), y: .value("Tracks", value), series: .value("Series", "On target"))
                            .foregroundStyle(Color.white.opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 5]))
                    }
                }
                ForEach(Array(a.actual.enumerated()), id: \.offset) { day, value in
                    AreaMark(x: .value("Date", date(day)), y: .value("Tracks", value), series: .value("Series", "Fill"))
                        .foregroundStyle(LinearGradient(colors: [actualColor.opacity(0.32), actualColor.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.stepEnd)
                }
                ForEach(kinds) { kind in
                    if let f = forecasts[kind] {
                        let color = GoalSeries(kind: kind).color
                        if showsBands {
                            ForEach(0..<f.median.count, id: \.self) { offset in
                                AreaMark(
                                    x: .value("Date", date(a.todayIndex + offset)), yStart: .value("Low", f.low[offset]), yEnd: .value("High", f.high[offset]),
                                    series: .value("Band", kind.label)
                                )
                                .foregroundStyle(color.opacity(0.16))
                            }
                        }
                        ForEach(0..<f.median.count, id: \.self) { offset in
                            LineMark(x: .value("Date", date(a.todayIndex + offset)), y: .value("Tracks", f.median[offset]), series: .value("Series", kind.label))
                                .foregroundStyle(color)
                                .lineStyle(StrokeStyle(lineWidth: 3))
                        }
                    }
                }
                ForEach(Array(a.actual.enumerated()), id: \.offset) { day, value in
                    LineMark(x: .value("Date", date(day)), y: .value("Tracks", value), series: .value("Series", "Actual"))
                        .foregroundStyle(actualColor)
                        .lineStyle(StrokeStyle(lineWidth: 4))
                        .interpolationMethod(.stepEnd)
                }
                if a.actual.count == 1, let only = a.actual.first {
                    PointMark(x: .value("Date", date(0)), y: .value("Tracks", only)).foregroundStyle(actualColor).symbolSize(120)
                }
                RuleMark(x: .value("Today", today))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text(a.daysUntilStart > 0 ? "Start" : "Today").font(.caption).foregroundStyle(muted)
                    }
                RuleMark(x: .value("Deadline", date(a.deadlineIndex)))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .foregroundStyle(Color.red.opacity(0.85))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text("Deadline").font(.caption).foregroundStyle(Color.red.opacity(0.95))
                    }
            }
            .chartYScale(domain: 0...yMax)
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.10))
                    AxisValueLabel().foregroundStyle(muted)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing) { _ in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.14))
                    AxisValueLabel().foregroundStyle(muted)
                }
            }
            .padding(.top, 18)
            .frame(height: height)
            if showsLegend {
                TagFlowLayout(spacing: 14) {
                    legendItem("Actual", actualColor)
                    if showsPlan { legendItem("On target", Color.white.opacity(0.55)) }
                    ForEach(kinds) { legendItem($0.label, GoalSeries(kind: $0).color) }
                }
            }
        }
    }

    private func legendItem(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption).foregroundStyle(muted)
        }
    }
}
