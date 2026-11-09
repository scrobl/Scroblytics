import SwiftUI
import Charts

/// The period's top few as lines over time (#1 at the top); a gap means it fell out of that bucket's top N. Hover names
/// the bucket's standings; a click opens Query on that bucket's top N.
struct TrendsRankBumpChart: View {
    struct Inputs: Equatable {
        let scrobbles: [ScrobbleSnapshot]
        let durations: DurationEngine.Snapshot
        /// The saved pictures (by address key), for the circles on the lines. Not part of the comparison: a picture arriving later redraws the
        /// chart without recomputing the standings.
        var imageLookup: [String: String] = [:]
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
    @Environment(\.shareChartCapture) private var shareCapture

    private var entity: QueryTarget { QueryTarget(rawValue: entityRaw) ?? .artist }
    private var metric: TrendsMetric { TrendsMetric(rawValue: metricRaw) ?? .plays }
    private static let palette: [Color] = [.blue, .green, .orange, .purple, .red, .teal, .pink, .yellow, .indigo, .brown]
    private struct ComputeKey: Equatable { let entity: QueryTarget; let topN: Int; let metric: TrendsMetric; let inputs: Inputs }
    private struct NativeKey: Equatable { let compute: ComputeKey; let ready: Bool }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            controls
            if let data, data.buckets.count >= 2 {
                let urls = Self.artworkURLs(data, lookup: inputs.imageLookup)
                chart(data, urls: urls).frame(height: CGFloat(max(220, data.topN * 34))).shareChartArea()
                legend(data, urls: urls)
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
        .task(id: ComputeKey(entity: entity, topN: topN, metric: metric, inputs: inputs), priority: .utility) { await recompute() }
        .shareNative(id: NativeKey(compute: ComputeKey(entity: entity, topN: topN, metric: metric, inputs: inputs), ready: data != nil)) {
            guard let data, data.buckets.count >= 2 else { return nil }
            return TrendsShareCharts2.rankings(data: data, metric: metric)
        }
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

    /// The picture each line carries: an artist's own; an album's cover; for a track its own saved picture, else its artist's. A line with no
    /// picture saved stays a plain coloured dot.
    static func artworkURLs(_ data: TrendsRankBump, lookup: [String: String]) -> [QueryEntityID: String] {
        var out: [QueryEntityID: String] = [:]
        for series in data.series {
            let id = series.id
            let artist = ImageTarget(kind: .artist, artist: id.artist, album: nil, track: nil)
            let url: String?
            switch data.target {
            case .artist:
                url = TrendsWeatherMapEngine.artworkURL(for: id.artist, lookup: lookup)
            case .album:
                url = ImageResolutionEngine.effectiveImageURL(for: ImageTarget(kind: .album, artist: id.artist, album: id.name, track: nil), lookup: lookup, fallbackURL: nil)
            case .track, .scrobble, .session:
                url = ImageResolutionEngine.effectiveImageURL(for: ImageTarget(kind: .track, artist: id.artist, album: nil, track: id.name), lookup: lookup, fallbackURL: nil)
                    ?? ImageResolutionEngine.effectiveImageURL(for: artist, lookup: lookup, fallbackURL: nil)
            }
            if let url { out[id] = url }
        }
        return out
    }

    /// The bucket where a line first appears: the one point of it that carries the picture (the rest stay dots).
    private func firstBucket(_ series: TrendsRankBump.Series) -> Int? {
        series.ranks.firstIndex { $0 != nil }
    }

    /// A line's marker: its picture in a circle, ringed in the line's colour (a plain dot when it has no picture).
    private func badge(_ index: Int, _ series: TrendsRankBump.Series, urls: [QueryEntityID: String], diameter: CGFloat) -> some View {
        ZStack {
            Circle().fill(color(index))
            if let url = urls[series.id] {
                ArtworkImage(urlString: url, contentMode: .fill) { Color.clear }
                    .frame(width: diameter - 3.5, height: diameter - 3.5)
                    .clipShape(Circle())
            }
        }
        .frame(width: diameter, height: diameter)
    }

    /// Each line's picture sits over its first point, so it is laid out from the chart's own positions.
    private func pictures(_ data: TrendsRankBump, urls: [QueryEntityID: String], proxy: ChartProxy, geo: GeometryProxy) -> some View {
        let plotFrame = proxy.plotFrame.map { geo[$0] } ?? .zero
        let pitch = plotFrame.height / CGFloat(max(1, data.topN))
        let base = min(30, max(16, pitch * 0.8))
        return ZStack(alignment: .topLeading) {
            ForEach(Array(data.series.enumerated()), id: \.element.id) { index, series in
                if urls[series.id] != nil, let first = firstBucket(series), let rank = series.ranks[first],
                   let bucket = data.buckets.first(where: { $0.index == first }),
                   let x = proxy.position(forX: bucket.start), let y = proxy.position(forY: height(rank, data)) {
                    let lifted = hovered?.id == bucket.id
                    badge(index, series, urls: urls, diameter: lifted ? base * 1.15 : base)
                        .overlay { if lifted { Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5) } }
                        .position(x: plotFrame.origin.x + x, y: plotFrame.origin.y + y)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func chart(_ data: TrendsRankBump, urls: [QueryEntityID: String]) -> some View {
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
                        // A line's picture is drawn over its first point (see `pictures`); every other point keeps the dot.
                        if urls[series.id] == nil || firstBucket(series) != bucket.index {
                            PointMark(x: .value("Date", bucket.start), y: .value("Rank", height(rank, data)))
                                .foregroundStyle(color(index))
                                .symbolSize(hovered?.id == bucket.id ? 90 : 45)
                        }
                    }
                }
            }
            if let hovered {
                RuleMark(x: .value("Date", hovered.start))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) { tooltip(hovered, data, urls: urls) }
            }
        }
        .chartYScale(domain: 0.5...(Double(data.topN) + 0.5))
        // Room at both ends so a picture on the first or last point isn't cut off or pushed over the rank labels.
        .chartXScale(range: .plotDimension(padding: 18))
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
                pictures(data, urls: urls, proxy: proxy, geo: geo)
            }
        }
    }

    private func bucket(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy, data: TrendsRankBump) -> TrendsRankBump.Bucket? {
        guard let plot = proxy.plotFrame, let date: Date = proxy.value(atX: location.x - geo[plot].origin.x) else { return nil }
        return data.buckets.min { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }
    }

    private func tooltip(_ bucket: TrendsRankBump.Bucket, _ data: TrendsRankBump, urls: [QueryEntityID: String]) -> some View {
        // `hovered` can be a bucket from the PREVIOUS data (it survives a recompute under a stationary pointer),
        // so its index is looked up safely rather than trusted to be in range for this data's series.
        let standings = data.series.enumerated().compactMap { index, series in (series.ranks[safe: bucket.index] ?? nil).map { (rank: $0, index: index, series: series) } }
            .sorted { $0.rank < $1.rank }
        return VStack(alignment: .leading, spacing: 3) {
            Text(data.bucketing.name(bucket.start)).font(AppTypography.metadata.weight(.semibold))
            ForEach(standings, id: \.series.id) { item in
                HStack(spacing: 6) {
                    badge(item.index, item.series, urls: urls, diameter: urls[item.series.id] == nil ? 7 : 18)
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

    private func legend(_ data: TrendsRankBump, urls: [QueryEntityID: String]) -> some View {
        FlowLegend {
            ForEach(Array(data.series.enumerated()), id: \.element.id) { index, series in
                HStack(spacing: 5) {
                    badge(index, series, urls: urls, diameter: urls[series.id] == nil ? 8 : 20)
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
        let computed = await TrendsComputeGate.shared.run {
            TrendsRankBumpEngine.compute(scrobbles: inputs.scrobbles, target: target, topN: n, range: inputs.range, metric: metric, durations: inputs.durations)
        }
        guard !Task.isCancelled, let computed else { return }
        hovered = nil
        data = computed
        isLoading = false
        // What the chart ranks and how it is bucketed, which its header says beside the pickers.
        // The legend names the lines (colour, overall rank, name), so it goes on the card in readable type rather than in the picture.
        shareCapture?.summary = computed.map { ranked in
            ShareChartSummary(
                headline: "Top \(ranked.topN) \(target.rawValue)s", detail: "By \(ranked.bucketing.label) · \(metric == .plays ? "by scrobbles" : "by time listened")",
                legend: ranked.series.enumerated().map { index, series in
                    ShareChartSummary.Legend(label: "#\(series.overallRank) " + series.title + (series.subtitle.map { " — \($0)" } ?? ""), color: color(index))
                }
            )
        }
    }
}

/// Wraps its children onto as many lines as they need.
private struct FlowLegend<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View { AskFlowLayout(spacing: 14) { content } }
}
