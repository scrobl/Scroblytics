import SwiftUI
import Charts

/// The period's top few as lines over time (#1 at the top); a gap means it fell out of that bucket's top N. Hover names
/// the bucket's standings; a click opens Query on that bucket's top N.
struct TrendsRankBumpChart: View {
    struct Inputs: Equatable {
        let scrobbles: [ScrobbleSnapshot]
        let durations: DurationEngine.Snapshot
        let range: DateRange
        let version: Int
        static func == (a: Inputs, b: Inputs) -> Bool { a.range == b.range && a.version == b.version }
    }

    let inputs: Inputs
    let openQuery: (QuerySpec, String) -> Void

    @AppStorage("trends.rankBump.entity") private var entityRaw = QueryTarget.artist.rawValue
    @AppStorage("trends.rankBump.topN") private var topN = 5
    @AppStorage("trends.rankBump.metric") private var metricRaw = TrendsMetric.plays.rawValue
    @State private var data: TrendsRankBump?
    @State private var isLoading = true
    @State private var hovered: TrendsRankBump.Bucket?

    private var entity: QueryTarget { QueryTarget(rawValue: entityRaw) ?? .artist }
    private var metric: TrendsMetric { TrendsMetric(rawValue: metricRaw) ?? .plays }
    private static let palette: [Color] = [.blue, .green, .orange, .purple, .red, .teal, .pink, .yellow, .indigo, .brown]
    private struct ComputeKey: Equatable { let entity: QueryTarget; let topN: Int; let metric: TrendsMetric; let inputs: Inputs }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            controls
            if let data, data.buckets.count >= 2 {
                chart(data).frame(height: CGFloat(max(220, data.topN * 34)))
                legend(data)
                Text("Click a \(data.bucketing.label) to see its top \(data.topN) in Query. A gap means it fell out of that \(data.bucketing.label)’s top \(data.topN).")
                    .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 220)
            } else {
                ContentUnavailableView(
                    data == nil ? "No data in this period" : "Select a wider date range", systemImage: "chart.line.uptrend.xyaxis",
                    description: Text(data == nil ? "Try a wider date range." : "This needs at least two weeks, months or years to show anything rising and falling.")
                )
                .frame(minHeight: 200)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.45), lineWidth: 1) }
        .task(id: ComputeKey(entity: entity, topN: topN, metric: metric, inputs: inputs)) { await recompute() }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Kind", selection: Binding(get: { entity }, set: { entityRaw = $0.rawValue })) {
                Text("Artists").tag(QueryTarget.artist)
                Text("Albums").tag(QueryTarget.album)
                Text("Tracks").tag(QueryTarget.track)
            }
            .pickerStyle(.segmented).labelsHidden()
            Picker("Show", selection: $topN) {
                Text("Top 5").tag(5)
                Text("Top 10").tag(10)
            }
            .pickerStyle(.segmented).labelsHidden()
            Picker("Metric", selection: $metricRaw) {
                ForEach(TrendsMetric.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Spacer()
            if let data { Text("By \(data.bucketing.label)").font(AppTypography.metadata).foregroundStyle(.secondary) }
        }
    }

    /// Which unbroken stretch of top-N buckets `bucket` belongs to: how many times the series re-entered before it.
    private func run(_ series: TrendsRankBump.Series, _ bucket: Int) -> Int {
        guard bucket > 0 else { return 0 }
        return (1...bucket).filter { (series.ranks[safe: $0] ?? nil) != nil && (series.ranks[safe: $0 - 1] ?? nil) == nil }.count
    }

    /// #1 is drawn at the top: the vertical position is the rank counted from the bottom of the chart.
    private func height(_ rank: Int, _ data: TrendsRankBump) -> Double { Double(data.topN + 1 - rank) }

    private func color(_ index: Int) -> Color { Self.palette[index % Self.palette.count] }

    private func chart(_ data: TrendsRankBump) -> some View {
        Chart {
            ForEach(Array(data.series.enumerated()), id: \.element.id) { index, series in
                ForEach(data.buckets) { bucket in
                    if let rank = series.ranks[safe: bucket.index] ?? nil {
                        // A line only joins buckets where it was in the top N: each unbroken stretch is its own series.
                        LineMark(x: .value("Date", bucket.start), y: .value("Rank", height(rank, data)),
                                 series: .value("Item", "\(index)-\(run(series, bucket.index))"))
                            .foregroundStyle(color(index))
                            .lineStyle(StrokeStyle(lineWidth: 2.5))
                            .interpolationMethod(.linear)
                        PointMark(x: .value("Date", bucket.start), y: .value("Rank", height(rank, data)))
                            .foregroundStyle(color(index))
                            .symbolSize(hovered?.id == bucket.id ? 90 : 45)
                    }
                }
            }
            if let hovered {
                RuleMark(x: .value("Date", hovered.start))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) { tooltip(hovered, data) }
            }
        }
        .chartYScale(domain: 0.5...(Double(data.topN) + 0.5))
        .chartYAxis {
            AxisMarks(position: .leading, values: Array(1...data.topN)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let v = value.as(Int.self) { Text("#\(data.topN + 1 - v)") } }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): hovered = bucket(at: location, proxy: proxy, geo: geo, data: data)
                        case .ended: hovered = nil
                        }
                    }
                    .onTapGesture { location in
                        guard let bucket = bucket(at: location, proxy: proxy, geo: geo, data: data) else { return }
                        openQuery(
                            TrendsDrill.rankedBucket(target: data.target, topN: data.topN, from: bucket.from, to: bucket.to, metric: metric),
                            "Top \(data.topN) · " + data.bucketing.name(bucket.start)
                        )
                    }
            }
        }
    }

    private func bucket(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy, data: TrendsRankBump) -> TrendsRankBump.Bucket? {
        guard let plot = proxy.plotFrame, let date: Date = proxy.value(atX: location.x - geo[plot].origin.x) else { return nil }
        return data.buckets.min { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }
    }

    private func tooltip(_ bucket: TrendsRankBump.Bucket, _ data: TrendsRankBump) -> some View {
        // `hovered` can be a bucket from the PREVIOUS data (it survives a recompute under a stationary pointer),
        // so its index is looked up safely rather than trusted to be in range for this data's series.
        let standings = data.series.enumerated().compactMap { index, series in (series.ranks[safe: bucket.index] ?? nil).map { (rank: $0, index: index, series: series) } }
            .sorted { $0.rank < $1.rank }
        return VStack(alignment: .leading, spacing: 3) {
            Text(data.bucketing.name(bucket.start)).font(AppTypography.metadata.weight(.semibold))
            ForEach(standings, id: \.series.id) { item in
                HStack(spacing: 6) {
                    Circle().fill(color(item.index)).frame(width: 7, height: 7)
                    Text("#\(item.rank)").font(AppTypography.compactMetadata.monospacedDigit()).foregroundStyle(.secondary)
                    Text(item.series.title).font(AppTypography.compactMetadata).lineLimit(1)
                }
            }
            if standings.isEmpty { Text("None of the period’s leaders").font(AppTypography.compactMetadata).foregroundStyle(.secondary) }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.5)) }
    }

    private func legend(_ data: TrendsRankBump) -> some View {
        FlowLegend {
            ForEach(Array(data.series.enumerated()), id: \.element.id) { index, series in
                HStack(spacing: 5) {
                    Circle().fill(color(index)).frame(width: 8, height: 8)
                    Text("#\(series.overallRank)").font(AppTypography.denseBadge.monospacedDigit()).foregroundStyle(.tertiary)
                    Text(series.title).font(AppTypography.compactMetadata).lineLimit(1)
                    if let subtitle = series.subtitle { Text(subtitle).font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1) }
                }
                .help("#\(series.overallRank) over the whole period")
            }
        }
    }

    private func recompute() async {
        isLoading = true
        let (target, n, metric, inputs) = (entity, topN, self.metric, self.inputs)
        let computed = await Task.detached(priority: .utility) {
            TrendsRankBumpEngine.compute(scrobbles: inputs.scrobbles, target: target, topN: n, range: inputs.range, metric: metric, durations: inputs.durations)
        }.value
        guard !Task.isCancelled else { return }
        hovered = nil
        data = computed
        isLoading = false
    }
}

/// Wraps its children onto as many lines as they need.
private struct FlowLegend<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View { AskFlowLayout(spacing: 14) { content } }
}
