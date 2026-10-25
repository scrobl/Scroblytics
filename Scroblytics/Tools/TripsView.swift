import SwiftData
import SwiftUI

/// Tools › Trips: every trip you have recorded, with what you listened to on it, and where trips are added, edited and removed. A trip is
/// where you were and for which days; it works with weather on or off (with weather on, each also uses the weather where you were, and
/// the rows add temperature and rain). The numbers come from the same calculation as Trends › Where you listened, over all your history.
struct TripsView: View {
    enum Sort: String, CaseIterable, Identifiable, Codable {
        case newest, oldest, mostPlays, mostDays, place
        var id: String { rawValue }
        var label: String {
            switch self {
            case .newest: "Newest first"
            case .oldest: "Oldest first"
            case .mostPlays: "Most plays"
            case .mostDays: "Longest"
            case .place: "Place, A to Z"
            }
        }
    }

    struct Options: Codable, Equatable {
        var sort = Sort.newest
    }

    private static let toolId = "trips"
    private static let defaults = Options()

    let modelContainer: ModelContainer
    let navigation: DetailNavigationCoordinator
    let openQuery: (QuerySpec, String, String?) -> Void

    @Environment(\.modelContext) private var modelContext
    @AppStorage(WeatherSettings.enabledKey) private var weatherEnabled = false
    @AppStorage(WeatherSettings.temperatureUnitKey) private var unitRaw = TemperatureUnit.automatic.rawValue
    @State private var model = TripsModel()
    @State private var options = Self.defaults
    @State private var searchText = ""
    @State private var result: TrendsPlacesResult?
    @State private var editing: TripDraft?
    @State private var removing: WeatherTrip?

    private var unit: TemperatureUnit { (TemperatureUnit(rawValue: unitRaw) ?? .automatic).resolved() }
    private var calendar: Calendar { AppCalendars.listening }

    /// What the engine worked out for a trip (nil while it is working, or for a trip it found no days or plays in).
    private func stay(for trip: WeatherTrip) -> TrendsStay? { result?.trips.first { $0.id == trip.id.uuidString } }

    private var visibleTrips: [WeatherTrip] {
        let filtered = model.trips.filter { searchText.isEmpty || $0.place.name.localizedCaseInsensitiveContains(searchText) }
        switch options.sort {
        case .newest: return filtered.sorted { $0.from > $1.from }
        case .oldest: return filtered.sorted { $0.from < $1.from }
        case .mostPlays: return filtered.sorted { (stay(for: $0)?.plays ?? -1, $0.from) > (stay(for: $1)?.plays ?? -1, $1.from) }
        case .mostDays: return filtered.sorted { (stay(for: $0)?.days ?? -1, $0.from) > (stay(for: $1)?.days ?? -1, $1.from) }
        case .place: return filtered.sorted { $0.place.name.localizedStandardCompare($1.place.name) == .orderedAscending }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageSettingsHeader("Trips") { controls }
                ToolHeadlineCard("WHERE YOU WERE") { headline }
                actionRow
                content
            }
            .padding(16)
        }
        .navigationTitle("Trips")
        .task {
            options = ToolFilterSettingsStore.load(Options.self, toolId: Self.toolId, context: modelContext, default: Self.defaults)
        }
        .task(id: model.revision) { await recompute() }
        .onChange(of: options) { _, value in ToolFilterSettingsStore.save(value, toolId: Self.toolId, context: modelContext) }
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in Task { await recompute() } }
        .onReceive(NotificationCenter.default.publisher(for: .weatherDidUpdate)) { _ in model.reload() }
        .sheet(item: $editing) { draft in
            TripEditor(draft: draft, onSave: { model.save($0); editing = nil }, onCancel: { editing = nil })
        }
        .confirmationDialog("Remove this trip?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove Trip", role: .destructive) { if let removing { model.remove(removing) }; removing = nil }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("Your scrobbles are not changed. The plays made then are just no longer filed under this trip’s place.")
        }
    }

    // MARK: Controls and summary

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { pickers }
            VStack(alignment: .leading, spacing: 10) { pickers }
        }
    }

    @ViewBuilder private var pickers: some View {
        TextField("Find a place…", text: $searchText).textFieldStyle(.roundedBorder).frame(minWidth: 190)
        Picker("Sort", selection: $options.sort) {
            ForEach(Sort.allCases) { Text($0.label).tag($0) }
        }
        .labelsHidden().fixedSize()
    }

    @ViewBuilder private var headline: some View {
        if model.trips.isEmpty {
            Text("Record where you were and for which days, and each trip shows what you listened to then, against your usual.")
        } else if let result, let home = result.home {
            let away = result.trips.filter { $0.days > 0 }
            let days = away.reduce(0) { $0 + $1.days }, plays = away.reduce(0) { $0 + $1.plays }
            let rate = Double(plays) / Double(max(days, 1))
            Text("\(model.trips.count) trip\(model.trips.count == 1 ? "" : "s"), \(days.formatted()) day\(days == 1 ? "" : "s") away: \(rate.formatted(.number.precision(.fractionLength(0)))) plays a day"
                 + (home.perDay > 0 ? ", against \(home.perDay.formatted(.number.precision(.fractionLength(0)))) at home." : "."))
        } else {
            Text("\(model.trips.count) trip\(model.trips.count == 1 ? "" : "s") recorded.")
        }
    }

    private var actionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("I’m Away Now…") { editing = TripDraft.awayNow(calendar: calendar) }
                Button("Add a Trip…") { editing = TripDraft.new(calendar: calendar) }
                if !model.openTrips.isEmpty { Button("Back Home") { model.backHome() } }
                Spacer()
                if let current = model.currentTrip {
                    Label("Away now: \(current.shortName)", systemImage: "airplane").foregroundStyle(.tint)
                }
            }
            if !model.overlapping.isEmpty {
                Text("Some trips overlap. For the days they share, the trip that began later is used.")
                    .font(AppTypography.supporting).foregroundStyle(.orange)
            }
            if !model.trips.isEmpty, !weatherEnabled {
                HStack(spacing: 6) {
                    Text("Weather is off, so these trips show plays only.").font(AppTypography.supporting).foregroundStyle(.secondary)
                    SettingsLink { Text("Turn it on in Settings › Weather") }.buttonStyle(.link).font(AppTypography.supporting)
                }
            }
        }
    }

    // MARK: Rows

    @ViewBuilder private var content: some View {
        if model.trips.isEmpty {
            EmptyView()
        } else if visibleTrips.isEmpty {
            Text("No trip matches “\(searchText)”.").font(AppTypography.metadata).foregroundStyle(.secondary)
        } else {
            let overlapping = model.overlapping
            VStack(spacing: 6) {
                ForEach(visibleTrips) { trip in row(trip, overlaps: overlapping.contains(trip.id)) }
            }
            Text("A day counts as a trip day when the trip covers its middle. “A day” is plays divided by those days, so a day away with no listening counts against the trip.")
                .font(AppTypography.compactMetadata).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ trip: WeatherTrip, overlaps: Bool) -> some View {
        let stay = stay(for: trip)
        let tint: Color = stay.flatMap { result?.tint(for: $0) } ?? .secondary
        return HStack(alignment: .center, spacing: 8) {
            Button {
                if let stay, stay.plays > 0, let result {
                    _ = result
                    openQuery(TrendsPlacesEngine.drillSpec(for: stay, target: .track), "Scrobbles · in \(trip.shortName) · " + TrendsDrill.rangeLabel(from: stay.from, to: stay.until), nil)
                }
            } label: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { rowItems(trip, stay: stay, tint: tint, overlaps: overlaps) }
                    VStack(alignment: .leading, spacing: 4) { rowItems(trip, stay: stay, tint: tint, overlaps: overlaps) }
                }
                .padding(.vertical, 6).padding(.horizontal, 10)
                .background((overlaps ? Color.orange : tint).opacity(overlaps ? 0.14 : 0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(stay.map { $0.plays > 0 ? "Open the \($0.plays.formatted()) plays made in \(trip.shortName) in Query" : "No plays were made during this trip" } ?? "")
            Menu {
                Button("Edit…") { editing = TripDraft(trip: trip, calendar: calendar) }
                Button("Remove…", role: .destructive) { removing = trip }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Edit or remove this trip")
        }
    }

    @ViewBuilder
    private func rowItems(_ trip: WeatherTrip, stay: TrendsStay?, tint: Color, overlaps: Bool) -> some View {
        HStack(alignment: .top, spacing: 7) {
            if overlaps {
                Image(systemName: "calendar.badge.exclamationmark").foregroundStyle(.orange).font(.system(size: 11)).padding(.top, 2)
                    .accessibilityLabel("Overlaps another trip").help("Overlaps another trip")
            } else {
                Circle().fill(tint).frame(width: 9, height: 9).padding(.top, 4)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(trip.place.name).font(AppTypography.metadata.weight(.semibold)).lineLimit(1)
                Text(model.dates(trip) + (stay.map { " · \($0.days) day\($0.days == 1 ? "" : "s")" } ?? ""))
                    .font(AppTypography.compactMetadata).foregroundStyle(overlaps ? Color.orange : Color.secondary).lineLimit(1)
            }
        }
        .frame(width: 230, alignment: .leading)
        if let stay, let result {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(stay.plays.formatted()) plays").font(AppTypography.metadata.monospacedDigit())
                Text(perDayText(stay, result: result)).font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(stay.newArtists == 1 ? "1 new artist" : "\(stay.newArtists.formatted()) new artists").font(AppTypography.metadata)
                if weatherEnabled { Text(weatherText(stay, trip: trip)).font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(width: 130, alignment: .leading)
            Text(stay.topArtists.map(\.name).joined(separator: " · "))
                .font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(2)
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
        } else if result == nil {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("No plays recorded in these days.").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func perDayText(_ stay: TrendsStay, result: TrendsPlacesResult) -> String {
        let perDay = stay.perDay.formatted(.number.precision(.fractionLength(0)))
        guard let relative = result.relativeToHome(stay) else { return "\(perDay) a day" }
        return "\(perDay) a day · \(Int((relative * 100).rounded()))% of home"
    }

    private func weatherText(_ stay: TrendsStay, trip: WeatherTrip) -> String {
        var parts: [String] = []
        if let temperature = stay.averageTemperature { parts.append(unit.text(celsius: temperature)) }
        if let rain = stay.rainShare { parts.append("\(Int((rain * 100).rounded()))% rain") }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return trip.place.hasCoordinates ? "no weather yet" : "name only, no weather"
    }

    // MARK: Numbers

    /// The same calculation as Trends › Where you listened, over the whole history, one row per trip (no grouping).
    private func recompute() async {
        guard !model.trips.isEmpty else { result = nil; return }
        let container = modelContainer
        let scrobbles = (try? await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)) ?? []
        let weather = await offMain { WeatherSnapshot.load() }
        let range = DateRange(from: scrobbles.first?.playedAt ?? model.trips.map(\.from).min() ?? Date(), to: Date())
        let computed = await Task.detached(priority: .userInitiated) {
            TrendsPlacesEngine.compute(scrobbles: scrobbles, weather: weather, range: range, level: .city)
        }.value
        guard !Task.isCancelled else { return }
        result = computed
    }
}
