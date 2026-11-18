import SwiftUI
import Charts

/// Trends › Taste & eras › Close to home: how much of what you play is by artists from your own city, region and country, week by week,
/// month by month or year by year. "Home" is the place you choose here, or the home place from Settings › Weather. A click on a bar
/// opens the artists from your country that you played in that stretch.
struct TrendsLocalSceneChart: View {
    struct Inputs: Equatable {
        let scrobbles: [ScrobbleSnapshot]
        let snapshots: QuerySnapshots
        let range: DateRange
        let version: Int
        static func == (a: Inputs, b: Inputs) -> Bool { a.range == b.range && a.version == b.version }
    }

    let inputs: Inputs
    let openQuery: (QuerySpec, String) -> Void
    private let preset: LocalSceneResult?
    private let presetHome: OriginPlace?

    @AppStorage("trends.localScene.metric") private var metricRaw = TrendsMetric.plays.rawValue
    @State private var result: LocalSceneResult?
    @State private var home: OriginPlace?
    @State private var isLoading = true
    @State private var editingHome = false
    @State private var hovered: LocalSceneResult.Bucket?
    @Environment(\.shareChartCapture) private var shareCapture

    init(inputs: Inputs, openQuery: @escaping (QuerySpec, String) -> Void, preset: LocalSceneResult? = nil, home: OriginPlace? = nil) {
        self.inputs = inputs
        self.openQuery = openQuery
        self.preset = preset
        self.presetHome = home
        _result = State(initialValue: preset)
        _home = State(initialValue: preset == nil ? OriginHome.current() : home)
    }

    private var metric: TrendsMetric { TrendsMetric(rawValue: metricRaw) ?? .plays }
    private static let colors: [LocalScene: Color] = [.city: .orange, .region: .green, .country: .blue, .elsewhere: .gray.opacity(0.55), .unknown: .gray.opacity(0.2)]
    private struct ComputeKey: Equatable { let metric: TrendsMetric; let inputs: Inputs; let home: OriginPlace? }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Picker("Metric", selection: $metricRaw) {
                    ForEach(TrendsMetric.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                if let home {
                    Button { editingHome = true } label: {
                        Label("Home: \(home.text)", systemImage: "house").font(AppTypography.metadata).lineLimit(1)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Change the place this chart treats as home")
                }
            }
            if home == nil {
                ContentUnavailableView {
                    Label("Where is home?", systemImage: "house")
                } description: {
                    Text("Choose your home city, region and country and this chart shows how much of what you play is by artists from there. It uses names only; nothing is sent anywhere.")
                } actions: {
                    Button("Choose Home…") { editingHome = true }
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else if let home, OriginHome.countryCode(of: home) == nil {
                // Without a country nothing can be at home, so every artist would read as "Elsewhere".
                ContentUnavailableView {
                    Label("Home needs a country", systemImage: "house")
                } description: {
                    Text("“\(home.text)” has no country, so every artist would count as elsewhere. Add its country (and, if you like, its state or region); it uses names only and nothing is sent anywhere.")
                } actions: {
                    Button("Choose Home…") { editingHome = true }
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else if let result, result.total > 0, result.share(.unknown) < 1 {
                chart(result)
                    .shareChartArea()
                summary(result)
                key(result)
                Text("Click a bar to open the artists from your country that you played then.")
                    .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            } else if isLoading, result == nil {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ContentUnavailableView(
                    (result?.total ?? 0) == 0 ? "Nothing played in this period" : "No artist here has a known origin yet", systemImage: "house",
                    description: Text((result?.total ?? 0) == 0 ? "Try a wider date range." : "This fills in as where your artists are from is looked up (Settings › Sync › Artist origins).")
                )
                .frame(minHeight: 200)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.45), lineWidth: 1) }
        .task(id: ComputeKey(metric: metric, inputs: inputs, home: home), priority: .utility) { await recompute() }
        .onReceive(NotificationCenter.default.publisher(for: .weatherDidUpdate)) { _ in
            // The weather home place may have changed; it is the home unless one was chosen here.
            if preset == nil { home = OriginHome.current() }
        }
        .sheet(isPresented: $editingHome) {
            OriginHomeEditView(current: home) { chosen in
                OriginHome.setChosen(chosen)
                home = OriginHome.current()
            }
        }
    }

    // MARK: Chart

    private func unit(_ bucketing: TrendsRankBump.Bucketing) -> Calendar.Component {
        switch bucketing {
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }

    private func chart(_ result: LocalSceneResult) -> some View {
        let scenes = LocalScene.allCases
        return Chart {
            ForEach(result.buckets.filter { $0.total > 0 }) { bucket in
                ForEach(scenes, id: \.self) { scene in
                    BarMark(x: .value("Date", bucket.start, unit: unit(result.bucketing)), y: .value("Share", bucket.share(scene) * 100))
                        .foregroundStyle(by: .value("From", scene.label))
                }
            }
            if let hovered {
                RuleMark(x: .value("Date", hovered.start, unit: unit(result.bucketing)))
                    .foregroundStyle(Color.primary.opacity(0.35))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) { tooltip(hovered, result) }
            }
        }
        .chartForegroundStyleScale(domain: scenes.map(\.label), range: scenes.map { Self.colors[$0] ?? .gray })
        .chartLegend(.hidden)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))%") } }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            hovered = bucket(at: point, proxy: proxy, geometry: geometry, result: result)
                        case .ended:
                            hovered = nil
                        }
                    }
                    .onTapGesture { point in
                        if let bucket = bucket(at: point, proxy: proxy, geometry: geometry, result: result) { open(bucket, result: result) }
                    }
            }
        }
        .frame(height: 260)
    }

    private func bucket(at point: CGPoint, proxy: ChartProxy, geometry: GeometryProxy, result: LocalSceneResult) -> LocalSceneResult.Bucket? {
        guard let plot = proxy.plotFrame else { return nil }
        let x = point.x - geometry[plot].origin.x
        guard let date: Date = proxy.value(atX: x) else { return nil }
        return result.buckets.last { $0.start <= date }.flatMap { $0.total > 0 ? $0 : nil }
    }

    private func open(_ bucket: LocalSceneResult.Bucket, result: LocalSceneResult) {
        guard let code = OriginHome.countryCode(of: result.home), let country = CountryNames.name(forCode: code) else { return }
        var spec = TrendsDrill.spec(from: bucket.start, to: bucket.end, target: .artist)
        spec.groups[0].append(QueryCondition("originCountry", .textIs, [.text(country)]))
        spec.columns.append(QueryFieldRef("originPlace"))
        openQuery(spec, "Artists from \(country) · \(result.bucketing.name(bucket.start))")
    }

    private func tooltip(_ bucket: LocalSceneResult.Bucket, _ result: LocalSceneResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(result.bucketing.name(bucket.start)).font(AppTypography.metadata.weight(.semibold))
            ForEach(LocalScene.allCases.filter { (bucket.weights[$0] ?? 0) > 0 }, id: \.self) { scene in
                HStack(spacing: 6) {
                    Circle().fill(Self.colors[scene] ?? .gray).frame(width: 7, height: 7)
                    Text(scene.label).font(AppTypography.compactMetadata)
                    Spacer(minLength: 8)
                    Text(percent(bucket.share(scene))).font(AppTypography.compactMetadata.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(8).frame(minWidth: 190)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.5)) }
    }

    // MARK: Text

    private func summary(_ result: LocalSceneResult) -> some View {
        var parts: [String] = []
        if let code = OriginHome.countryCode(of: result.home) {
            parts.append("\(percent(result.homeCountryShare)) of what you played is by artists from \(CountryNames.phrase(forCode: code))")
        }
        if result.share(.region) + result.share(.city) > 0, let region = result.home.region ?? result.home.city {
            parts.append("\(percent(result.share(.region) + result.share(.city))) from \(region)")
        }
        if result.share(.city) > 0, let city = result.home.city { parts.append("\(percent(result.share(.city))) from \(city)") }
        let text = parts.isEmpty ? "None of what you played is by artists from your home." : parts.joined(separator: ", ") + "."
        return VStack(alignment: .leading, spacing: 4) {
            Text(text).font(AppTypography.metadata)
            if result.share(.unknown) > 0 {
                Text("\(percent(result.share(.unknown))) of what you played is by artists whose origin isn’t known yet (the palest part of each bar). The shares are of everything you played.")
                    .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            }
            if result.pendingLength > 0 {
                Label("\(result.pendingLength.formatted()) plays are still waiting for a track length and aren’t counted yet.", systemImage: "hourglass")
                    .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            }
        }
    }

    private func key(_ result: LocalSceneResult) -> some View {
        AskFlowLayout(spacing: 14) {
            ForEach(LocalScene.allCases, id: \.self) { scene in
                HStack(spacing: 5) {
                    Circle().fill(Self.colors[scene] ?? .gray).frame(width: 8, height: 8)
                    Text("\(scene.label) \(percent(result.share(scene)))").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func percent(_ share: Double) -> String {
        if share > 0, share < 0.005 { return "<1%" }
        return (share * 100).formatted(.number.precision(.fractionLength(0))) + "%"
    }

    private func recompute() async {
        guard preset == nil else { return }
        guard let home else { result = nil; isLoading = false; return }
        isLoading = true
        let (metric, inputs) = (self.metric, self.inputs)
        let computed = await TrendsComputeGate.shared.run {
            LocalSceneEngine.compute(
                scrobbles: inputs.scrobbles, origins: inputs.snapshots.origins, durations: inputs.snapshots.durations, range: inputs.range, metric: metric, home: home
            )
        }
        guard !Task.isCancelled, let computed else { return }
        result = computed
        isLoading = false
        shareCapture?.summary = ShareChartSummary(
            headline: "Close to home", detail: "Artists from \(home.text) · \(metric == .plays ? "by scrobbles" : "by time listened")",
            legend: LocalScene.allCases.map { ShareChartSummary.Legend(label: $0.label, color: Self.colors[$0] ?? .gray) }
        )
    }
}

/// "Where is home?": city, state or region and country, for the local-scene chart. Names only; the home place from Settings › Weather is
/// offered when there is one.
struct OriginHomeEditView: View {
    let current: OriginPlace?
    let onSave: (OriginPlace?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var city = ""
    @State private var region = ""
    @State private var countryCode = ""

    private var typed: OriginPlace {
        OriginPlace(
            city: city.trimmingCharacters(in: .whitespaces).isEmpty ? nil : city.trimmingCharacters(in: .whitespaces),
            region: region.trimmingCharacters(in: .whitespaces).isEmpty ? nil : region.trimmingCharacters(in: .whitespaces),
            country: ArtistOriginCountries.name(forCode: countryCode), countryCode: countryCode.isEmpty ? nil : countryCode
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where Is Home?").font(AppTypography.sectionTitle)
            Text("The chart compares where your artists are from with this place. A country is needed; a city and a region make the closer layers.")
                .font(AppTypography.supporting).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("City")
                    TextField("City", text: $city).textFieldStyle(.roundedBorder).labelsHidden()
                }
                GridRow {
                    Text("State / region")
                    TextField("State, province or region (optional)", text: $region).textFieldStyle(.roundedBorder).labelsHidden()
                }
                GridRow {
                    Text("Country")
                    Picker("Country", selection: $countryCode) {
                        Text("None").tag("")
                        ForEach(ArtistOriginCountries.all) { Text($0.name).tag($0.code) }
                    }
                    .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                if let weather = OriginHome.fromWeather() {
                    Button("Use My Weather Home") { fill(weather) }
                        .help("The home place in Settings › Weather: \(weather.text)")
                }
                if OriginHome.chosen() != nil {
                    Button("Forget This Choice", role: .destructive) { onSave(nil); dismiss() }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") { onSave(typed); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(countryCode.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { if let current { fill(current) } }
    }

    private func fill(_ place: OriginPlace) {
        city = place.city ?? ""
        region = place.region ?? ""
        countryCode = OriginHome.countryCode(of: place) ?? ""
    }
}
