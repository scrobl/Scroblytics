import SwiftUI

/// Scrobbles by weekday and hour of day, for the period and (when comparing) the comparison period on the same
/// colour scale. A cell — or a weekday / hour label for a whole row / column — opens Query on the plays made then.
/// Weighs by plays or by time listened, its own choice.
struct TrendsHeatmapChart: View {
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

    @AppStorage("trends.heatmap.metric") private var metricRaw = TrendsMetric.plays.rawValue
    /// Which kind of thing a click opens in Query; remembered between launches.
    @AppStorage("trends.heatmap.drillTarget") private var drillTargetRaw = QueryTarget.track.rawValue
    private var drillTarget: QueryTarget { QueryTarget(rawValue: drillTargetRaw) ?? .track }
    private var drillTargetBinding: Binding<QueryTarget> {
        Binding(get: { drillTarget }, set: { drillTargetRaw = $0.rawValue })
    }
    private var metric: TrendsMetric { TrendsMetric(rawValue: metricRaw) ?? .plays }
    @State private var heatmap: TrendsHeatmap?
    @State private var isLoading = true
    @State private var hovered: Slot?

    /// Rows run Monday to Sunday; `day` is the 0 = Sunday numbering the filter uses.
    private static let rows: [(label: String, day: Int)] = [("Mon", 1), ("Tue", 2), ("Wed", 3), ("Thu", 4), ("Fri", 5), ("Sat", 6), ("Sun", 0)]

    private struct Slot: Equatable { let grid: Int; let day: Int; let hour: Int }
    private struct ComputeKey: Equatable { let metric: TrendsMetric; let inputs: Inputs }
    private func format(_ v: Int) -> String { TrendsWeight.format(v, metric: metric) }
    private var unitWord: String { metric == .plays ? "scrobbles" : "listened" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if let heatmap, let peak = heatmap.peak {
                    Text("Busiest: \(QueryPlayFilter.dayNames[peak.day]) \(QueryPlayFilter.hourLabel(peak.hour))")
                        .font(AppTypography.entityTitle)
                    Text("\(format(peak.count)) \(unitWord)").font(AppTypography.metadata).foregroundStyle(.secondary)
                }
                if heatmap != nil {
                    Text(hoverText)
                        .font(AppTypography.metadata.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Metric", selection: $metricRaw) {
                    ForEach(TrendsMetric.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            if let heatmap {
                grid(title: heatmap.compareCounts == nil ? nil : "This period", counts: heatmap.counts, range: heatmap.range, index: 0)
                if let compare = heatmap.compareCounts, let compareRange = heatmap.compareRange {
                    grid(title: "Previous period · " + TrendsDrill.rangeLabel(from: compareRange.from, to: compareRange.to), counts: compare, range: compareRange, index: 1)
                }
                if metric == .timeListened, heatmap.pending > 0 {
                    Label("\(heatmap.pending.formatted()) plays are still waiting for a track length and aren’t counted yet.", systemImage: "hourglass")
                        .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Text("Click a cell, a day or an hour to see what you played then, as")
                        .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                    Picker("Open as", selection: drillTargetBinding) {
                        Text("Artists").tag(QueryTarget.artist)
                        Text("Albums").tag(QueryTarget.album)
                        Text("Tracks").tag(QueryTarget.track)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Spacer()
                    legend
                }
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 220)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.45), lineWidth: 1) }
        .task(id: ComputeKey(metric: metric, inputs: inputs)) { await recompute() }
    }

    private var hoverText: String {
        guard let hovered, let heatmap else { return "" }
        let counts = hovered.grid == 0 ? heatmap.counts : (heatmap.compareCounts ?? [])
        let n = counts.isEmpty ? 0 : counts[hovered.day * 24 + hovered.hour]
        return "\(QueryPlayFilter.dayNames[hovered.day]) \(QueryPlayFilter.hourLabel(hovered.hour)) · \(format(n)) \(unitWord)"
    }

    private func grid(title: String?, counts: [Int], range: DateRange, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { Text(title).font(AppTypography.metadata.weight(.semibold)).foregroundStyle(.secondary) }
            Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                GridRow {
                    Color.clear.frame(width: 34, height: 14)
                    ForEach(0..<24, id: \.self) { hour in
                        Button { drill(range, days: nil, hours: hour...hour, detail: "every day at \(QueryPlayFilter.hourLabel(hour))") } label: {
                            Text(hour % 3 == 0 ? shortHour(hour) : "").font(AppTypography.denseBadge).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("All days at \(QueryPlayFilter.hourLabel(hour))")
                    }
                }
                ForEach(Self.rows, id: \.day) { row in
                    GridRow {
                        Button { drill(range, days: [row.day], hours: nil, detail: QueryPlayFilter.dayNames[row.day] + "s") } label: {
                            Text(row.label).font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Every \(QueryPlayFilter.dayNames[row.day])")
                        ForEach(0..<24, id: \.self) { hour in
                            let count = counts[row.day * 24 + hour]
                            RoundedRectangle(cornerRadius: 3)
                                .fill(HeatColorScale.cellColor(count: count, thresholds: heatmap?.thresholds ?? [], hour: hour))
                                .frame(height: 24)
                                .overlay {
                                    if hovered == Slot(grid: index, day: row.day, hour: hour) {
                                        RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.8), lineWidth: 1.5)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onHover { inside in
                                    let slot = Slot(grid: index, day: row.day, hour: hour)
                                    if inside { hovered = slot } else if hovered == slot { hovered = nil }
                                }
                                .onTapGesture {
                                    drill(range, days: [row.day], hours: hour...hour, detail: "\(QueryPlayFilter.dayNames[row.day]) \(QueryPlayFilter.hourLabel(hour))")
                                }
                        }
                    }
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text("Fewer").font(AppTypography.denseBadge).foregroundStyle(.secondary)
            ForEach([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0], id: \.self) { level in
                RoundedRectangle(cornerRadius: 2).fill(Color.orange.opacity([10, 20, 31, 43, 56, 70, 84, 97][Int(level) - 1] / 100)).frame(width: 14, height: 10)
            }
            Text("More").font(AppTypography.denseBadge).foregroundStyle(.secondary)
        }
    }

    private func shortHour(_ hour: Int) -> String {
        hour == 0 ? "12a" : hour == 12 ? "12p" : hour < 12 ? "\(hour)a" : "\(hour - 12)p"
    }

    private func drill(_ range: DateRange, days: [Int]?, hours: ClosedRange<Int>?, detail: String) {
        let filter = QueryPlayFilter(weekdays: days, fromHour: hours?.lowerBound, toHour: hours?.upperBound)
        let spec = TrendsDrill.spec(from: range.from, to: range.to, target: drillTarget, playFilter: filter)
        openQuery(spec, "Scrobbles · \(detail) · " + TrendsDrill.rangeLabel(from: range.from, to: range.to))
    }

    private func recompute() async {
        isLoading = true
        let (metric, inputs) = (self.metric, self.inputs)
        let computed = await Task.detached(priority: .utility) {
            TrendsEngine.heatmap(scrobbles: inputs.scrobbles, range: inputs.range, compareRange: inputs.compareRange, metric: metric, durations: inputs.durations)
        }.value
        guard !Task.isCancelled else { return }
        heatmap = computed
        isLoading = false
    }
}
