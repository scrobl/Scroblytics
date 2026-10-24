import AppKit
import Charts
import SwiftUI

/// The rest of the Trends charts drawn for a shared card (see `ShareNativeChart`): volume, when you listen, discovery, rankings, long tail,
/// loyalty, flow, eras and taste. Each is built from the numbers its chart has already worked out and laid out at the card's own size.
enum TrendsShareCharts2 {
    private static func compareToggle() -> ShareNativeControl { ShareNativeControl(id: "compare", label: "Include the comparison with the previous period", kind: .toggle(defaultValue: false)) }
    private static func legendToggle() -> ShareNativeControl { ShareNativeControl(id: "legend", label: "Show the key", kind: .toggle(defaultValue: true)) }
    private static func whole(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0))) }
    private static let wideBias: @Sendable (ShareSize) -> CGFloat = { $0 == .wide ? 1.6 : 1.8 }

    // MARK: Volume over time

    static func volume(volume: TrendsVolume, metric: TrendsMetric, mode: String) -> ShareNativeChart {
        let unitWord = metric == .plays ? "scrobbles" : "listened"
        let compared = volume.compareRange.map { TrendsDrill.rangeLabel(from: $0.from, to: $0.to) } ?? "the previous period"
        let caption = "\(TrendsWeight.format(volume.total, metric: metric)) \(unitWord)"
        let comparisonCaption = volume.changeLabel.map { caption + ", \($0) vs \(compared)" }
        var controls = [
            ShareNativeControl(id: "mode", label: "Show", kind: .choice(["Per period", "Running total"], defaultValue: mode)),
            ShareNativeControl(id: "area", label: "Shade under the line", kind: .toggle(defaultValue: true)),
        ]
        if volume.compareRange != nil { controls.insert(compareToggle(), at: 1) }
        var lines: [String] = []
        if let best = volume.points.max(by: { $0.count < $1.count }), best.count > 0 {
            lines.append("Busiest \(volume.granularity == .day ? "day" : volume.granularity == .week ? "week" : "month"): \(TrendsDrill.label(start: best.start, granularity: volume.granularity)) (\(TrendsWeight.format(best.count, metric: metric)))")
        }
        return ShareNativeChart(
            id: "trends.volume", caption: caption, comparisonCaption: comparisonCaption,
            footnote: metric == .timeListened && volume.pending > 0 ? "\(volume.pending.formatted()) plays still waiting for a track length aren’t counted." : nil,
            preferredSize: .wide, controls: controls, textLines: lines, zoomForShape: wideBias
        ) { layout, options, _ in
            AnyView(ShareVolumeChart(
                volume: volume, metric: metric, running: options.pick("mode", mode) == "Running total",
                compare: options.flag("compare", false), area: options.flag("area", true), height: layout.logical.height
            ))
        }
    }

    // MARK: When you listen

    static func heatmap(heatmap: TrendsHeatmap, metric: TrendsMetric) -> ShareNativeChart {
        let unitWord = metric == .plays ? "scrobbles" : "listened"
        let caption = heatmap.peak.map { "Busiest: \(QueryPlayFilter.dayNames[$0.day]) \(QueryPlayFilter.hourLabel($0.hour)) · \(TrendsWeight.format($0.count, metric: metric)) \(unitWord)" } ?? "Scrobbles by day of the week and hour of the day."
        var controls = [
            ShareNativeControl(id: "hours", label: "Show the hour labels", kind: .toggle(defaultValue: true)),
            ShareNativeControl(id: "legend", label: "Show the key", kind: .toggle(defaultValue: true)),
        ]
        if heatmap.compareCounts != nil { controls.insert(compareToggle(), at: 0) }
        return ShareNativeChart(
            id: "trends.heatmap", caption: caption,
            footnote: "Darker means more. Times are in your local time. " + (metric == .timeListened && heatmap.pending > 0 ? "\(heatmap.pending.formatted()) plays still waiting for a track length aren’t counted." : ""),
            preferredSize: .wide, controls: controls, zoomForShape: { $0 == .wide ? 1.6 : 1.85 }
        ) { layout, options, _ in
            AnyView(ShareHeatmapGrid(
                heatmap: heatmap, layout: layout, compare: options.flag("compare", false), hours: options.flag("hours", true), legend: options.flag("legend", true)
            ))
        }
    }

    // MARK: Discovery

    static func discovery(discovery: TrendsDiscovery, metric: TrendsMetric) -> ShareNativeChart {
        let pct = discovery.newPercent.formatted(.number.precision(.fractionLength(1)))
        let caption = "\(pct)% of what you played was new"
        let comparisonCaption = discovery.comparePercent.map { compare -> String in
            let diff = discovery.newPercent - compare
            return caption + " (\(diff >= 0 ? "+" : "")\(diff.formatted(.number.precision(.fractionLength(1)))) pts vs the previous period)"
        }
        let detail = metric == .plays
            ? "\(discovery.newTotal.formatted()) new tracks · \(discovery.repeatTotal.formatted()) repeat plays"
            : "\(TrendsWeight.format(discovery.newTotal, metric: .timeListened)) on something new · \(TrendsWeight.format(discovery.repeatTotal, metric: .timeListened)) on repeats"
        var controls = [legendToggle()]
        if discovery.compareRange != nil { controls.insert(compareToggle(), at: 0) }
        return ShareNativeChart(
            id: "trends.discovery", caption: caption, comparisonCaption: comparisonCaption, footnote: "New means the first time you ever played that track.", preferredSize: .wide,
            controls: controls, textLines: [detail], zoomForShape: wideBias
        ) { layout, options, _ in
            AnyView(ShareDiscoveryChart(discovery: discovery, compare: options.flag("compare", false), legend: options.flag("legend", true), height: layout.logical.height))
        }
    }

    // MARK: Rankings

    static func rankings(data: TrendsRankBump, metric: TrendsMetric) -> ShareNativeChart {
        let noun = data.target.rawValue + "s"
        let controls = [
            ShareNativeControl(id: "lines", label: "Lines", kind: .count(range: 3...max(3, data.topN), defaultValue: data.topN)),
            ShareNativeControl(id: "legend", label: "Name the lines", kind: .toggle(defaultValue: true)),
            ShareNativeControl(id: "points", label: "Show the points", kind: .toggle(defaultValue: true)),
        ]
        let lines = data.series.map { "#\($0.overallRank) \($0.title)" + ($0.subtitle.map { " — \($0)" } ?? "") }
        return ShareNativeChart(
            id: "trends.rankings", caption: "Your top \(data.topN) \(noun) rising and falling, by \(data.bucketing.label).",
            footnote: "#1 is at the top. A gap means it fell out of that \(data.bucketing.label)’s top \(data.topN).", preferredSize: .wide,
            controls: controls, textLines: lines, zoomForShape: wideBias
        ) { layout, options, _ in
            AnyView(ShareRankBumpChart(
                data: data, lines: options.number("lines", data.topN), legend: options.flag("legend", true), points: options.flag("points", true), height: layout.logical.height
            ))
        }
    }

    // MARK: Long tail

    static func longTail(data: TrendsLongTail, entity: QueryTarget, metric: LongTailMetric, topPercent: Int) -> ShareNativeChart {
        let noun = entity.rawValue + "s"
        var caption = "How your listening is spread across your \(noun)."
        var lines: [String] = []
        if let concentration = data.concentration(topPercent: topPercent) {
            caption = "The top \(topPercent)% of your \(noun) (\(concentration.topCount.formatted())) account for \(concentration.share.formatted(.number.precision(.fractionLength(0...1))))% of \(data.concentrationMetric == .timeListened ? "time listened" : "plays")."
        }
        if let stats = data.stats {
            lines = ["Min \(metric.format(stats.min)), max \(metric.format(stats.max)), mean \(metric.formatAverage(stats.mean)), median \(metric.formatAverage(stats.median)), mode \(metric.format(stats.mode))", "\(data.values.count.formatted()) \(noun)"]
        }
        let controls = [ShareNativeControl(id: "stats", label: "Show the figures", kind: .toggle(defaultValue: true))]
        return ShareNativeChart(
            id: "trends.longTail", caption: caption, footnote: "Each bar counts the \(noun) whose \(metric.label.lowercased()) fall in that range.", preferredSize: .square,
            controls: controls, textLines: lines, zoomForShape: { $0 == .wide ? 1.6 : 1.8 }
        ) { layout, options, _ in
            AnyView(ShareLongTailChart(data: data, noun: noun, metric: metric, stats: options.flag("stats", true), layout: layout))
        }
    }

    // MARK: Eras

    static func eras(data: TrendsDecadeRiver, colors: [Color]) -> ShareNativeChart {
        var controls = [legendToggle()]
        if data.comparePoints != nil { controls.insert(compareToggle(), at: 0) }
        var caption = "Which decades your listening comes from, by \(data.bucketing.label)."
        let totals = data.presentDecades.map { decade in (decade, data.points.reduce(0) { $0 + $1.counts[decade] }) }
        let all = max(1, totals.reduce(0) { $0 + $1.1 })
        var lines: [String] = []
        if let top = totals.max(by: { $0.1 < $1.1 }) {
            caption = "Mostly the \(TrendsDecadeRiver.decades[top.0]): \(Int((Double(top.1) / Double(all) * 100).rounded()))% of what you played came out then."
        }
        lines = totals.sorted { $0.1 > $1.1 }.map { "\(TrendsDecadeRiver.decades[$0.0]): \(Int((Double($0.1) / Double(all) * 100).rounded()))%" }
        return ShareNativeChart(
            id: "trends.eras", caption: caption, footnote: "Each band is a decade of release; plays with no release date on record are left out.", preferredSize: .wide,
            controls: controls, textLines: lines, zoomForShape: wideBias
        ) { layout, options, _ in
            AnyView(ShareErasChart(data: data, colors: colors, compare: options.flag("compare", false), legend: options.flag("legend", true), height: layout.logical.height))
        }
    }

    // MARK: Taste

    static func taste(tags: TrendsTags, metric: TrendsMetric) -> ShareNativeChart {
        var controls = [
            ShareNativeControl(id: "rows", label: "Tags", kind: .count(range: 3...15, defaultValue: 8)),
            ShareNativeControl(id: "bars", label: "Show the bars", kind: .toggle(defaultValue: true)),
        ]
        if tags.compareRange != nil { controls.insert(compareToggle(), at: 1) }
        let caption = tags.rows.first.map { "\($0.tag.capitalized) leads: \(TrendsWeight.format($0.plays, metric: metric))." } ?? "The genres and tags your listening falls under."
        let lines = tags.rows.map { "\($0.tag.capitalized): \(TrendsWeight.format($0.plays, metric: metric))" }
        return ShareNativeChart(
            id: "trends.taste", caption: caption,
            footnote: tags.lookedUpShare < 0.995 ? "Tags are known for \((tags.lookedUpShare * 100).formatted(.number.precision(.fractionLength(0))))% of this period’s plays so far." : "Each play counts toward every tag of its track.",
            preferredSize: .portrait, controls: controls, textLines: lines, zoomForShape: { $0 == .wide ? 1.6 : 1.9 }
        ) { layout, options, _ in
            AnyView(ShareTagBars(tags: tags, metric: metric, count: options.number("rows", 8), changes: options.flag("compare", false), bars: options.flag("bars", true), layout: layout))
        }
    }

    // MARK: Loyalty

    static func loyalty(
        noun: String, quadrants: [(quadrant: LoyaltyQuadrant, count: Int, tops: [LoyaltyItem])], population: Int, minPlays: Int, metric: TrendsMetric
    ) -> ShareNativeChart {
        let controls = [
            ShareNativeControl(id: "top", label: "Names in each", kind: .count(range: 1...6, defaultValue: 4)),
            ShareNativeControl(id: "summary", label: "Show what each means", kind: .toggle(defaultValue: true)),
        ]
        let biggest = quadrants.max { $0.count < $1.count }
        let caption = biggest.map { "Most of your \(noun) are \($0.quadrant.label.lowercased()): \($0.count.formatted()) of \(population.formatted())." } ?? "Which of your \(noun) you keep coming back to, and which were a passing phase."
        let lines = quadrants.map { "\($0.quadrant.label): \($0.count.formatted()) (\($0.tops.prefix(3).map(\.title).joined(separator: ", ")))" }
        return ShareNativeChart(
            id: "trends.loyalty", caption: caption,
            footnote: "Of the \(population.formatted()) \(noun) with \(minPlays)+ plays: the medians of plays and of how long they were played for divide them into four.",
            preferredSize: .square, controls: controls, textLines: lines, zoomForShape: { $0 == .wide ? 1.5 : 1.8 }
        ) { layout, options, _ in
            AnyView(ShareLoyaltyQuadrants(quadrants: quadrants, metric: metric, tops: options.number("top", 4), summary: options.flag("summary", true), layout: layout))
        }
    }

    // MARK: Flow

    static func flow(data: TrendsFlow, noun: String, gapText: String) -> ShareNativeChart {
        let edges = data.edges.filter { $0.status != .dropped }
        var controls = [
            ShareNativeControl(id: "rows", label: "Hand-offs", kind: .count(range: 3...10, defaultValue: 6)),
            ShareNativeControl(id: "bars", label: "Show the bars", kind: .toggle(defaultValue: true)),
        ]
        if data.comparing { controls.append(compareToggle()) }
        let caption = edges.first.map { "\($0.source) → \($0.target) is your strongest hand-off: \($0.count.formatted()) times." } ?? "What you tend to play right after what."
        let lines = edges.prefix(10).map { "\($0.source) → \($0.target): \($0.count.formatted())" }
        return ShareNativeChart(
            id: "trends.flow", caption: caption,
            footnote: "\(data.sessionCount.formatted()) listening sessions, \(data.totalTransitions.formatted()) hand-offs from one \(noun) to another, with a \(gapText) session gap. A → B means B was the very next thing you played after A.",
            preferredSize: .portrait, controls: controls, textLines: lines, zoomForShape: { $0 == .wide ? 1.6 : 1.9 }
        ) { layout, options, _ in
            AnyView(ShareFlowList(edges: Array(edges), comparing: data.comparing, count: options.number("rows", 6), bars: options.flag("bars", true), changes: options.flag("compare", false), layout: layout))
        }
    }
}

// MARK: - The drawings

struct ShareVolumeChart: View {
    let volume: TrendsVolume
    let metric: TrendsMetric
    let running: Bool
    let compare: Bool
    let area: Bool
    let height: CGFloat

    private func value(_ p: TrendsVolume.Point) -> Int { running ? p.cumulative : p.count }
    private func compareValue(_ p: TrendsVolume.Point) -> Int? { running ? p.cumulativeCompare : p.compareCount }

    var body: some View {
        Chart {
            ForEach(volume.points) { p in
                if area {
                    AreaMark(x: .value("Date", p.start), y: .value("Value", value(p)), series: .value("Series", "Selected"))
                        .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.4), Color.accentColor.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                }
                LineMark(x: .value("Date", p.start), y: .value("Value", value(p)), series: .value("Series", "Selected"))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.2))
                    .interpolationMethod(.monotone)
                if compare, let other = compareValue(p) {
                    LineMark(x: .value("Date", p.start), y: .value("Value", other), series: .value("Series", "Previous"))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1.6, dash: [4, 3]))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.12))
                AxisValueLabel { if let v = value.as(Int.self) { Text(metric == .plays ? v.formatted() : TrendsDuration.formatCompact(v)) } }
            }
        }
        .frame(height: max(120, height))
    }
}

struct ShareHeatmapGrid: View {
    let heatmap: TrendsHeatmap
    let layout: ShareNativeLayout
    let compare: Bool
    let hours: Bool
    let legend: Bool

    private static let rows: [(label: String, day: Int)] = [("Mon", 1), ("Tue", 2), ("Wed", 3), ("Thu", 4), ("Fri", 5), ("Sat", 6), ("Sun", 0)]

    private func shortHour(_ hour: Int) -> String { hour == 0 ? "12a" : hour == 12 ? "12p" : hour < 12 ? "\(hour)a" : "\(hour - 12)p" }

    private func grid(title: String?, counts: [Int], cell: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title { Text(title).font(AppTypography.metadata.weight(.semibold)).foregroundStyle(.secondary) }
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                if hours {
                    GridRow {
                        Color.clear.frame(width: 30, height: 12)
                        ForEach(0..<24, id: \.self) { hour in
                            Text(hour % 3 == 0 ? shortHour(hour) : "").font(AppTypography.denseBadge).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        }
                    }
                }
                ForEach(Self.rows, id: \.day) { row in
                    GridRow {
                        Text(row.label).font(AppTypography.compactMetadata).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                        ForEach(0..<24, id: \.self) { hour in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(HeatColorScale.cellColor(count: counts[row.day * 24 + hour], thresholds: heatmap.thresholds, hour: hour))
                                .frame(height: cell)
                        }
                    }
                }
            }
        }
    }

    var body: some View {
        let showCompare = compare && heatmap.compareCounts != nil
        let grids = showCompare ? 2 : 1
        let extra: CGFloat = (hours ? 14 : 0) + (legend ? 22 : 0) + (showCompare ? 22 : 0)
        let cell = max(12, min(48, (layout.logical.height - extra * CGFloat(grids) - CGFloat(grids) * 18) / CGFloat(7 * grids)))
        VStack(alignment: .leading, spacing: 10) {
            grid(title: showCompare ? "This period" : nil, counts: heatmap.counts, cell: cell)
            if showCompare, let other = heatmap.compareCounts, let range = heatmap.compareRange {
                grid(title: "Previous period · " + TrendsDrill.rangeLabel(from: range.from, to: range.to), counts: other, cell: cell)
            }
            if legend {
                HStack(spacing: 4) {
                    Text("Fewer").font(AppTypography.denseBadge).foregroundStyle(.secondary)
                    ForEach(0..<8, id: \.self) { level in
                        RoundedRectangle(cornerRadius: 2).fill(Color.orange.opacity([10, 20, 31, 43, 56, 70, 84, 97][level] / 100)).frame(width: 14, height: 10)
                    }
                    Text("More").font(AppTypography.denseBadge).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct ShareDiscoveryChart: View {
    let discovery: TrendsDiscovery
    let compare: Bool
    let legend: Bool
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(discovery.points) { p in
                    AreaMark(x: .value("Date", p.start), y: .value("Percent", p.newPercent), series: .value("Kind", "New"), stacking: .unstacked)
                        .foregroundStyle(Color.green.opacity(0.55)).interpolationMethod(.monotone)
                    LineMark(x: .value("Date", p.start), y: .value("Percent", p.newPercent), series: .value("Kind", "NewLine"))
                        .foregroundStyle(Color.green).lineStyle(StrokeStyle(lineWidth: 2.2)).interpolationMethod(.monotone)
                    if compare, let other = p.comparePercent {
                        LineMark(x: .value("Date", p.start), y: .value("Percent", other), series: .value("Kind", "Previous"))
                            .foregroundStyle(Color.purple).lineStyle(StrokeStyle(lineWidth: 1.6, dash: [4, 3])).interpolationMethod(.monotone)
                    }
                }
            }
            .chartYScale(domain: 0...max(10, ceil((discovery.points.map { max($0.newPercent, compare ? ($0.comparePercent ?? 0) : 0) }.max() ?? 0) / 10) * 10))
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.12))
                    AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))%") } }
                }
            }
            .frame(height: max(120, height - (legend ? 26 : 0)))
            if legend {
                HStack(spacing: 14) {
                    HStack(spacing: 4) { Circle().fill(Color.green).frame(width: 8, height: 8); Text("New").font(AppTypography.compactMetadata).foregroundStyle(.secondary) }
                    if compare, discovery.compareRange != nil {
                        HStack(spacing: 4) { Rectangle().fill(Color.purple).frame(width: 12, height: 2); Text("Previous period (% new)").font(AppTypography.compactMetadata).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }
}

struct ShareRankBumpChart: View {
    let data: TrendsRankBump
    let lines: Int
    let legend: Bool
    let points: Bool
    let height: CGFloat

    private static let palette: [Color] = [.blue, .green, .orange, .purple, .red, .teal, .pink, .yellow, .indigo, .brown]
    private var shown: [(index: Int, series: TrendsRankBump.Series)] { Array(data.series.enumerated().prefix(lines).map { ($0.offset, $0.element) }) }
    private func height(_ rank: Int) -> Double { Double(data.topN + 1 - rank) }
    private func run(_ series: TrendsRankBump.Series, _ bucket: Int) -> Int {
        guard bucket > 0 else { return 0 }
        return (1...bucket).filter { (series.ranks[safe: $0] ?? nil) != nil && (series.ranks[safe: $0 - 1] ?? nil) == nil }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(shown, id: \.series.id) { item in
                    ForEach(data.buckets) { bucket in
                        if let rank = item.series.ranks[safe: bucket.index] ?? nil {
                            LineMark(x: .value("Date", bucket.start), y: .value("Rank", height(rank)), series: .value("Item", "\(item.index)-\(run(item.series, bucket.index))"))
                                .foregroundStyle(Self.palette[item.index % Self.palette.count])
                                .lineStyle(StrokeStyle(lineWidth: 3))
                                .interpolationMethod(.linear)
                            if points {
                                PointMark(x: .value("Date", bucket.start), y: .value("Rank", height(rank)))
                                    .foregroundStyle(Self.palette[item.index % Self.palette.count]).symbolSize(55)
                            }
                        }
                    }
                }
            }
            .chartYScale(domain: 0.5...(Double(data.topN) + 0.5))
            .chartYAxis {
                AxisMarks(position: .leading, values: Array(1...data.topN)) { value in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.12))
                    AxisValueLabel { if let v = value.as(Int.self) { Text("#\(data.topN + 1 - v)") } }
                }
            }
            .frame(height: max(140, height - (legend ? CGFloat(shown.count) * 17 + 8 : 0)))
            if legend {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(shown, id: \.series.id) { item in
                        HStack(spacing: 6) {
                            Circle().fill(Self.palette[item.index % Self.palette.count]).frame(width: 8, height: 8)
                            Text("#\(item.series.overallRank)").font(AppTypography.denseBadge.monospacedDigit()).foregroundStyle(.secondary)
                            Text(item.series.title).font(AppTypography.compactMetadata).lineLimit(1)
                            if let subtitle = item.series.subtitle { Text(subtitle).font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }
                }
            }
        }
    }
}

struct ShareLongTailChart: View {
    let data: TrendsLongTail
    let noun: String
    let metric: LongTailMetric
    let stats: Bool
    let layout: ShareNativeLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if stats, let figures = data.stats {
                HStack(spacing: 8) {
                    ForEach([("Min", metric.format(figures.min)), ("Max", metric.format(figures.max)), ("Mean", metric.formatAverage(figures.mean)),
                             ("Median", metric.formatAverage(figures.median)), ("Mode", metric.format(figures.mode))], id: \.0) { item in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.0).font(AppTypography.denseBadge).foregroundStyle(.secondary)
                            Text(item.1).font(AppTypography.metadata.weight(.semibold).monospacedDigit())
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            Chart {
                ForEach(data.bins) { bin in
                    BarMark(x: .value("Range", bin.label), y: .value("Count", bin.count)).foregroundStyle(Color.accentColor.opacity(0.85)).cornerRadius(2)
                }
            }
            .chartXScale(domain: data.bins.map(\.label))
            .chartXAxis { AxisMarks { _ in AxisValueLabel(orientation: .verticalReversed).font(AppTypography.chartAxis) } }
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(Color.white.opacity(0.12)); AxisValueLabel() } }
            .frame(height: max(140, layout.logical.height - (stats ? 56 : 0)))
        }
    }
}

struct ShareErasChart: View {
    let data: TrendsDecadeRiver
    let colors: [Color]
    let compare: Bool
    let legend: Bool
    let height: CGFloat

    private func river(_ points: [TrendsDecadeRiver.Point], height: CGFloat) -> some View {
        let present = data.presentDecades
        return Chart {
            ForEach(present, id: \.self) { decade in
                ForEach(points.filter { $0.total > 0 }) { point in
                    AreaMark(x: .value("Date", point.start), y: .value("Plays", point.counts[decade]), stacking: .normalized)
                        .foregroundStyle(by: .value("Decade", TrendsDecadeRiver.decades[decade]))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartForegroundStyleScale(domain: present.map { TrendsDecadeRiver.decades[$0] }, range: present.map { colors[$0 % colors.count] })
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.12))
                AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))%") } }
            }
        }
        .frame(height: max(100, height))
    }

    var body: some View {
        let both = compare && data.comparePoints != nil
        let legendHeight: CGFloat = legend ? 24 : 0
        VStack(alignment: .leading, spacing: 8) {
            if both, let other = data.comparePoints, let range = data.compareRange {
                Text("This period").font(AppTypography.metadata.weight(.semibold)).foregroundStyle(.secondary)
                river(data.points, height: (height - legendHeight - 60) / 2)
                Text("Previous period · " + TrendsDrill.rangeLabel(from: range.from, to: range.to)).font(AppTypography.metadata.weight(.semibold)).foregroundStyle(.secondary)
                river(other, height: (height - legendHeight - 60) / 2)
            } else {
                river(data.points, height: height - legendHeight - 8)
            }
            if legend {
                AskFlowLayout(spacing: 14) {
                    ForEach(data.presentDecades, id: \.self) { decade in
                        HStack(spacing: 5) {
                            Circle().fill(colors[decade % colors.count]).frame(width: 8, height: 8)
                            Text(TrendsDecadeRiver.decades[decade]).font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

struct ShareTagBars: View {
    let tags: TrendsTags
    let metric: TrendsMetric
    let count: Int
    let changes: Bool
    let bars: Bool
    let layout: ShareNativeLayout

    private var rows: [TrendsTags.Row] { Array(tags.rows.prefix(count)) }
    private var maximum: Int { max(1, rows.map { max($0.plays, $0.comparePlays ?? 0) }.max() ?? 1) }

    var body: some View {
        let rowHeight = max(30, min(84, (layout.logical.height - CGFloat(rows.count - 1) * 10) / CGFloat(max(rows.count, 1))))
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows) { row in
                let diff: Double? = (row.comparePlays ?? 0) > 0 ? (Double(row.plays) - Double(row.comparePlays ?? 0)) / Double(row.comparePlays ?? 1) * 100 : nil
                let tint: Color = diff.map { $0 > 0 ? .green : $0 < 0 ? .red : .accentColor } ?? .accentColor
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(row.tag.capitalized).font(AppTypography.metadata.weight(.semibold)).lineLimit(1)
                        Spacer()
                        Text(TrendsWeight.format(row.plays, metric: metric)).font(AppTypography.metadata.monospacedDigit()).foregroundStyle(.secondary)
                        if changes, let diff {
                            Text((diff >= 0 ? "+" : "") + diff.formatted(.number.precision(.fractionLength(1))) + "%")
                                .font(AppTypography.metadata.monospacedDigit()).foregroundStyle(diff >= 0 ? Color.green : Color.red).frame(minWidth: 56, alignment: .trailing)
                        }
                    }
                    if bars {
                        GeometryReader { geo in
                            let scale = geo.size.width / CGFloat(maximum)
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.10))
                                RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.9)).frame(width: max(2, CGFloat(row.plays) * scale))
                                if changes, let compare = row.comparePlays { Rectangle().fill(Color.purple).frame(width: 2).offset(x: max(0, CGFloat(compare) * scale - 1)) }
                            }
                        }
                        .frame(height: min(14, rowHeight / 3))
                    }
                }
                .frame(minHeight: rowHeight - 10, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct ShareLoyaltyQuadrants: View {
    let quadrants: [(quadrant: LoyaltyQuadrant, count: Int, tops: [LoyaltyItem])]
    let metric: TrendsMetric
    let tops: Int
    let summary: Bool
    let layout: ShareNativeLayout

    private static let colors: [LoyaltyQuadrant: Color] = [.lifers: .green, .obsessions: .red, .background: .blue, .passing: .purple]

    var body: some View {
        // Obsessions and lifers on top (played a lot), background and passing below, as the map reads.
        let order: [LoyaltyQuadrant] = [.obsessions, .lifers, .passing, .background]
        let byQuadrant = Dictionary(uniqueKeysWithValues: quadrants.map { ($0.quadrant, $0) })
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(order) { quadrant in
                let entry = byQuadrant[quadrant]
                let tint = Self.colors[quadrant] ?? .gray
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Circle().fill(tint).frame(width: 10, height: 10)
                        Text(quadrant.label).font(AppTypography.metadata.weight(.semibold))
                        Spacer()
                        Text((entry?.count ?? 0).formatted()).font(AppTypography.compactTitle.monospacedDigit())
                    }
                    if summary { Text(quadrant.summary).font(AppTypography.compactMetadata).foregroundStyle(.secondary) }
                    ForEach(Array((entry?.tops ?? []).prefix(tops).enumerated()), id: \.element.id) { _, item in
                        HStack(spacing: 4) {
                            Text(item.title).font(AppTypography.compactMetadata).lineLimit(1)
                            if let subtitle = item.subtitle { Text(subtitle).font(AppTypography.denseBadge).foregroundStyle(.secondary).lineLimit(1) }
                            Spacer(minLength: 4)
                            Text(TrendsWeight.format(item.value, metric: metric)).font(AppTypography.denseBadge.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: max(120, (layout.logical.height - 10) / 2), alignment: .topLeading)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(tint.opacity(0.35), lineWidth: 1) }
            }
        }
    }
}

struct ShareFlowList: View {
    let edges: [TrendsFlow.Edge]
    let comparing: Bool
    let count: Int
    let bars: Bool
    let changes: Bool
    let layout: ShareNativeLayout

    var body: some View {
        let shown = Array(edges.prefix(count))
        let maximum = Double(shown.first?.count ?? 1)
        let rowHeight = max(34, min(84, (layout.logical.height - CGFloat(max(shown.count - 1, 0)) * 10) / CGFloat(max(shown.count, 1))))
        VStack(alignment: .leading, spacing: 10) {
            ForEach(shown) { edge in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(edge.source).font(AppTypography.metadata.weight(.semibold)).lineLimit(1)
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        Text(edge.target).font(AppTypography.metadata.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(edge.count.formatted()).font(AppTypography.metadata.monospacedDigit()).foregroundStyle(.secondary)
                        if changes, comparing { badge(edge) }
                    }
                    if bars {
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.85)).frame(width: max(3, geo.size.width * Double(edge.count) / maximum))
                        }
                        .frame(height: 7)
                    }
                }
                .frame(minHeight: rowHeight - 10, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func badge(_ edge: TrendsFlow.Edge) -> some View {
        switch edge.status {
        case .new: Text("new").font(AppTypography.denseBadge).foregroundStyle(.green)
        case .dropped: Text("gone").font(AppTypography.denseBadge).foregroundStyle(.red)
        case .shared:
            let delta = edge.count - (edge.previousCount ?? edge.count)
            if delta != 0 { Text((delta > 0 ? "+" : "") + delta.formatted()).font(AppTypography.denseBadge.monospacedDigit()).foregroundStyle(delta > 0 ? Color.green : Color.red) }
        }
    }
}
