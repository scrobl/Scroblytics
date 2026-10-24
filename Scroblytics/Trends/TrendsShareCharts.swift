import AppKit
import SwiftUI

/// The Weather & places charts drawn for a shared card: each is built from the numbers its card has already worked out, laid out at the
/// card's own size (see `ShareNativeChart`), with the sentence about it, what can be left in or out, and the lines to copy as text.
enum TrendsShareCharts {
    private static func percent(_ lift: Double) -> String { WeatherPalette.percent(lift) }
    private static func whole(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0))) }

    // MARK: Weather and listening

    static func tiles(result: TrendsWeatherResult, metric: TrendsMetric, caption: String) -> ShareNativeChart {
        var controls = [
            ShareNativeControl(id: "hideThin", label: "Leave out weathers with too few plays", kind: .toggle(defaultValue: false)),
            ShareNativeControl(id: "detail", label: "Show plays and hours", kind: .toggle(defaultValue: true)),
        ]
        if !result.previousLifts.isEmpty { controls.append(ShareNativeControl(id: "compare", label: "Include the comparison with the previous period", kind: .toggle(defaultValue: false))) }
        let amount: (Double) -> String = { metric == .plays ? whole($0) : TrendsDuration.formatCompact(Int($0.rounded())) }
        let lines = result.tiles.compactMap { tile -> String? in
            guard let lift = tile.lift, !tile.isThin else { return nil }
            return "\(tile.condition == .thunderstorm ? "Storm" : tile.condition.rawValue): \(percent(lift)) (\(amount(tile.perDay)) a day, average \(amount(tile.average)))"
        }
        return ShareNativeChart(
            id: "weather.tiles", caption: caption,
            footnote: "Each tile is your listening per day of that weather against an average day. A weather with under \(TrendsWeatherTile.thinBelow) plays is faded.",
            preferredSize: .square, controls: controls, textLines: lines,
            zoomForShape: { $0 == .portrait ? 1.95 : ($0 == .square ? 1.9 : 1.5) }
        ) { _, options, _ in
            let tiles = options.flag("hideThin", false) ? result.tiles.filter { !$0.isThin && $0.hours > 0 } : result.tiles
            return AnyView(
                TrendsWeatherTiles(tiles: tiles, previousLifts: options.flag("compare", false) ? result.previousLifts : [:], metric: metric, showsDetail: options.flag("detail", true))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            )
        }
    }

    // MARK: Temperature and time of day

    /// The cells with enough plays, most and least played-in, named as a person reads them.
    private static func gridHighlights(_ grid: TrendsWeatherGrid, unit: TemperatureUnit) -> (best: String, worst: String, lines: [String])? {
        var cells: [(lift: Double, name: String)] = []
        for (row, line) in grid.cells.enumerated() {
            for (column, cell) in line.enumerated() where cell.plays >= TrendsWeatherGridView.minimumPlays {
                guard let lift = cell.lift, column + 1 < grid.edges.count else { continue }
                let range = "\(unit.text(celsius: grid.edges[column])) to \(unit.text(celsius: grid.edges[column + 1]))"
                cells.append((lift, "\(TrendsWeatherGrid.dayparts[row].lowercased()) at \(range)"))
            }
        }
        guard let best = cells.max(by: { $0.lift < $1.lift }), let worst = cells.min(by: { $0.lift < $1.lift }), best.name != worst.name else { return nil }
        let ordered = cells.sorted { $0.lift > $1.lift }
        let lines = Array(ordered.prefix(3) + ordered.suffix(3)).map { "\($0.name.prefix(1).uppercased() + $0.name.dropFirst()): \(percent($0.lift))" }
        return ("\(best.name) (\(percent(best.lift)))", "\(worst.name) (\(percent(worst.lift)))", lines)
    }

    static func grid(result: TrendsWeatherResult, unit: TemperatureUnit) -> ShareNativeChart {
        let highlights = gridHighlights(result.grid, unit: unit)
        let caption = highlights.map { "You play most in the \($0.best) and least in the \($0.worst)." } ?? "How much more or less than usual you play, by how warm it was and the time of day."
        let controls = [
            ShareNativeControl(id: "values", label: "Show the percentages in the cells", kind: .toggle(defaultValue: true)),
            ShareNativeControl(id: "legend", label: "Show the colour key", kind: .toggle(defaultValue: true)),
        ]
        return ShareNativeChart(
            id: "weather.grid", caption: caption,
            footnote: "Columns are tenths of your place’s own hours, coldest to warmest; rows are parts of the day. Cells with under \(TrendsWeatherGridView.minimumPlays) plays are left blank." + (result.adjusted ? " Each hour is compared with your usual listening in the same month." : ""),
            preferredSize: .wide, controls: controls, textLines: highlights?.lines ?? [],
            zoomForShape: { $0 == .wide ? 1.6 : 1.7 }
        ) { layout, options, _ in
            let legend = options.flag("legend", true)
            let cell = max(28, min(120, (layout.logical.height - (legend ? 64 : 8)) / 4 - 4))
            return AnyView(
                TrendsWeatherGridView(grid: result.grid, unit: unit, interactive: false, cellHeight: cell, showsValues: options.flag("values", true), showsLegend: legend)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            )
        }
    }

    // MARK: Listening against the weather

    static func timeline(result: TrendsWeatherResult, unit: TemperatureUnit, metric: TrendsMetric) -> ShareNativeChart {
        let span = result.bucketDays == 1 ? "day" : "week"
        let word = metric == .plays ? "scrobbles" : "listening time"
        let controls = [
            ShareNativeControl(id: "temperature", label: "Temperature colours", kind: .toggle(defaultValue: true)),
            ShareNativeControl(id: "markers", label: "Rain and snow markers", kind: .toggle(defaultValue: true)),
            ShareNativeControl(id: "average", label: "Average line", kind: .toggle(defaultValue: true)),
            ShareNativeControl(id: "legend", label: "Show the colour key", kind: .toggle(defaultValue: true)),
        ]
        return ShareNativeChart(
            id: "weather.timeline", caption: "Each \(span)’s \(word) (the line) over how warm that \(span) was (the colour).",
            footnote: "Dots mark rainy \(span)s and diamonds snowy ones. Nothing is adjusted: this is the raw story.",
            preferredSize: .wide, controls: controls,
            zoomForShape: { $0 == .wide ? 1.7 : 1.9 }
        ) { layout, options, _ in
            let legend = options.flag("legend", true)
            return AnyView(
                TrendsWeatherTimeline(
                    weeks: result.buckets, unit: unit, metric: metric, chartHeight: max(120, layout.logical.height - (legend ? 44 : 6)),
                    showsLegend: legend, showsTemperature: options.flag("temperature", true), showsMarkers: options.flag("markers", true), showsAverage: options.flag("average", true)
                )
                .frame(maxWidth: .infinity, alignment: .topLeading)
            )
        }
    }

    // MARK: Leaning into the weather

    static func leanings(
        result: TrendsLeaningsResult, choice: String, target: QueryTarget, away: Bool, imageLookup: [String: String]
    ) -> ShareNativeChart {
        let items = away ? result.away : result.toward
        let weatherWord = TemperatureBand(rawValue: choice) != nil ? "when it is \(choice.lowercased())" : "in \(choice.lowercased() == "clear" ? "clear weather" : choice.lowercased())"
        let noun = target == .artist ? "artists" : target == .album ? "albums" : "tracks"
        let caption: String
        if let top = items.first {
            caption = away
                ? "\(top.name) is the \(noun.dropLast()) you play least \(weatherWord): \(Int(((1 - top.lift) * 100).rounded()))% less often than usual."
                : "\(top.name) leans most \(weatherWord): \(Int(((top.lift - 1) * 100).rounded()))% more often than usual."
        } else {
            caption = "Nothing clearly leans \(away ? "away from" : "toward") \(choice.lowercased()) in this period."
        }
        let controls = [
            ShareNativeControl(id: "rows", label: "Rows", kind: .count(range: 3...10, defaultValue: 5)),
            ShareNativeControl(id: "artwork", label: "Show the artwork", kind: .toggle(defaultValue: true)),
            ShareNativeControl(id: "counts", label: "Show the plays and days", kind: .toggle(defaultValue: true)),
            ShareNativeControl(id: "bars", label: "Show the bars", kind: .toggle(defaultValue: true)),
        ]
        let urls = items.map { TrendsLeaningsEngine.imageURL(for: $0, lookup: imageLookup) }
        let lines = items.enumerated().map { index, item in
            "\(index + 1). \(item.name)\(target == .artist ? "" : " — \(item.artist)") (\(percent(item.lift)); \(item.inWeather.formatted()) of \(item.plays.formatted()) plays on \(item.days.formatted()) days)"
        }
        return ShareNativeChart(
            id: "weather.leanings", caption: caption,
            footnote: "Against your usual for the same month, and only a difference of 15% or more. Each needs \(TrendsLeaningsEngine.minimumPlays)+ plays with weather" + (away ? "." : ", \(TrendsLeaningsEngine.minimumInWeather)+ of them \(weatherWord) on \(TrendsLeaningsEngine.minimumDays)+ different days."),
            preferredSize: .portrait, controls: controls, imageURLs: urls, textLines: lines,
            zoomForShape: { $0 == .wide ? 1.6 : 1.8 }
        ) { layout, options, images in
            AnyView(ShareLeaningsRows(
                items: Array(items.prefix(options.number("rows", 5))), target: target, urls: urls, images: images, layout: layout,
                showsArtwork: options.flag("artwork", true), showsCounts: options.flag("counts", true), showsBars: options.flag("bars", true)
            ))
        }
    }

    // MARK: Artist weather map

    static func weatherMap(result: TrendsWeatherMapResult, mode: TrendsWeatherMapMode, count: Int, unit: TemperatureUnit, imageLookup: [String: String] = [:]) -> ShareNativeChart {
        let all = result.bubbles(mode: mode, count: count)
        let caption: String
        if let top = all.first {
            caption = mode == .affinity
                ? "\(top.candidate.artist) leans furthest into the weather: \(TrendsWeatherMapEngine.sentence(top.placement, unit: unit))."
                : "\(top.candidate.artist) is your most played artist, most often \(TrendsWeatherMapEngine.phrase(top.placement.condition)) at \(TrendsWeatherMapEngine.rangeText(bin: top.placement.bin, unit: unit))."
        } else {
            caption = "Your artists on a map of weather against temperature."
        }
        let controls = [
            ShareNativeControl(id: "count", label: "Artists", kind: .count(range: 5...min(max(count, 10), 100), defaultValue: min(count, 25))),
            ShareNativeControl(id: "artwork", label: "Show the artwork", kind: .toggle(defaultValue: true)),
            ShareNativeControl(id: "labels", label: "Show the names", kind: .toggle(defaultValue: true)),
            ShareNativeControl(id: "density", label: "Show the shading", kind: .toggle(defaultValue: true)),
            ShareNativeControl(id: "legend", label: "Show the key", kind: .toggle(defaultValue: true)),
        ]
        var artwork: [String: String] = [:]
        for bubble in all { if let url = TrendsWeatherMapEngine.artworkURL(for: bubble.candidate.artist, lookup: imageLookup) { artwork[bubble.candidate.artist] = url } }
        let urls: [String?] = all.map { artwork[$0.candidate.artist] }
        let lines = all.prefix(10).enumerated().map { index, bubble in
            "\(index + 1). \(bubble.candidate.artist): \(TrendsWeatherMapEngine.sentence(bubble.placement, unit: unit)) (\(bubble.candidate.plays.formatted()) plays)"
        }
        return ShareNativeChart(
            id: "weather.map", caption: caption,
            footnote: "Size is plays, the ring is how far above usual the artist leans, across is its average temperature in its cell. " + (mode == .affinity ? "Each artist is placed where it leans furthest against what is usual, with \(TrendsWeatherMapEngine.minimumPlays)+ plays with weather." : "Each artist is placed where it is played most."),
            preferredSize: .wide, controls: controls, imageURLs: urls, textLines: lines,
            zoomForShape: { $0 == .wide ? 1.5 : 1.75 }
        ) { layout, options, images in
            let shown = result.bubbles(mode: mode, count: options.number("count", min(count, 25)))
            let legend = options.flag("legend", true)
            return AnyView(
                TrendsWeatherMapChart(
                    bubbles: shown, result: result, unit: unit, height: layout.logical.height, interactive: false,
                    labelCount: options.flag("labels", true) ? (shown.count <= 25 ? 14 : 8) : 0,
                    showsDensity: options.flag("density", true), showsLegend: legend, artwork: artwork, images: images, showsArtwork: options.flag("artwork", true)
                )
                .frame(maxWidth: .infinity, alignment: .topLeading)
            )
        }
    }

    // MARK: Where you listened

    static func places(result: TrendsPlacesResult, unit: TemperatureUnit) -> ShareNativeChart {
        let away = result.trips.filter { $0.days > 0 }
        var caption = "Where you listened: your trips against home."
        if let home = result.home, home.perDay > 0, !away.isEmpty {
            let days = away.reduce(0) { $0 + $1.days }
            let plays = away.reduce(0) { $0 + $1.plays }
            let rate = Double(plays) / Double(max(days, 1)) / home.perDay
            caption = "Away you play \(Int((rate * 100).rounded()))% as much as at home: \(away.count) trip\(away.count == 1 ? "" : "s"), \(days) days, \(whole(Double(plays) / Double(max(days, 1)))) plays a day against \(whole(home.perDay))."
        }
        let controls = [
            ShareNativeControl(id: "chart", label: "Show the chart", kind: .toggle(defaultValue: true)),
            ShareNativeControl(id: "rows", label: "Trips", kind: .count(range: 1...8, defaultValue: 3)),
            ShareNativeControl(id: "home", label: "Show the home row", kind: .toggle(defaultValue: true)),
            ShareNativeControl(id: "newArtists", label: "Show new artists", kind: .toggle(defaultValue: true)),
            ShareNativeControl(id: "weather", label: "Show the weather", kind: .toggle(defaultValue: true)),
            ShareNativeControl(id: "artists", label: "Show top artists", kind: .toggle(defaultValue: true)),
        ]
        let lines = result.trips.map { trip in
            "\(trip.city), \(trip.tripCount > 1 ? trip.summaryLine : dateRange(trip)): \(trip.plays.formatted()) plays, \(whole(trip.perDay)) a day" + (result.relativeToHome(trip).map { ", \(Int(($0 * 100).rounded()))% of home" } ?? "")
        }
        return ShareNativeChart(
            id: "weather.places", caption: caption,
            footnote: "A day counts as a trip day when the trip covers its middle. Plays a day is plays divided by those days.",
            preferredSize: .wide, controls: controls, textLines: lines,
            zoomForShape: { $0 == .wide ? 1.6 : 1.8 }
        ) { layout, options, _ in
            AnyView(SharePlacesView(result: result, unit: unit, layout: layout, options: options))
        }
    }

    static func dateRange(_ stay: TrendsStay) -> String {
        let format = Date.FormatStyle.dateTime.month(.abbreviated).day()
        return stay.from.formatted(format) + " – " + stay.until.addingTimeInterval(-1).formatted(format)
    }
}

// MARK: - Leaning rows

/// The ranked rows of the leanings card at the card's size: artwork, name, the plays behind it, a bar and the percentage.
struct ShareLeaningsRows: View {
    let items: [TrendsLeaningItem]
    let target: QueryTarget
    let urls: [String?]
    let images: [String: NSImage]
    let layout: ShareNativeLayout
    let showsArtwork: Bool
    let showsCounts: Bool
    let showsBars: Bool

    private var rowHeight: CGFloat {
        let count = max(items.count, 1)
        return max(34, min(96, (layout.logical.height - CGFloat(count - 1) * 8) / CGFloat(count)))
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 10) {
                    Text("\(index + 1)").font(AppTypography.compactMetadata.monospacedDigit()).foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
                    if showsArtwork { thumbnail(index) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).font(AppTypography.metadata.weight(.semibold)).lineLimit(1)
                        if target != .artist { Text(item.artist).font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1) }
                        if showsCounts {
                            Text("\(item.inWeather.formatted()) of \(item.plays.formatted()) plays · \(item.days.formatted()) days")
                                .font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 6)
                    if showsBars {
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.18))
                            Capsule().fill(WeatherPalette.lift(item.lift)).frame(width: max(6, 60 * min(1, abs(item.lift - 1))))
                        }
                        .frame(width: 60, height: 8)
                    }
                    Text(WeatherPalette.percent(item.lift)).font(AppTypography.metadata.monospacedDigit().weight(.semibold)).frame(width: 56, alignment: .trailing)
                }
                .padding(.horizontal, 8)
                .frame(height: rowHeight)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func thumbnail(_ index: Int) -> some View {
        let side = rowHeight - 10
        if index < urls.count, let url = urls[index], let image = images[url] {
            Image(nsImage: image).resizable().scaledToFill().frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.10)).frame(width: side, height: side)
                .overlay(Image(systemName: target == .artist ? "person.fill" : "music.note").foregroundStyle(.secondary))
        }
    }
}

// MARK: - Places

/// The chart and the trips of the places card at the card's size, with each part optional.
struct SharePlacesView: View {
    let result: TrendsPlacesResult
    let unit: TemperatureUnit
    let layout: ShareNativeLayout
    let options: ShareOptions

    private var trips: [TrendsStay] { Array(result.trips.prefix(options.number("rows", 3))) }
    private var rowCount: Int { trips.count + (options.flag("home", true) && result.home != nil ? 1 : 0) }
    private var showsChart: Bool { options.flag("chart", true) }
    private var rowHeight: CGFloat { 50 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsChart {
                let used = rowCount > 0 ? CGFloat(rowCount) * (rowHeight + 6) + 6 : 0
                TrendsPlacesChart(result: result, height: max(110, layout.logical.height - used - 4))
            }
            VStack(spacing: 6) {
                ForEach(trips) { trip in row(trip) }
                if options.flag("home", true), let home = result.home { row(home) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func row(_ stay: TrendsStay) -> some View {
        let perDay = stay.perDay.formatted(.number.precision(.fractionLength(0)))
        var first = "\(stay.plays.formatted()) plays · \(perDay) a day"
        if !stay.isHome, let relative = result.relativeToHome(stay) { first += " · \(Int((relative * 100).rounded()))% of home" }
        var second: [String] = []
        if options.flag("newArtists", true) { second.append("\(stay.newArtists.formatted()) new artist\(stay.newArtists == 1 ? "" : "s")") }
        if options.flag("weather", true) {
            var weather: [String] = []
            if let temperature = stay.averageTemperature { weather.append(unit.text(celsius: temperature)) }
            if let rain = stay.rainShare { weather.append("\(Int((rain * 100).rounded()))% rain") }
            if !weather.isEmpty { second.append(weather.joined(separator: ", ")) }
        }
        if options.flag("artists", true), !stay.topArtists.isEmpty { second.append(stay.topArtists.map(\.name).joined(separator: ", ")) }
        return HStack(alignment: .top, spacing: 10) {
            HStack(alignment: .top, spacing: 6) {
                Circle().fill(stay.isHome ? Color.white.opacity(0.5) : result.tint(for: stay)).frame(width: 9, height: 9).padding(.top, 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(stay.isHome ? "\(stay.city) · home" : stay.city).font(AppTypography.metadata.weight(.semibold)).lineLimit(1)
                    Text(stay.isHome ? "everything else" : (stay.tripCount > 1 ? stay.summaryLine : TrendsShareCharts.dateRange(stay))).font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: 124, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(first).font(AppTypography.metadata.monospacedDigit()).lineLimit(1)
                if !second.isEmpty { Text(second.joined(separator: " · ")).font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
        .background((stay.isHome ? Color.white : result.tint(for: stay)).opacity(stay.isHome ? 0.06 : 0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
