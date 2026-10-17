import SwiftUI
import Charts

/// Share of listening by release decade over time, as a 100% stacked area (and the comparison period beneath it).
/// A click on a band opens Query on what was played from that decade in that week / month / year.
struct TrendsDecadeRiverChart: View {
    struct Inputs: Equatable {
        let scrobbles: [ScrobbleSnapshot]
        let snapshots: QuerySnapshots
        let range: DateRange
        let compareRange: DateRange?
        let version: Int
        static func == (a: Inputs, b: Inputs) -> Bool { a.range == b.range && a.compareRange == b.compareRange && a.version == b.version }
    }

    let inputs: Inputs
    let openQuery: (QuerySpec, String) -> Void

    @AppStorage("trends.decadeRiver.entity") private var entityRaw = QueryTarget.track.rawValue
    @AppStorage("trends.decadeRiver.view") private var viewRaw = ViewMode.river.rawValue
    @AppStorage("trends.decadeRiver.metric") private var metricRaw = TrendsMetric.plays.rawValue
    @State private var data: TrendsDecadeRiver?
    @Environment(\.shareChartCapture) private var shareCapture
    @State private var isLoading = true
    @State private var hovered: (grid: Int, point: TrendsDecadeRiver.Point)?

    private enum ViewMode: String, CaseIterable, Identifiable {
        case river = "By decade", grid = "By release year"
        var id: String { rawValue }
    }
    private var viewMode: ViewMode { ViewMode(rawValue: viewRaw) ?? .river }

    private var entity: QueryTarget { QueryTarget(rawValue: entityRaw) == .album ? .album : .track }
    private var metric: TrendsMetric { TrendsMetric(rawValue: metricRaw) ?? .plays }
    private static let colors: [Color] = [.blue, .orange, .green, Color(red: 0.95, green: 0.35, blue: 0.75), .purple, .yellow, Color(red: 0.9, green: 0.25, blue: 0.25)]
    private struct ComputeKey: Equatable { let entity: QueryTarget; let metric: TrendsMetric; let inputs: Inputs }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Picker("Kind", selection: Binding(get: { entity }, set: { entityRaw = $0.rawValue })) {
                    Text("Albums").tag(QueryTarget.album)
                    Text("Tracks").tag(QueryTarget.track)
                }
                .pickerStyle(.segmented).labelsHidden()
                Picker("View", selection: $viewRaw) {
                    ForEach(ViewMode.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .help("By decade: each \(data?.bucketing.label ?? "month")’s share of listening by decade of release, as a stacked river. By release year: the same listening as a grid of when you listened against the exact year released.")
                Picker("Metric", selection: $metricRaw) {
                    ForEach(TrendsMetric.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Spacer()
                if let data { Text("By \(data.bucketing.label)").font(AppTypography.metadata).foregroundStyle(.secondary) }
            }
            if let data, viewMode == .grid, data.points.count >= 2, !data.presentDecades.isEmpty {
                TrendsTimeTravelGrid(data: data, openQuery: openQuery)
                    .shareChartArea()
                notes(data)
            } else if let data, data.points.count >= 2, !data.presentDecades.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        if data.comparePoints != nil { Text("This period").font(AppTypography.metadata.weight(.semibold)).foregroundStyle(.secondary) }
                        river(data.points, data: data, grid: 0).frame(height: data.comparePoints != nil ? 200 : 260)
                    }
                    if let compare = data.comparePoints, let compareRange = data.compareRange {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Previous period · " + TrendsDrill.rangeLabel(from: compareRange.from, to: compareRange.to))
                                .font(AppTypography.metadata.weight(.semibold)).foregroundStyle(.secondary)
                            if compare.contains(where: { $0.total > 0 }) {
                                river(compare, data: data, grid: 1).frame(height: 200)
                            } else {
                                Text("No listening with a known release date in the previous period.").font(AppTypography.metadata).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .shareChartArea()
                legend(data)
                notes(data)
                Text("Click a band to see what you played from that decade in that \(data.bucketing.label).")
                    .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 220)
            } else {
                ContentUnavailableView(
                    (data?.pending ?? 0) > 0 ? "Release dates are still being looked up" : "Nothing to show yet", systemImage: "calendar",
                    description: Text((data?.pending ?? 0) > 0 ? "They come from a lookup that runs in the background; this fills in as they arrive." : "Try a wider date range — this needs at least two weeks, months or years with known release dates.")
                )
                .frame(minHeight: 200)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.45), lineWidth: 1) }
        .task(id: ComputeKey(entity: entity, metric: metric, inputs: inputs), priority: .utility) { await recompute() }
    }

    private func river(_ points: [TrendsDecadeRiver.Point], data: TrendsDecadeRiver, grid: Int) -> some View {
        let present = data.presentDecades
        return Chart {
            ForEach(present, id: \.self) { decade in
                ForEach(points.filter { $0.total > 0 }) { point in
                    AreaMark(x: .value("Date", point.start), y: .value("Plays", point.counts[decade]), stacking: .normalized)
                        .foregroundStyle(by: .value("Decade", TrendsDecadeRiver.decades[decade]))
                        .interpolationMethod(.monotone)
                }
            }
            if let hovered, hovered.grid == grid {
                RuleMark(x: .value("Date", hovered.point.start))
                    .foregroundStyle(Color.primary.opacity(0.5))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) { tooltip(hovered.point, data) }
            }
        }
        .chartForegroundStyleScale(domain: present.map { TrendsDecadeRiver.decades[$0] }, range: present.map { Self.colors[$0] })
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))%") } }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): hovered = pick(location, proxy: proxy, geo: geo, points: points).map { (grid, $0.point) }
                        case .ended: hovered = nil
                        }
                    }
                    .onTapGesture { location in
                        guard let hit = pick(location, proxy: proxy, geo: geo, points: points), let decade = hit.decade else { return }
                        openQuery(
                            TrendsDrill.decadeBucket(target: data.target, decade: decade, from: hit.point.from, to: hit.point.to, metric: metric),
                            "\(TrendsDecadeRiver.decades[decade]) · " + data.bucketing.name(hit.point.start)
                        )
                    }
            }
        }
    }

    /// The bucket under the pointer, and the decade band at its height (bands stack oldest at the bottom).
    private func pick(_ location: CGPoint, proxy: ChartProxy, geo: GeometryProxy, points: [TrendsDecadeRiver.Point]) -> (point: TrendsDecadeRiver.Point, decade: Int?)? {
        guard let plot = proxy.plotFrame else { return nil }
        let frame = geo[plot]
        guard let date: Date = proxy.value(atX: location.x - frame.origin.x) else { return nil }
        let candidates = points.filter { $0.total > 0 }
        guard let point = candidates.min(by: { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }) else { return nil }
        let fraction = 1 - (location.y - frame.origin.y) / frame.height
        var running = 0.0
        for decade in 0..<TrendsDecadeRiver.decades.count where point.counts[decade] > 0 {
            running += Double(point.counts[decade]) / Double(point.total)
            if fraction <= running { return (point, decade) }
        }
        return (point, nil)
    }

    private func tooltip(_ point: TrendsDecadeRiver.Point, _ data: TrendsDecadeRiver) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(data.bucketing.name(point.start)).font(AppTypography.metadata.weight(.semibold))
            ForEach((0..<TrendsDecadeRiver.decades.count).reversed().filter { point.counts[$0] > 0 }, id: \.self) { decade in
                HStack(spacing: 6) {
                    Circle().fill(Self.colors[decade]).frame(width: 7, height: 7)
                    Text(TrendsDecadeRiver.decades[decade]).font(AppTypography.compactMetadata)
                    Spacer(minLength: 8)
                    Text((Double(point.counts[decade]) / Double(point.total) * 100).formatted(.number.precision(.fractionLength(0))) + "%")
                        .font(AppTypography.compactMetadata.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(8).frame(minWidth: 170)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.5)) }
    }

    private func legend(_ data: TrendsDecadeRiver) -> some View {
        AskFlowLayout(spacing: 14) {
            ForEach(data.presentDecades, id: \.self) { decade in
                HStack(spacing: 5) {
                    Circle().fill(Self.colors[decade]).frame(width: 8, height: 8)
                    Text(TrendsDecadeRiver.decades[decade]).font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func notes(_ data: TrendsDecadeRiver) -> some View {
        let pending = data.pending + data.comparePending
        let waitingOn = data.metric == .plays ? "a release date" : "a release date or a track length"
        if pending > 0 {
            Label("\(pending.formatted()) plays are still waiting for \(waitingOn) and aren’t counted yet — the shape sharpens as they’re found.", systemImage: "hourglass")
                .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
        }
        if data.noDate > 0 {
            Label("\(data.noDate.formatted()) plays have no release date on record and are left out.", systemImage: "questionmark.circle")
                .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
        }
    }

    private func recompute() async {
        isLoading = true
        let (target, metric, inputs) = (entity, self.metric, self.inputs)
        let computed = await TrendsComputeGate.shared.run {
            TrendsDecadeRiverEngine.compute(scrobbles: inputs.scrobbles, snapshots: inputs.snapshots, target: target, range: inputs.range, compareRange: inputs.compareRange, metric: metric)
        }
        guard !Task.isCancelled, let computed else { return }
        data = computed
        isLoading = false
        // The decades' colours, as the legend under the chart gives them, in readable type on a shared card.
        shareCapture?.summary = computed.map { eras in
            ShareChartSummary(
                headline: "Eras", detail: "By \(eras.bucketing.label) · \(metric == .plays ? "by scrobbles" : "by time listened")",
                legend: eras.presentDecades.map { ShareChartSummary.Legend(label: TrendsDecadeRiver.decades[$0], color: Self.colors[$0]) }
            )
        }
    }
}
