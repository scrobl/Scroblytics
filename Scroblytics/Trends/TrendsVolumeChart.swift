import SwiftUI
import Charts

/// Scrobbles per bucket (or the running total), with the comparison period overlaid. Hover names a bucket and
/// its numbers; clicking one opens Query on the artists, albums or tracks played in it. Weighs by plays or by
/// time listened — its own choice, remembered, computed only when picked (time listened needs every play's
/// runtime, which is looked up lazily and may still be pending).
struct TrendsVolumeChart: View {
    struct Inputs: Equatable {
        let scrobbles: [ScrobbleSnapshot]
        let durations: DurationEngine.Snapshot
        let range: DateRange
        let compareRange: DateRange?
        let version: Int
        static func == (a: Inputs, b: Inputs) -> Bool { a.range == b.range && a.compareRange == b.compareRange && a.version == b.version }
    }

    let inputs: Inputs
    let openQuery: (QuerySpec, String) -> Void

    private enum Mode: String, CaseIterable, Identifiable {
        case perPeriod = "Per period", cumulative = "Running total"
        var id: String { rawValue }
    }

    @AppStorage("trends.volume.mode") private var mode: Mode = .perPeriod
    @AppStorage("trends.volume.metric") private var metricRaw = TrendsMetric.plays.rawValue
    /// Which kind of thing a click opens in Query; remembered between launches.
    @AppStorage("trends.volume.drillTarget") private var drillTargetRaw = QueryTarget.track.rawValue
    private var drillTarget: QueryTarget { QueryTarget(rawValue: drillTargetRaw) ?? .track }
    private var drillTargetBinding: Binding<QueryTarget> {
        Binding(get: { drillTarget }, set: { drillTargetRaw = $0.rawValue })
    }
    private var metric: TrendsMetric { TrendsMetric(rawValue: metricRaw) ?? .plays }
    @State private var volume: TrendsVolume?
    @State private var isLoading = true
    @State private var hovered: TrendsVolume.Point?
    @Environment(\.shareChartCapture) private var shareCapture

    private struct ComputeKey: Equatable { let metric: TrendsMetric; let inputs: Inputs }
    private struct NativeKey: Equatable { let compute: ComputeKey; let ready: Bool; let mode: Mode }

    private func value(_ p: TrendsVolume.Point) -> Int { mode == .perPeriod ? p.count : p.cumulative }
    private func compareValue(_ p: TrendsVolume.Point) -> Int? { mode == .perPeriod ? p.compareCount : p.cumulativeCompare }
    private func format(_ v: Int) -> String { TrendsWeight.format(v, metric: metric) }
    private var unitWord: String { metric == .plays ? "scrobbles" : "listened" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if let volume {
                    Text("\(format(volume.total)) \(unitWord)").font(AppTypography.entityTitle.monospacedDigit())
                    if let change = volume.changeLabel {
                        Text("\(change) vs \(volume.compareRange.map { TrendsDrill.rangeLabel(from: $0.from, to: $0.to) } ?? "previous")")
                            .font(AppTypography.metadata)
                            .foregroundStyle(change.hasPrefix("+") ? Color.green : Color.red)
                    }
                }
                Spacer()
                Picker("Metric", selection: $metricRaw) {
                    ForEach(TrendsMetric.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Picker("Show", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }

            if let volume {
                chart(volume).frame(height: 260).shareChartArea()
                if metric == .timeListened, volume.pending > 0 {
                    Label("\(volume.pending.formatted()) plays are still waiting for a track length and aren’t counted yet.", systemImage: "hourglass")
                        .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Text("Click a point to see what you played in it, as")
                        .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                    Picker("Open as", selection: drillTargetBinding) {
                        Text("Artists").tag(QueryTarget.artist)
                        Text("Albums").tag(QueryTarget.album)
                        Text("Tracks").tag(QueryTarget.track)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Spacer()
                    Button("Open whole period in Query") { drill(from: volume.range.from, to: volume.range.to, detail: "Scrobbles · " + TrendsDrill.rangeLabel(from: volume.range.from, to: volume.range.to)) }
                        .buttonStyle(.borderless)
                }
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 220)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.45), lineWidth: 1) }
        .task(id: ComputeKey(metric: metric, inputs: inputs), priority: .utility) { await recompute() }
        .shareNative(id: NativeKey(compute: ComputeKey(metric: metric, inputs: inputs), ready: volume != nil, mode: mode)) {
            volume.map { TrendsShareCharts2.volume(volume: $0, metric: metric, mode: mode.rawValue) }
        }
    }

    private func chart(_ volume: TrendsVolume) -> some View {
        Chart {
            ForEach(volume.points) { p in
                AreaMark(x: .value("Date", p.start), y: .value("Value", value(p)), series: .value("Series", "Selected"))
                    .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Date", p.start), y: .value("Value", value(p)), series: .value("Series", "Selected"))
                    .foregroundStyle(Color.accentColor)
                    .interpolationMethod(.monotone)
                if let compare = compareValue(p) {
                    LineMark(x: .value("Date", p.start), y: .value("Value", compare), series: .value("Series", "Previous"))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .interpolationMethod(.monotone)
                }
            }
            if let hovered {
                RuleMark(x: .value("Date", hovered.start))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) { tooltip(hovered, volume) }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let v = value.as(Int.self) { Text(metric == .plays ? v.formatted() : TrendsDuration.formatCompact(v)) } }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): hovered = point(at: location, proxy: proxy, geo: geo, volume: volume)
                        case .ended: hovered = nil
                        }
                    }
                    .onTapGesture { location in
                        guard let p = point(at: location, proxy: proxy, geo: geo, volume: volume) else { return }
                        drill(from: p.from, to: p.to, detail: "Scrobbles · " + TrendsDrill.label(start: p.start, granularity: volume.granularity))
                    }
            }
        }
    }

    private func point(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy, volume: TrendsVolume) -> TrendsVolume.Point? {
        guard let plot = proxy.plotFrame else { return nil }
        let x = location.x - geo[plot].origin.x
        guard let date: Date = proxy.value(atX: x) else { return nil }
        return volume.points.min { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }
    }

    private func tooltip(_ p: TrendsVolume.Point, _ volume: TrendsVolume) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(TrendsDrill.label(start: p.start, granularity: volume.granularity)).font(AppTypography.metadata.weight(.semibold))
            Text("\(format(value(p))) \(unitWord)").font(AppTypography.metadata.monospacedDigit())
            if let compare = compareValue(p), let compareStart = p.compareStart {
                Text("\(format(compare)) · " + TrendsDrill.label(start: compareStart, granularity: volume.granularity))
                    .font(AppTypography.compactMetadata.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.5)) }
    }

    private func drill(from: Date, to: Date, detail: String) {
        let spec = TrendsDrill.spec(from: from, to: to, target: drillTarget)
        openQuery(spec, detail)
    }

    private func recompute() async {
        isLoading = true
        let (metric, inputs) = (self.metric, self.inputs)
        let computed = await TrendsComputeGate.shared.run {
            TrendsEngine.volume(scrobbles: inputs.scrobbles, range: inputs.range, compareRange: inputs.compareRange, metric: metric, durations: inputs.durations)
        }
        guard !Task.isCancelled, let computed else { return }
        volume = computed
        isLoading = false
        // The same headline the chart shows above itself, for a shared card.
        let comparedWith = computed.compareRange.map { TrendsDrill.rangeLabel(from: $0.from, to: $0.to) } ?? "previous"
        shareCapture?.summary = ShareChartSummary(
            headline: "\(TrendsWeight.format(computed.total, metric: metric)) \(metric == .plays ? "scrobbles" : "listened")",
            change: computed.changeLabel.map { "\($0) vs \(comparedWith)" }, isUp: computed.changeLabel?.hasPrefix("+") ?? true
        )
    }
}
