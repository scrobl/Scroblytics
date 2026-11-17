import SwiftUI

/// Trends › Taste & eras › Countries you've heard: a passport of every country you have heard an artist from, over your whole history,
/// with the day you first heard one from there and who it was, and how many countries you had reached by when. A click on a stamp opens
/// that country's artists in Query. It ignores the period, because a passport is about ever.
struct TrendsPassportChart: View {
    struct Inputs: Equatable {
        let scrobbles: [ScrobbleSnapshot]
        let snapshots: QuerySnapshots
        let version: Int
        static func == (a: Inputs, b: Inputs) -> Bool { a.version == b.version }
    }

    enum Order: String, CaseIterable, Identifiable {
        case first = "First heard", plays = "Most played"
        var id: String { rawValue }
    }

    let inputs: Inputs
    let openQuery: (QuerySpec, String) -> Void
    private let preset: CountryPassportResult?

    @AppStorage("trends.passport.order") private var orderRaw = Order.first.rawValue
    @State private var result: CountryPassportResult?
    @State private var isLoading = true
    @Environment(\.shareChartCapture) private var shareCapture

    init(inputs: Inputs, openQuery: @escaping (QuerySpec, String) -> Void, preset: CountryPassportResult? = nil) {
        self.inputs = inputs
        self.openQuery = openQuery
        self.preset = preset
        _result = State(initialValue: preset)
    }

    private var order: Order { Order(rawValue: orderRaw) ?? .first }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let result, result.countryCount > 0 {
                HStack(spacing: 12) {
                    Picker("Order", selection: $orderRaw) {
                        ForEach(Order.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    Text(headline(result)).font(AppTypography.metadata).foregroundStyle(.secondary)
                }
                if !result.steps.isEmpty { ladder(result) }
                stamps(result)
                    .shareChartArea()
                notes(result)
            } else if isLoading, result == nil {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ContentUnavailableView(
                    "No country yet", systemImage: "globe.europe.africa",
                    description: Text("A country appears once where one of your artists is from is known (Settings › Sync › Artist origins).")
                )
                .frame(minHeight: 200)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.45), lineWidth: 1) }
        .task(id: inputs, priority: .utility) { await recompute() }
    }

    private func headline(_ result: CountryPassportResult) -> String {
        let count = result.countryCount
        var text = "Artists from \(count) countr\(count == 1 ? "y" : "ies")"
        if let next = result.nextStep { text += " · next step: \(next)" }
        return text
    }

    private func ladder(_ result: CountryPassportResult) -> some View {
        AskFlowLayout(spacing: 8) {
            ForEach(result.steps) { step in
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.seal.fill").font(AppTypography.compactMetadata).foregroundStyle(.orange)
                    Text("\(step.count) \(step.count == 1 ? "country" : "countries")").font(AppTypography.compactMetadata.weight(.semibold))
                    Text("· \(step.reachedAt.formatted(.dateTime.month(.abbreviated).year())) · \(step.country)").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.orange.opacity(0.12), in: Capsule())
                .help("The \(step.count == 1 ? "first country" : "\(step.count)th country") you heard an artist from was \(step.country), on \(step.reachedAt.formatted(date: .long, time: .omitted)).")
            }
        }
    }

    private func stamps(_ result: CountryPassportResult) -> some View {
        let shown = order == .first ? result.stamps : result.stamps.sorted { ($0.plays, $1.name) > ($1.plays, $0.name) }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
            ForEach(shown) { stamp in
                Button { open(stamp) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Text(CountryNames.flag(forCode: stamp.code)).font(.system(size: 30))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stamp.name).font(AppTypography.metadata.weight(.semibold)).lineLimit(1)
                            Text("First heard \(stamp.firstHeard.formatted(.dateTime.month(.abbreviated).day().year()))")
                                .font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1)
                            Text(stamp.firstArtist).font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1)
                            Text("\(stamp.artists) artist\(stamp.artists == 1 ? "" : "s") · \(stamp.plays.formatted()) plays")
                                .font(AppTypography.compactMetadata.monospacedDigit()).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open the artists from \(stamp.name) in Query")
            }
        }
    }

    @ViewBuilder
    private func notes(_ result: CountryPassportResult) -> some View {
        if result.unknownArtists > 0 {
            Label("\(result.unknownArtists.formatted()) of the \((result.unknownArtists + result.knownArtists).formatted()) artists you have played have no known origin yet, so more countries may appear.", systemImage: "questionmark.circle")
                .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
        }
        Text("This covers everything you have played, whatever period is chosen. Click a stamp to see its artists.")
            .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
    }

    private func open(_ stamp: CountryPassportResult.Stamp) {
        openQuery(OriginMapDrill.countryAllTime(name: stamp.name), "Artists from \(stamp.name)")
    }

    private func recompute() async {
        guard preset == nil else { return }
        isLoading = true
        let inputs = self.inputs
        let computed = await TrendsComputeGate.shared.run {
            CountryPassportEngine.compute(scrobbles: inputs.scrobbles, origins: inputs.snapshots.origins)
        }
        guard !Task.isCancelled, let computed else { return }
        result = computed
        isLoading = false
        shareCapture?.summary = ShareChartSummary(
            headline: "Countries I’ve heard", detail: "Artists from \(computed.countryCount) countr\(computed.countryCount == 1 ? "y" : "ies") · whole history", legend: []
        )
    }
}
