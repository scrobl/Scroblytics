import SwiftUI

/// The period's top tags as bars, each tinted green or red against the comparison period (with a tick where that
/// period stood). A tag opens Query on the tracks, albums or artists carrying it, over the same period. Weighs
/// each track's contribution by plays or by time listened.
struct TrendsTagsChart: View {
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

    @AppStorage("trends.tags.metric") private var metricRaw = TrendsMetric.plays.rawValue
    /// Which kind of thing a click opens in Query; remembered between launches.
    @AppStorage("trends.tags.drillTarget") private var drillTargetRaw = QueryTarget.track.rawValue
    private var drillTarget: QueryTarget { QueryTarget(rawValue: drillTargetRaw) ?? .track }
    private var drillTargetBinding: Binding<QueryTarget> {
        Binding(get: { drillTarget }, set: { drillTargetRaw = $0.rawValue })
    }
    private var metric: TrendsMetric { TrendsMetric(rawValue: metricRaw) ?? .plays }
    @State private var tags: TrendsTags?
    @State private var isLoading = true
    private struct ComputeKey: Equatable { let metric: TrendsMetric; let inputs: Inputs }

    private func maxValue(_ tags: TrendsTags) -> Int { tags.rows.map { max($0.plays, $0.comparePlays ?? 0) }.max() ?? 0 }
    private func format(_ v: Int) -> String { TrendsWeight.format(v, metric: metric) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer()
                Picker("Metric", selection: $metricRaw) {
                    ForEach(TrendsMetric.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            if let tags {
                if tags.rows.isEmpty {
                    ContentUnavailableView(
                        tags.pendingPlays > 0 ? "Tags are still being looked up" : "No tagged plays in this period",
                        systemImage: "tag",
                        description: Text(tags.pendingPlays > 0
                            ? "Tags come from Last.fm and are fetched in the background; this fills in as they arrive."
                            : "Try a wider date range.")
                    )
                    .frame(minHeight: 160)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(tags.rows) { row in tagRow(row, tags) }
                    }
                    .shareChartArea()
                    if tags.lookedUpShare < 0.995 {
                        Label("Tags are known for \((tags.lookedUpShare * 100).formatted(.number.precision(.fractionLength(0))))% of this period’s plays so far — the rest are still being looked up, so these totals will grow.", systemImage: "hourglass")
                            .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                    }
                    if metric == .timeListened, tags.pendingRuntime > 0 {
                        Label("\(tags.pendingRuntime.formatted()) tagged plays are still waiting for a track length and aren’t weighed in yet.", systemImage: "hourglass")
                            .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Text("Click a tag to see what you played, as")
                            .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                        Picker("Open as", selection: drillTargetBinding) {
                            Text("Artists").tag(QueryTarget.artist)
                            Text("Albums").tag(QueryTarget.album)
                            Text("Tracks").tag(QueryTarget.track)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        Spacer()
                        if tags.compareRange != nil {
                            HStack(spacing: 6) {
                                Rectangle().fill(Color.purple).frame(width: 2, height: 10)
                                Text("Previous period").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.45), lineWidth: 1) }
        .task(id: ComputeKey(metric: metric, inputs: inputs), priority: .utility) { await recompute() }
    }

    private func change(_ row: TrendsTags.Row) -> Double? {
        guard let compare = row.comparePlays, compare > 0 else { return nil }
        return (Double(row.plays) - Double(compare)) / Double(compare) * 100
    }

    private func tagRow(_ row: TrendsTags.Row, _ tags: TrendsTags) -> some View {
        let diff = change(row)
        let tint: Color = diff.map { $0 > 0 ? .green : $0 < 0 ? .red : .accentColor } ?? .accentColor
        let maxValue = maxValue(tags)
        return Button {
            let spec = TrendsDrill.spec(from: tags.range.from, to: tags.range.to, target: drillTarget, tag: row.tag)
            openQuery(spec, "Scrobbles tagged “\(row.tag)” · " + TrendsDrill.rangeLabel(from: tags.range.from, to: tags.range.to))
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(row.tag.capitalized).font(AppTypography.metadata.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text(format(row.plays)).font(AppTypography.metadata.monospacedDigit()).foregroundStyle(.secondary)
                    if let diff {
                        Text((diff >= 0 ? "+" : "") + diff.formatted(.number.precision(.fractionLength(1))) + "%")
                            .font(AppTypography.metadata.monospacedDigit())
                            .foregroundStyle(diff >= 0 ? Color.green : Color.red)
                            .frame(minWidth: 56, alignment: .trailing)
                    }
                }
                GeometryReader { geo in
                    let scale = maxValue > 0 ? geo.size.width / CGFloat(maxValue) : 0
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06))
                        RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.85)).frame(width: max(2, CGFloat(row.plays) * scale))
                        if let compare = row.comparePlays, maxValue > 0 {
                            Rectangle().fill(Color.purple).frame(width: 2).offset(x: max(0, CGFloat(compare) * scale - 1))
                        }
                    }
                }
                .frame(height: 10)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open the \(drillTarget.rawValue)s tagged “\(row.tag)” in Query")
    }

    private func recompute() async {
        isLoading = true
        let (metric, inputs) = (self.metric, self.inputs)
        let computed = await TrendsComputeGate.shared.run {
            TrendsTagsEngine.compute(scrobbles: inputs.scrobbles, snapshots: inputs.snapshots, range: inputs.range, compareRange: inputs.compareRange, metric: metric)
        }
        guard !Task.isCancelled, let computed else { return }
        tags = computed
        isLoading = false
    }
}
