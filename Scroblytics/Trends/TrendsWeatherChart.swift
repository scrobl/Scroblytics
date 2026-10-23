import SwiftUI

/// Trends › Listening › Weather: three cards (kinds of weather, temperature by time of day, listening over the weeks' weather) with one
/// set of controls. The weather is the home place's, from Settings › Weather. Everything shown is worked out per hour of weather, so more
/// plays on clear days only because there are more clear days never shows up as a liking for them.
struct TrendsWeatherGroup: View {
    struct Inputs: Equatable {
        let scrobbles: [ScrobbleSnapshot]
        let durations: DurationEngine.Snapshot
        let weather: WeatherSnapshot
        let range: DateRange
        let compareRange: DateRange?
        let version: Int
        static func == (a: Inputs, b: Inputs) -> Bool { a.range == b.range && a.compareRange == b.compareRange && a.version == b.version }
    }

    let inputs: Inputs
    let openQuery: (QuerySpec, String) -> Void

    @AppStorage("trends.weather.metric") private var metricRaw = TrendsMetric.plays.rawValue
    @AppStorage("trends.weather.adjust") private var adjustForSeason = true
    @AppStorage("trends.weather.drillTarget") private var drillTargetRaw = QueryTarget.track.rawValue
    @AppStorage(WeatherSettings.enabledKey) private var weatherEnabled = false
    /// "Not now" on the card that offers weather to someone who has not turned it on.
    @AppStorage("trends.weather.offerHidden") private var offerHidden = false
    @AppStorage(WeatherSettings.temperatureUnitKey) private var unitRaw = TemperatureUnit.automatic.rawValue
    @State private var result: TrendsWeatherResult?
    @State private var isLoading = true
    @State private var status = WeatherStatus.shared

    private var metric: TrendsMetric { TrendsMetric(rawValue: metricRaw) ?? .plays }
    private var drillTarget: QueryTarget { QueryTarget(rawValue: drillTargetRaw) ?? .track }
    private var unit: TemperatureUnit { (TemperatureUnit(rawValue: unitRaw) ?? .automatic).resolved() }
    private var unitWord: String { metric == .plays ? "scrobbles" : "listening time" }

    private struct ComputeKey: Equatable { let metric: TrendsMetric; let adjust: Bool; let inputs: Inputs }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !weatherEnabled || WeatherSettings.place() == nil {
                if !offerHidden { setupCard }
            } else if inputs.weather.isEmpty {
                waitingCard
            } else {
                controls
                if let result, result.hasWeather {
                    sections(result)
                } else if isLoading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    messageCard(icon: "cloud.slash", title: "No weather for this period",
                                text: "The weather downloaded doesn’t reach this period yet. Pick a different period, or check Settings › Weather.")
                }
            }
        }
        .task(id: ComputeKey(metric: metric, adjust: adjustForSeason, inputs: inputs), priority: .utility) { await recompute() }
    }

    // MARK: Before there is weather

    private var setupCard: some View {
        messageCard(icon: "cloud.sun", title: "Weather and listening",
                    text: "See how much you listen in rain, snow or cold, and when. Turn it on and choose where you live in Settings › Weather: the app downloads the hourly weather for your place (never anything about your music) and keeps it on this Mac.") {
            HStack(spacing: 12) {
                SettingsLink { Text("Open Settings") }
                Button("Not now") { offerHidden = true }.buttonStyle(.link)
            }
        }
    }

    private var waitingCard: some View {
        let text: String
        switch status.state {
        case .updating(let progress): text = "Downloading the weather for your place… \(progress)"
        case .failed(let message): text = message
        case .waitingForConnection: text = "Waiting for a connection (Offline mode is on, or the network is down)."
        case .idle: text = "Nothing is downloaded yet. It starts on its own; you can also press Update Now in Settings › Weather."
        }
        return messageCard(icon: "arrow.down.circle", title: "Getting the weather", text: text) {
            SettingsLink { Text("Open Settings") }
        }
    }

    private func messageCard<Extra: View>(icon: String, title: String, text: String, @ViewBuilder extra: () -> Extra = { EmptyView() }) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(.secondary).frame(width: 36)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(AppTypography.sectionTitle)
                Text(text).font(AppTypography.metadata).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                extra()
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.45), lineWidth: 1) }
    }

    // MARK: Controls

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { controlItems }
            VStack(alignment: .leading, spacing: 8) { controlItems }
        }
    }

    @ViewBuilder
    private var controlItems: some View {
        Picker("Metric", selection: $metricRaw) {
            ForEach(TrendsMetric.allCases) { Text($0.label).tag($0.rawValue) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        Toggle("Allow for the time of year", isOn: $adjustForSeason)
            .toggleStyle(.checkbox)
            .help("Compares each hour with your usual listening in the same month, so cold weather isn’t just winter and hot weather isn’t just summer.")
        HStack(spacing: 6) {
            Text("Click to open as").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            Picker("Open as", selection: $drillTargetRaw) {
                Text("Artists").tag(QueryTarget.artist.rawValue)
                Text("Albums").tag(QueryTarget.album.rawValue)
                Text("Tracks").tag(QueryTarget.track.rawValue)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        Spacer()
        Link(WeatherAttribution.text, destination: WeatherAttribution.url).font(AppTypography.compactMetadata)
    }

    // MARK: The cards

    @ViewBuilder
    private func sections(_ result: TrendsWeatherResult) -> some View {
        TrendsSection(title: "Weather and listening", subtitle: tilesSubtitle(result), comparison: true) {
            tilesCard(result)
        }
        TrendsSection(title: "Temperature and time of day", subtitle: "How much more or less than usual you play, by how warm it was for your place and the time of day" + (result.adjusted ? ", allowing for the time of year" : "")) {
            gridCard(result)
        }
        TrendsSection(title: "Listening against the weather", subtitle: "Each \(result.bucketDays == 1 ? "day" : "week")’s \(unitWord) over the weather of that \(result.bucketDays == 1 ? "day" : "week")") {
            timelineCard(result)
        }
    }

    private func tilesSubtitle(_ result: TrendsWeatherResult) -> String {
        guard let tile = result.leaning, let lift = tile.lift else { return "How much you listen in each kind of weather, against an average day" }
        let amount = metric == .plays ? tile.perDay.formatted(.number.precision(.fractionLength(0))) : TrendsDuration.formatCompact(Int(tile.perDay.rounded()))
        return "\(tile.condition.rawValue) is your music weather: \(amount) a day, \(WeatherPalette.percent(lift)) against an average day"
    }

    private func tilesCard(_ result: TrendsWeatherResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TrendsWeatherTiles(tiles: result.tiles, previousLifts: result.previousLifts, metric: metric, onSelect: { openCondition($0) })
                .shareChartArea()
                .shareSummary(tilesSummary(result))
            footnote(result)
        }
    }

    private func gridCard(_ result: TrendsWeatherResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TrendsWeatherGridView(grid: result.grid, unit: unit, onSelect: { openCell(row: $0, column: $1, edges: result.grid.edges) })
                .shareChartArea()
                .shareSummary(ShareChartSummary(headline: "Weather and time of day", change: nil, detail: "How much more or less than usual, by temperature and time of day"))
            Text("Cells with fewer than \(TrendsWeatherGridView.minimumPlays) plays are left blank.")
                .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
        }
    }

    private func timelineCard(_ result: TrendsWeatherResult) -> some View {
        TrendsWeatherTimeline(weeks: result.buckets, unit: unit, metric: metric, onSelect: { openBucket($0, days: result.bucketDays) })
            .shareChartArea()
            .shareSummary(ShareChartSummary(headline: "Listening against the weather", change: nil, detail: "Each \(result.bucketDays == 1 ? "day" : "week")’s \(unitWord) over its temperature"))
    }

    private func footnote(_ result: TrendsWeatherResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("The bar is a day of that weather; the tick is an average day" + (result.adjusted ? ". The percentage allows for the time of year." : ". The percentage does not allow for the time of year: turn that on above to compare like with like."))
                .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            if metric == .timeListened, result.pending > 0 {
                Label("\(result.pending.formatted()) plays are still waiting for a track length and aren’t counted yet.", systemImage: "hourglass")
                    .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            }
        }
    }

    private func tilesSummary(_ result: TrendsWeatherResult) -> ShareChartSummary? {
        guard let tile = result.leaning, let lift = tile.lift else { return ShareChartSummary(headline: "Weather and listening", change: nil, detail: "Against an average day") }
        return ShareChartSummary(headline: "\(tile.condition.rawValue) is my music weather", change: "\(WeatherPalette.percent(lift)) against an average day", isUp: true)
    }

    // MARK: Opening Query

    private func periodLabel() -> String { TrendsDrill.rangeLabel(from: inputs.range.from, to: inputs.range.to) }

    private func openCondition(_ condition: WeatherCondition) {
        let filter = QueryPlayFilter(weekdays: nil, fromHour: nil, toHour: nil, months: nil, weatherConditions: [condition.rawValue])
        let spec = TrendsDrill.spec(from: inputs.range.from, to: inputs.range.to, target: drillTarget, playFilter: filter)
        openQuery(spec, "Scrobbles · in \(condition.rawValue.lowercased()) · " + periodLabel())
    }

    private func openCell(row: Int, column: Int, edges: [Double]) {
        guard let filter = TrendsWeatherEngine.cellFilter(row: row, column: column, edges: edges), let from = filter.temperatureFrom else { return }
        let spec = TrendsDrill.spec(from: inputs.range.from, to: inputs.range.to, target: drillTarget, playFilter: filter)
        openQuery(spec, "Scrobbles · \(TrendsWeatherGrid.dayparts[row]), \(unit.text(celsius: from)) to \(unit.text(celsius: edges[column + 1])) · " + periodLabel())
    }

    private func openBucket(_ week: TrendsWeatherWeek, days: Int) {
        let end = min(inputs.range.to, week.start.addingTimeInterval(Double(days) * 86_400 - 1))
        let spec = TrendsDrill.spec(from: max(week.start, inputs.range.from), to: end, target: drillTarget)
        openQuery(spec, "Scrobbles · " + TrendsDrill.label(start: week.start, granularity: days == 1 ? .day : .week))
    }

    // MARK: Computing

    private func recompute() async {
        isLoading = true
        let (metric, adjust, inputs) = (self.metric, adjustForSeason, self.inputs)
        let computed = await TrendsComputeGate.shared.run {
            TrendsWeatherEngine.compute(
                scrobbles: inputs.scrobbles, weather: inputs.weather, range: inputs.range, compareRange: inputs.compareRange, metric: metric,
                durations: inputs.durations, adjustForSeason: adjust
            )
        }
        guard !Task.isCancelled, let computed else { return }
        result = computed
        isLoading = false
    }
}

/// Sets the headline a shared card of this part of the page carries.
private struct ShareSummaryModifier: ViewModifier {
    let summary: ShareChartSummary?
    @Environment(\.shareChartCapture) private var capture

    func body(content: Content) -> some View {
        content.task(id: summary) { capture?.summary = summary }
    }
}

private extension View {
    func shareSummary(_ summary: ShareChartSummary?) -> some View { modifier(ShareSummaryModifier(summary: summary)) }
}
