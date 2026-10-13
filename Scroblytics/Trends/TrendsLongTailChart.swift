import SwiftUI
import Charts

/// How a metric is spread across everything you played in the period — most things sit at the low end, with a long
/// thin tail of favourites. A bar opens Query on the artists, albums or tracks in that range.
struct TrendsLongTailChart: View {
    /// What the chart is drawn from; `version` changes when the underlying data does.
    struct Inputs: Equatable {
        let scrobbles: [ScrobbleSnapshot]
        let snapshots: QuerySnapshots
        let range: DateRange
        let version: Int
        static func == (a: Inputs, b: Inputs) -> Bool { a.range == b.range && a.version == b.version }
    }

    let inputs: Inputs
    let openQuery: (QuerySpec, String) -> Void

    @AppStorage("trends.longTail.entity") private var entityRaw = QueryTarget.track.rawValue
    @AppStorage("trends.longTail.metric") private var metricRaw = LongTailMetric.plays.rawValue
    @AppStorage("trends.longTail.topPercent") private var topPercent = 10
    @State private var data: TrendsLongTail?
    @State private var isLoading = true
    @State private var hovered: LongTailBin?

    private var entity: QueryTarget { QueryTarget(rawValue: entityRaw) ?? .track }
    private var metric: LongTailMetric {
        let m = LongTailMetric(rawValue: metricRaw) ?? .plays
        return LongTailMetric.available(for: entity).contains(m) ? m : .plays
    }
    private var noun: String { entity.rawValue + "s" }

    private struct ComputeKey: Equatable { let entity: QueryTarget; let metric: LongTailMetric; let inputs: Inputs }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            controls
            if let data, let stats = data.stats {
                statRow(stats, data: data)
                chart(data).frame(height: 240)
                if let conc = data.concentration(topPercent: topPercent) { concentrationLine(data, conc) }
                if data.pending > 0 { pendingNote(data) }
                Text("Click a bar to see the \(noun) in that range.").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 240)
            } else {
                ContentUnavailableView(
                    (data?.pending ?? 0) > 0 ? "Still looking up track lengths" : "No data in this period",
                    systemImage: "chart.bar",
                    description: Text((data?.pending ?? 0) > 0 ? "Lengths come from a lookup that runs in the background; this fills in as they arrive." : "Try a wider date range.")
                )
                .frame(minHeight: 200)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.45), lineWidth: 1) }
        .task(id: ComputeKey(entity: entity, metric: metric, inputs: inputs), priority: .utility) { await recompute() }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Kind", selection: Binding(get: { entity }, set: { entityRaw = $0.rawValue })) {
                Text("Artists").tag(QueryTarget.artist)
                Text("Albums").tag(QueryTarget.album)
                Text("Tracks").tag(QueryTarget.track)
            }
            .pickerStyle(.segmented).labelsHidden()
            Picker("Metric", selection: Binding(get: { metric }, set: { metricRaw = $0.rawValue })) {
                ForEach(LongTailMetric.available(for: entity)) { Text($0.label).tag($0) }
            }
            .fixedSize()
            Spacer()
        }
    }

    private func statRow(_ stats: TrendsLongTail.Stats, data: TrendsLongTail) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 90), spacing: 8, alignment: .leading)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach([("Min", metric.format(stats.min)), ("Max", metric.format(stats.max)), ("Mean", metric.formatAverage(stats.mean)),
                     ("Median", metric.formatAverage(stats.median)), ("Mode", metric.format(stats.mode))], id: \.0) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.0).font(AppTypography.denseBadge).foregroundStyle(.secondary)
                    Text(item.1).font(AppTypography.metadata.weight(.semibold).monospacedDigit())
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(minWidth: 90, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            Text("\(data.values.count.formatted()) \(noun)").font(AppTypography.metadata).foregroundStyle(.secondary)
        }
    }

    private func chart(_ data: TrendsLongTail) -> some View {
        Chart {
            ForEach(data.bins) { bin in
                BarMark(x: .value("Range", bin.label), y: .value("Count", bin.count))
                    .foregroundStyle(hovered?.id == bin.id ? Color.accentColor : Color.accentColor.opacity(0.75))
                    .cornerRadius(2)
            }
        }
        .chartXScale(domain: data.bins.map(\.label))
        .chartXAxis {
            AxisMarks { _ in AxisValueLabel(orientation: .verticalReversed).font(AppTypography.chartAxis) }
        }
        .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): hovered = bin(at: location, proxy: proxy, geo: geo, data: data)
                        case .ended: hovered = nil
                        }
                    }
                    .onTapGesture { location in
                        guard let bin = bin(at: location, proxy: proxy, geo: geo, data: data) else { return }
                        openQuery(
                            TrendsDrill.longTailBin(target: entity, metric: metric, bin: bin, range: data.range),
                            "\(metric.label) \(bin.label) · " + TrendsDrill.rangeLabel(from: data.range.from, to: data.range.to)
                        )
                    }
            }
        }
        .overlay(alignment: .topTrailing) {
            if let hovered {
                Text("\(hovered.count.formatted()) \(noun) · \(metric.label.lowercased()) \(hovered.label)")
                    .font(AppTypography.metadata.monospacedDigit())
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.5)) }
            }
        }
    }

    private func bin(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy, data: TrendsLongTail) -> LongTailBin? {
        guard let plot = proxy.plotFrame, let label: String = proxy.value(atX: location.x - geo[plot].origin.x) else { return nil }
        return data.bins.first { $0.label == label }
    }

    private func concentrationLine(_ data: TrendsLongTail, _ conc: (topCount: Int, share: Double)) -> some View {
        HStack(spacing: 6) {
            Text("The top")
            Menu("\(topPercent)%") {
                ForEach([5, 10, 20, 25, 50], id: \.self) { pct in Button("\(pct)%") { topPercent = pct } }
            }
            .fixedSize()
            Text("of your \(noun) (\(conc.topCount.formatted())) account for \(conc.share.formatted(.number.precision(.fractionLength(0...1))))% of \(data.concentrationMetric == .timeListened ? "time listened" : "plays").")
        }
        .font(AppTypography.metadata)
    }

    private func pendingNote(_ data: TrendsLongTail) -> some View {
        Label("\(data.pending.formatted()) \(noun) left out — their track lengths are still being looked up, so these numbers will fill in.", systemImage: "hourglass")
            .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
    }

    private func recompute() async {
        isLoading = true
        let (target, metric, inputs) = (entity, self.metric, self.inputs)
        let computed = await TrendsComputeGate.shared.run {
            TrendsLongTailEngine.compute(scrobbles: inputs.scrobbles, snapshots: inputs.snapshots, target: target, metric: metric, range: inputs.range)
        }
        guard !Task.isCancelled, let computed else { return }
        data = computed
        isLoading = false
    }
}
