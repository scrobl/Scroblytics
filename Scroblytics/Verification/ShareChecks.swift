import AppKit
import Foundation
import SwiftData
import SwiftUI

#if DEBUG
/// `SCROBLYTICS_SHARE_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): the Share cards on made-up data: how a chart becomes a
/// card (ranks, movement, values), the text forms and their escaping, the two identity switches, the image sizes and that an image is
/// really drawn (not blank), including awkward names, no pictures and very few or many rows. `SCROBLYTICS_SHARE_SNAPSHOT=<folder>`
/// writes the cards as PNGs so they can be looked at. Exits 0 on success.
enum ShareChecks {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        let env = ProcessInfo.processInfo.environment
        if let folder = env["SCROBLYTICS_SHARE_DUMP"] {
            Task { @MainActor in await dumpRealLibrary(into: folder, container: container) }
            return
        }
        if let folder = env["SCROBLYTICS_SHARE_SYMBOLTEST"] {
            Task { @MainActor in
                let view = HStack(spacing: 20) {
                    Image(systemName: "lastfm").font(.system(size: 120)).foregroundStyle(.red)
                    Image(systemName: "music.note").font(.system(size: 120)).foregroundStyle(.red)
                }.padding(20).background(Color.white)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 1
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: folder))
                }
                exit(0)
            }
            return
        }
        if let folder = env["SCROBLYTICS_SHARE_SNAPSHOT_POPOVER"] {
            Task { @MainActor in await writePopoverSnapshots(into: folder, container: container) }
            return
        }
        if let folder = env["SCROBLYTICS_SHARE_SNAPSHOT"] {
            Task { @MainActor in writeSnapshots(into: folder); exit(0) }
            return
        }
        guard env["SCROBLYTICS_SHARE_CHECK"] != nil else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }

            // MARK: A chart becomes a card
            check("no comparison period: no change shown", ShareCards.change(rank: 3, previous: 1, hasCompareRange: false) == ShareChange.none)
            check("not charted before: NEW", ShareCards.change(rank: 3, previous: nil, hasCompareRange: true) == .new)
            check("same place: same", ShareCards.change(rank: 3, previous: 3, hasCompareRange: true) == .same)
            check("better than before: up by the places gained", ShareCards.change(rank: 2, previous: 7, hasCompareRange: true) == .up(5))
            check("worse than before: down by the places lost", ShareCards.change(rank: 9, previous: 4, hasCompareRange: true) == .down(5))

            let entries = sampleEntries()
            let card = ShareCards.topChart(entries: entries, entity: .album, metric: .scrobbles, periodLabel: "Year to date")
            check("the card says what it is", card.title == "Top Albums" && card.period == "Year to date" && card.measure == "Ranked by scrobbles" && card.kindID == "topChart.album")
            check("one row per entry, in rank order, with the artist beneath an album", card.rows.map(\.rank) == [1, 2, 3, 4] && card.rows[0].subtitle == "Artist A" && card.rows.map(\.title) == entries.map(\.name))
            check("values are the play counts, grouped", card.rows[0].value == "1,204" && card.rows[1].value == "87" && card.valueLabel == "Plays")
            check("changes follow each entry's previous rank", card.rows.map(\.change) == [.up(2), .same, .new, .down(1)], "\(card.rows.map(\.change))")
            check("movement is offered when a comparison exists", card.hasMovement)
            let artistCard = ShareCards.topChart(entries: entries, entity: .artist, metric: .timeListened, periodLabel: "All time")
            check("an artist chart has no subtitle under each name, and shows time", artistCard.rows.allSatisfy { $0.subtitle == nil } && artistCard.valueLabel == "Time" && artistCard.rows[0].value == DurationEngine.formatTimeListened(7_300))
            let noCompare = ShareCards.topChart(entries: entries.map { sample($0, hasCompare: false) }, entity: .track, metric: .scrobbles, periodLabel: "x")
            check("without a comparison there is no movement to show", !noCompare.hasMovement && noCompare.rows.allSatisfy { $0.change == ShareChange.none })
            check("the first rows for the options, never more than exist", card.visibleRows(for: ShareOptions(rowCount: 2)).count == 2 && card.visibleRows(for: ShareOptions(rowCount: 20)).count == 4)

            // MARK: Text
            check("Markdown formatting characters in a name are escaped", ShareText.escape("A_B *C* [D] |E| <F> #G ~H `I`") == "A\\_B \\*C\\* \\[D\\] \\|E\\| \\<F\\> \\#G \\~H \\`I\\`")
            check("a name with a line break stays on one line", ShareText.escape("a\nb") == "a b")
            let options = ShareOptions()
            let table = ShareText.markdownTable(card, options: options)
            let tableLines = table.split(separator: "\n").map(String.init)
            check("the table has a title, a header row, a separator and a row each", tableLines.count == 3 + card.rows.count, "\(tableLines.count)")
            check("…and the columns agree on every line", Set(tableLines.dropFirst(1).map { $0.filter { $0 == "|" }.count - $0.components(separatedBy: "\\|").count + 1 }).count == 1)
            check("the table carries artist, plays and move", tableLines[1].contains("Artist") && tableLines[1].contains("Plays") && tableLines[1].contains("Move") && table.contains("▲2") && table.contains("NEW") && table.contains("▼1"))
            var hidden = options; hidden.showValues = false; hidden.showMovement = false
            let bare = ShareText.markdownTable(card, options: hidden)
            check("with values and movement off neither appears", !bare.contains("Plays") && !bare.contains("Move") && !bare.contains("1,204") && !bare.contains("▲"))
            let list = ShareText.markdownList(card, options: options)
            check("the list numbers the rows and bolds the names", list.contains("1. **Album One**") && list.contains("(1,204 plays, ▲2)"), list)
            let plain = ShareText.plain(card, options: options)
            check("plain text has no Markdown characters added", !plain.contains("**") && plain.contains("1. Album One — Artist A (1,204 plays, ▲2)"), plain)
            let odd = ShareCard(title: "T", period: "P", measure: "M", rows: [ShareRow(rank: 1, title: "Song *1* | one", subtitle: "A_B", value: "3", change: .none, imageURL: nil)], valueLabel: "Plays", hasMovement: false, kindID: "x")
            check("an awkward name stays one table cell", !ShareText.markdownTable(odd, options: options).split(separator: "\n").last!.dropFirst().contains("*1*") || ShareText.markdownTable(odd, options: options).contains("Song \\*1\\* \\| one"))

            // MARK: Date and what the movement is measured against
            let dated = ShareCards.topChart(entries: entries, entity: .album, metric: .scrobbles, periodLabel: "Last 365 days", compareRange: DateRange(from: Date(timeIntervalSince1970: 1_700_000_000), to: Date(timeIntervalSince1970: 1_731_536_000)), now: Date(timeIntervalSince1970: 1_760_000_000))
            let expectedDate = Date(timeIntervalSince1970: 1_760_000_000).formatted(date: .abbreviated, time: .omitted)
            check("the card carries the date it was made", dated.generatedAt == Date(timeIntervalSince1970: 1_760_000_000) && ShareText.dateText(dated) == expectedDate)
            let compareWindow = DateRange(from: Date(timeIntervalSince1970: 1_700_000_000), to: Date(timeIntervalSince1970: 1_731_536_000))
            let sinceDate = Date(timeIntervalSince1970: 1_731_536_000).formatted(date: .abbreviated, time: .omitted)
            check("movement is 'since' the day the comparison chart ends", dated.movementNote == "since \(sinceDate)" && !(dated.movementNote ?? "").contains("–"), dated.movementNote ?? "nil")
            let startDate = Date(timeIntervalSince1970: 1_700_000_000).formatted(date: .abbreviated, time: .omitted)
            check("the note is the comparison's end date, not its start", ShareCards.movementSince(compareWindow) == "since \(sinceDate)" && (startDate == sinceDate || !ShareCards.movementSince(compareWindow).contains(startDate)))
            check("one day is one date, not a range", ShareCards.rangeLabel(DateRange(from: Date(timeIntervalSince1970: 1_700_000_000), to: Date(timeIntervalSince1970: 1_700_000_100))) == Date(timeIntervalSince1970: 1_700_000_000).formatted(date: .abbreviated, time: .omitted))
            check("no comparison period, no movement note", noCompare.movementNote == nil && card.movementNote == nil)
            let datedTable = ShareText.markdownTable(dated, options: options)
            check("the text forms show the date and, with movement on, what it is against", datedTable.contains(expectedDate) && datedTable.contains("Movement (▲▼) since \(sinceDate)") && ShareText.markdownList(dated, options: options).contains(expectedDate) && ShareText.plain(dated, options: options).contains(expectedDate) && ShareText.plain(dated, options: options).contains("Movement (▲▼) since"))
            var noDate = options; noDate.showDate = false
            var noMove = options; noMove.showMovement = false
            check("with the date off it is gone from every text form", !ShareText.markdownTable(dated, options: noDate).contains(expectedDate) && !ShareText.markdownList(dated, options: noDate).contains(expectedDate) && !ShareText.plain(dated, options: noDate).contains(expectedDate))
            check("with movement off the comparison note is gone too", !ShareText.markdownTable(dated, options: noMove).contains("Movement") && !ShareText.plain(dated, options: noMove).contains("Movement"))
            var square = ShareOptions(); square.size = .square
            let withDate = ShareRenderer.png(card: dated, options: square, identity: .anonymous, images: [:])
            var squareNoDate = square; squareNoDate.showDate = false
            var squareNoMove = square; squareNoMove.showMovement = false
            check("the date appears on the image and goes when switched off", withDate != nil && withDate != ShareRenderer.png(card: dated, options: squareNoDate, identity: .anonymous, images: [:]))
            check("the comparison caption appears on the image with movement on, and goes with it off", withDate != ShareRenderer.png(card: dated, options: squareNoMove, identity: .anonymous, images: [:]))
            check("the Last.fm badge precedes a shown name (the image differs with and without a name)", ShareRenderer.png(card: dated, options: squareNoDate, identity: ShareIdentity(name: "someone", showsFooter: false), images: [:]) != ShareRenderer.png(card: dated, options: squareNoDate, identity: .anonymous, images: [:]))

            // MARK: Identity: nothing about the person unless chosen
            let anonymous = ShareText.markdownTable(card, options: options, identity: .anonymous)
            check("by default no name and no footer in any text form", !anonymous.contains("Scroblytics") && !ShareText.plain(card, options: options).contains("Scroblytics") && !ShareText.markdownList(card, options: options).contains("Scroblytics"))
            let named = ShareIdentity(name: "someone_88", showsFooter: true)
            check("a chosen name appears once, escaped, and the footer once", ShareText.markdownTable(card, options: options, identity: named).components(separatedBy: "someone\\_88").count == 2 && ShareText.markdownTable(card, options: options, identity: named).components(separatedBy: "Scroblytics").count == 2)
            check("plain text gives the name unescaped", ShareText.plain(card, options: options, identity: named).contains("(someone_88)"))
            let suite = UserDefaults(suiteName: "share-check-\(UUID().uuidString)")!
            check("the identity switches start off", !ShareSettings.showsName(defaults: suite) && !ShareSettings.showsFooter(defaults: suite))
            var chosen = ShareOptions(); chosen.size = .portrait; chosen.rowCount = 15; chosen.showMovement = false
            ShareSettings.save(chosen, for: "topChart.album", defaults: suite)
            check("options are remembered per kind of card", ShareSettings.options(for: "topChart.album", defaults: suite) == chosen && ShareSettings.options(for: "topChart.track", defaults: suite) == ShareOptions())

            // MARK: Images
            check("the three sizes in points", ShareSize.square.points == CGSize(width: 1080, height: 1080) && ShareSize.portrait.points == CGSize(width: 1080, height: 1350) && ShareSize.wide.points == CGSize(width: 1920, height: 1080))
            for size in ShareSize.allCases {
                var o = ShareOptions(); o.size = size
                let png = ShareRenderer.png(card: card, options: o, identity: .anonymous, images: [:])
                let image = png.flatMap { NSBitmapImageRep(data: $0) }
                check("\(size.label): a PNG at 2x the card size", image?.pixelsWide == Int(size.points.width) * 2 && image?.pixelsHigh == Int(size.points.height) * 2, "\(image?.pixelsWide ?? -1)x\(image?.pixelsHigh ?? -1)")
                check("\(size.label): something is drawn (not blank)", image.map { luminanceSpread($0) > 0.05 } ?? false, "\(image.map { luminanceSpread($0) } ?? -1)")
            }
            let awkward = ShareCard(
                title: "Top Tracks", period: "A very long period name that goes on and on and on", measure: "Ranked by time listened",
                rows: (1...20).map { i in ShareRow(rank: i, title: i % 3 == 0 ? "日本語のとても長いタイトルがここに入りますよ \(i)" : (i % 3 == 1 ? "An extremely long track title that will never fit on one line of a card \(i) 🎵🎶" : "Short \(i)"), subtitle: "Artist with a long name \(i) & Friends", value: "3d 4h 12m", change: i % 4 == 0 ? .new : (i % 2 == 0 ? .up(i) : .down(i)), imageURL: nil) },
                valueLabel: "Time", hasMovement: true, kindID: "topChart.track"
            )
            for count in [1, 5, 20] {
                for size in ShareSize.allCases {
                    var o = ShareOptions(); o.size = size; o.rowCount = count
                    let png = ShareRenderer.png(card: awkward, options: o, identity: named, images: [:])
                    check("awkward names, \(count) row\(count == 1 ? "" : "s"), \(size.label): renders", (png.flatMap { NSBitmapImageRep(data: $0) }?.pixelsWide ?? 0) == Int(size.points.width) * 2)
                }
            }
            var squareOptions = ShareOptions(); squareOptions.size = .square
            let plainData = ShareRenderer.png(card: card, options: squareOptions, identity: .anonymous, images: [:])
            let again = ShareRenderer.png(card: card, options: squareOptions, identity: .anonymous, images: [:])
            let withName = ShareRenderer.png(card: card, options: squareOptions, identity: ShareIdentity(name: "someone", showsFooter: false), images: [:])
            let withFooter = ShareRenderer.png(card: card, options: squareOptions, identity: ShareIdentity(name: nil, showsFooter: true), images: [:])
            check("the same card renders the same image twice", plainData != nil && plainData == again)
            check("turning on the name or the footer changes the image, and each differently", plainData != withName && plainData != withFooter && withName != withFooter)
            // A real picture: a flat colour stands in for artwork; the card must use it.
            let swatch = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in NSColor.systemRed.setFill(); rect.fill(); return true }
            let withArt = ShareRenderer.png(card: card, options: squareOptions, identity: .anonymous, images: [entries[0].imageURL ?? "": swatch])
            check("a loaded picture is drawn on the card", withArt != nil && withArt != plainData)

            print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }


    /// `SCROBLYTICS_SHARE_DUMP=<folder>` (with `SCROBLYTICS_STORE_PATH` on a COPY of a library and `SCROBLYTICS_OFFLINE=1`): builds the Top Charts
    /// cards from the copy's last year against the year before, checks the top rows against an independent count of the plays, and writes the
    /// images (with whatever artwork is saved on this Mac) with how long each took. Exits 0 on success.
    @MainActor
    private static func dumpRealLibrary(into folder: String, container: ModelContainer) async {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
            if !ok { failures += 1 }
        }
        let calendar = AppCalendars.listening
        let now = Date()
        let yearAgo = calendar.date(byAdding: .year, value: -1, to: now)!
        let twoYearsAgo = calendar.date(byAdding: .year, value: -2, to: now)!
        let range = DateRange(from: yearAgo, to: now)
        let compare = DateRange(from: twoYearsAgo, to: yearAgo.addingTimeInterval(-1))
        let history = (try? await ScrobbleHistoryCache.shared.snapshots(container: container)) ?? []
        check("the copy has plays", !history.isEmpty, "\(history.count)")
        let inRange = history.filter { $0.playedAt >= range.from && $0.playedAt <= range.to }
        for entity in TopChartsEntity.allCases {
            guard let entries = try? await TopChartsEngine.fetchRankings(container: container, entity: entity, range: range, compareRange: compare, limit: 20, includePeak: false) else {
                check("\(entity.displayName): the chart loads", false); continue
            }
            let card = ShareCards.topChart(entries: entries, entity: entity, metric: .scrobbles, periodLabel: "Last 365 days")
            check("\(entity.displayName): the card has \(card.rows.count) rows, in order", card.rows.map(\.rank) == Array(1...max(card.rows.count, 1)) || card.rows.isEmpty)
            // Independent count for the top three: the plays of that exact name (and artist), straight from the history.
            for entry in entries.prefix(3) {
                let artistKey = entry.artist.map(TextNormalization.artistIdentityKey)
                let plays = inRange.filter { play in
                    switch entity {
                    case .artist: TextNormalization.artistIdentityKey(play.artistName) == TextNormalization.artistIdentityKey(entry.name)
                    case .album: play.albumName == entry.name && TextNormalization.artistIdentityKey(play.artistName) == artistKey
                    case .track: play.trackName == entry.name && TextNormalization.artistIdentityKey(play.artistName) == artistKey
                    }
                }.count
                check("\(entity.displayName) #\(entry.rank): the card's plays equal an independent count (\(plays))", card.rows[entry.rank - 1].value == plays.formatted() && entry.playcount == plays, "\(entry.playcount) vs \(plays)")
            }
            let urls = ShareRenderer.imageURLs(card: card, options: ShareOptions(rowCount: 20))
            let loadStart = Date()
            let images = await ShareArtwork.load(urls)
            let loaded = Date().timeIntervalSince(loadStart)
            for size in ShareSize.allCases {
                var options = ShareOptions(); options.size = size; options.rowCount = size == .wide ? 20 : 10
                let start = Date()
                let png = ShareRenderer.png(card: card, options: options, identity: .anonymous, images: images)
                let seconds = Date().timeIntervalSince(start)
                if let png { try? png.write(to: URL(fileURLWithPath: folder).appending(path: "real-\(entity.rawValue)-\(size.rawValue).png")) }
                check("\(entity.displayName), \(size.label): rendered in \(String(format: "%.2f", seconds)) s (\(images.count) of \(urls.compactMap { $0 }.count) pictures loaded in \(String(format: "%.2f", loaded)) s)", png != nil && seconds < 3)
            }
        }
        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }


    @MainActor
    private static func writePopoverSnapshots(into folder: String, container: ModelContainer) async {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let card = ShareCards.topChart(entries: sampleEntries(), entity: .album, metric: .scrobbles, periodLabel: "Year to date")
        for dark in [true, false] {
            let view = SharePopoverPreview.view(card: card)
                .modelContainer(container)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            for _ in 0..<12 { try? await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded() }
            window.setContentSize(NSSize(width: 440, height: host.fittingSize.height))
            for _ in 0..<4 { try? await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded() }
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appending(path: "popover-\(dark ? "dark" : "light").png"))
            }
        }
        exit(0)
    }

    // MARK: Samples

    private static func sample(_ entry: TopChartEntry, hasCompare: Bool) -> TopChartEntry {
        TopChartEntry(
            rank: entry.rank, name: entry.name, artist: entry.artist, album: entry.album, playcount: entry.playcount,
            timeListenedSeconds: entry.timeListenedSeconds, imageURL: entry.imageURL, hasCompareRange: hasCompare, previousRank: entry.previousRank,
            peakRank: entry.peakRank, lastPlayedAt: entry.lastPlayedAt, loved: entry.loved, releaseDateResolution: .unknown
        )
    }

    static func sampleEntries() -> [TopChartEntry] {
        func entry(_ rank: Int, _ name: String, plays: Int, previous: Int?, seconds: Int) -> TopChartEntry {
            TopChartEntry(
                rank: rank, name: name, artist: "Artist \(Character(UnicodeScalar(64 + rank)!))", album: nil, playcount: plays, timeListenedSeconds: seconds,
                imageURL: "file:///nonexistent/\(rank).jpg", hasCompareRange: true, previousRank: previous, peakRank: rank,
                lastPlayedAt: Date(timeIntervalSince1970: 1_700_000_000), loved: false, releaseDateResolution: .unknown
            )
        }
        return [
            entry(1, "Album One", plays: 1_204, previous: 3, seconds: 7_300), entry(2, "Album Two", plays: 87, previous: 2, seconds: 900),
            entry(3, "Album Three", plays: 60, previous: nil, seconds: 500), entry(4, "Album Four", plays: 41, previous: 3, seconds: 300),
        ]
    }

    /// The spread (standard deviation) of the picture's brightness: a blank card has none.
    private static func luminanceSpread(_ bitmap: NSBitmapImageRep) -> Double {
        let step = max(1, bitmap.pixelsWide / 120)
        var values: [Double] = []
        var y = 0
        while y < bitmap.pixelsHigh {
            var x = 0
            while x < bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    values.append(0.299 * Double(color.redComponent) + 0.587 * Double(color.greenComponent) + 0.114 * Double(color.blueComponent))
                }
                x += step
            }
            y += step
        }
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)).squareRoot()
    }

    // MARK: Snapshots

    @MainActor
    private static func writeSnapshots(into folder: String) {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let compare = DateRange(from: Date(timeIntervalSince1970: 1_697_500_000), to: Date(timeIntervalSince1970: 1_728_000_000))
        let card = ShareCards.topChart(entries: sampleEntries(), entity: .album, metric: .scrobbles, periodLabel: "Year to date", compareRange: compare)
        let long = ShareCard(
            title: "Top Tracks", period: "Last 30 days", measure: "Ranked by scrobbles",
            rows: (1...20).map { i in ShareRow(rank: i, title: i % 3 == 0 ? "日本語のとても長いタイトルがここに入りますよ \(i)" : (i % 3 == 1 ? "An extremely long track title that will never fit on one line \(i) 🎵" : "Short \(i)"), subtitle: "Artist with a long name \(i)", value: "\(1_000 - i * 37)", change: i % 4 == 0 ? .new : (i % 2 == 0 ? .up(i) : .down(i)), imageURL: nil) },
            valueLabel: "Plays", hasMovement: true, movementNote: ShareCards.movementSince(compare), kindID: "topChart.track"
        )
        let swatches: [String: NSImage] = Dictionary(uniqueKeysWithValues: sampleEntries().enumerated().map { index, entry in
            let hue = CGFloat(index) / 4
            return (entry.imageURL ?? "", NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in NSColor(hue: hue, saturation: 0.55, brightness: 0.8, alpha: 1).setFill(); rect.fill(); return true })
        })
        for (name, c, count, images, identity) in [("album4", card, 4, swatches, ShareIdentity(name: "someone", showsFooter: false)), ("long20", long, 20, [:], ShareIdentity(name: "someone", showsFooter: true)), ("long5", long, 5, [:], ShareIdentity.anonymous), ("one", card, 1, swatches, ShareIdentity.anonymous)] {
            for size in ShareSize.allCases {
                var o = ShareOptions(); o.size = size; o.rowCount = count
                if let png = ShareRenderer.png(card: c, options: o, identity: identity, images: images, scale: 1) {
                    try? png.write(to: URL(fileURLWithPath: folder).appending(path: "\(name)-\(size.rawValue).png"))
                }
            }
        }
    }
}
#endif
