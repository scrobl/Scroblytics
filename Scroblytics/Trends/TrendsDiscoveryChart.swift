import SwiftUI
import Charts

/// New tracks against repeat listens over time. "New" is a track's very first play; the rest are repeats. Clicking
/// a bucket opens Query on the tracks discovered in it. Weighs by plays (how many were new) or by time listened
/// (how much of your listening time went to something new versus something familiar).
struct TrendsDiscoveryChart: View {
    struct Inputs: Equatable {
        /// Must have canonical artist names — a track's first play is tracked across spelling variants.
        let scrobbles: [ScrobbleSnapshot]
        let durations: DurationEngine.Snapshot
        let range: DateRange
        let compareRange: DateRange?
        let version: Int
        static func == (a: Inputs, b: Inputs) -> Bool { a.range == b.range && a.compareRange == b.compareRange && a.version == b.version }
    }

    let inputs: Inputs
    let openQuery: (QuerySpec, String) -> Void

    @AppStorage("trends.discovery.metric") private var metricRaw = TrendsMetric.plays.rawValue
    private var metric: TrendsMetric { TrendsMetric(rawValue: metricRaw) ?? .plays }
    @State private var discovery: TrendsDiscovery?
    @State private var isLoading = true
    @State private var hovered: TrendsDiscovery.Point?
    private struct ComputeKey: Equatable { let metric: TrendsMetric; let inputs: Inputs }

    private func changeText(_ discovery: TrendsDiscovery) -> (text: String, positive: Bool)? {
        guard let compare = discovery.comparePercent else { return nil }
        let diff = discovery.newPercent - compare
        return ((diff >= 0 ? "+" : "") + diff.formatted(.number.precision(.fractionLength(1))) + " pts vs previous", diff >= 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if let discovery {
                    Text("\(discovery.newPercent.formatted(.number.precision(.fractionLength(1))))% new").font(AppTypography.entityTitle.monospacedDigit())
                    if metric == .plays {
                        Text("\(discovery.newTotal.formatted()) new tracks · \(discovery.repeatTotal.formatted()) repeat plays")
                            .font(AppTypography.metadata).foregroundStyle(.secondary)
                    } else {
                        Text("\(TrendsWeight.format(discovery.newTotal, metric: .timeListened)) on something new · \(TrendsWeight.format(discovery.repeatTotal, metric: .timeListened)) on repeats")
                            .font(AppTypography.metadata).foregroundStyle(.secondary)
                    }
                    if let changeText = changeText(discovery) {
                        Text(changeText.text).font(AppTypography.metadata).foregroundStyle(changeText.positive ? Color.green : Color.red)
                    }
                }
                Spacer()
                Picker("Metric", selection: $metricRaw) {
                    ForEach(TrendsMetric.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden()
                if discovery != nil { legend }
            }
            if let discovery {
                chart(discovery).frame(height: 220)
                if metric == .timeListened, discovery.pending > 0 {
                    Label("\(discovery.pending.formatted()) plays are still waiting for a track length and aren’t counted yet.", systemImage: "hourglass")
                        .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                }
                Text("Click a point to see the tracks you heard for the first time then.")
                    .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 180)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.45), lineWidth: 1) }
        .task(id: ComputeKey(metric: metric, inputs: inputs), priority: .utility) { await recompute() }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) { Circle().fill(Color.green).frame(width: 8, height: 8); Text("New").font(AppTypography.compactMetadata).foregroundStyle(.secondary) }
            HStack(spacing: 4) { Circle().fill(Color.gray.opacity(0.5)).frame(width: 8, height: 8); Text("Repeat").font(AppTypography.compactMetadata).foregroundStyle(.secondary) }
            if inputs.compareRange != nil {
                HStack(spacing: 4) { Rectangle().fill(Color.purple).frame(width: 12, height: 2); Text("Previous period (% new)").font(AppTypography.compactMetadata).foregroundStyle(.secondary) }
            }
        }
    }

    private func chart(_ discovery: TrendsDiscovery) -> some View {
        Chart {
            ForEach(discovery.points) { p in
                AreaMark(x: .value("Date", p.start), y: .value("Percent", p.newPercent), series: .value("Kind", "New"), stacking: .unstacked)
                    .foregroundStyle(Color.green.opacity(0.55))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Date", p.start), y: .value("Percent", p.newPercent), series: .value("Kind", "NewLine"))
                    .foregroundStyle(Color.green)
                    .interpolationMethod(.monotone)
                if let compare = p.comparePercent {
                    LineMark(x: .value("Date", p.start), y: .value("Percent", compare), series: .value("Kind", "Previous"))
                        .foregroundStyle(Color.purple)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .interpolationMethod(.monotone)
                }
            }
            if let hovered {
                RuleMark(x: .value("Date", hovered.start))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) { tooltip(hovered, discovery) }
            }
        }
        .chartYScale(domain: 0...max(10, ceil((discovery.points.map { max($0.newPercent, $0.comparePercent ?? 0) }.max() ?? 0) / 10) * 10))
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))%") } }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): hovered = point(at: location, proxy: proxy, geo: geo, discovery: discovery)
                        case .ended: hovered = nil
                        }
                    }
                    .onTapGesture { location in
                        guard let p = point(at: location, proxy: proxy, geo: geo, discovery: discovery) else { return }
                        openQuery(TrendsDrill.discoveries(from: p.from, to: p.to),
                                  "New tracks · " + TrendsDrill.label(start: p.start, granularity: discovery.granularity))
                    }
            }
        }
    }

    private func point(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy, discovery: TrendsDiscovery) -> TrendsDiscovery.Point? {
        guard let plot = proxy.plotFrame else { return nil }
        guard let date: Date = proxy.value(atX: location.x - geo[plot].origin.x) else { return nil }
        return discovery.points.min { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }
    }

    private func tooltip(_ p: TrendsDiscovery.Point, _ discovery: TrendsDiscovery) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(TrendsDrill.label(start: p.start, granularity: discovery.granularity)).font(AppTypography.metadata.weight(.semibold))
            Text("\(TrendsWeight.format(p.newCount, metric: metric)) new · \(TrendsWeight.format(p.repeatCount, metric: metric)) repeat").font(AppTypography.metadata.monospacedDigit())
            Text("\(p.newPercent.formatted(.number.precision(.fractionLength(1))))% new").font(AppTypography.metadata.monospacedDigit())
            if let compare = p.comparePercent {
                Text("\(compare.formatted(.number.precision(.fractionLength(1))))% new in the previous period")
                    .font(AppTypography.compactMetadata.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.5)) }
    }

    private func recompute() async {
        isLoading = true
        let (metric, inputs) = (self.metric, self.inputs)
        let computed = await TrendsComputeGate.shared.run {
            TrendsDiscoveryEngine.compute(scrobbles: inputs.scrobbles, range: inputs.range, compareRange: inputs.compareRange, metric: metric, durations: inputs.durations)
        }
        guard !Task.isCancelled, let computed else { return }
        discovery = computed
        isLoading = false
    }
}
