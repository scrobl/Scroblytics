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

            // The mark in front of the name: the red circle by default, a simple badge, or none
            let logoSuite = UserDefaults(suiteName: "share-logo-\(UUID().uuidString)")!
            check("the logo defaults to the circle; each choice reads back; junk falls back to the circle", ShareSettings.logo(defaults: logoSuite) == .circle && LastfmLogoStyle.allCases.allSatisfy { style in logoSuite.set(style.rawValue, forKey: ShareSettings.logoKey); return ShareSettings.logo(defaults: logoSuite) == style } && { logoSuite.set("nonsense", forKey: ShareSettings.logoKey); return ShareSettings.logo(defaults: logoSuite) == .circle }())
            check("the circle and wordmark artwork are in the app", NSImage(named: "LastfmLogo") != nil && NSImage(named: "LastfmWordmark") != nil)
            check("a card's identity carries the chosen mark", ShareSettings.identity(context: container.mainContext, defaults: { let d = UserDefaults(suiteName: "share-logo2-\(UUID().uuidString)")!; d.set(true, forKey: ShareSettings.showsNameKey); d.set("badge", forKey: ShareSettings.logoKey); return d }()).logo == .badge)
            var logoOptions = ShareOptions(); logoOptions.size = .square
            let logoCircle = ShareRenderer.png(card: card, options: logoOptions, identity: ShareIdentity(name: "someone", showsFooter: false, logo: .circle), images: [:])
            let logoBadge = ShareRenderer.png(card: card, options: logoOptions, identity: ShareIdentity(name: "someone", showsFooter: false, logo: .badge), images: [:])
            let logoNone = ShareRenderer.png(card: card, options: logoOptions, identity: ShareIdentity(name: "someone", showsFooter: false, logo: .none), images: [:])
            let logoWordmark = ShareRenderer.png(card: card, options: logoOptions, identity: ShareIdentity(name: "someone", showsFooter: false, logo: .wordmark), images: [:])
            check("the four marks draw four different cards", logoCircle != nil && Set([logoCircle, logoWordmark, logoBadge, logoNone]).count == 4)
            check("the wordmark keeps its proportions", abs(LastfmMark.wordmarkAspect - 352.0 / 96.0) < 0.001 && (NSImage(named: "LastfmWordmark").map { abs($0.size.width / $0.size.height - LastfmMark.wordmarkAspect) < 0.01 } ?? false))

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

            // MARK: The Collage tool shares the same way (Copy Image and Share use the renderer Save PNG always used)
            let collageItems = (1...9).map { CollageItem(id: "c\($0)", name: "Album \($0)", artist: "Artist \($0)", album: nil, metricValue: 100 - $0, imageURL: nil, periodLabel: nil) }
            for (grid, width, height) in [(CollageGrid.three, 3600, 3600), (CollageGrid.widescreen, 3600, 2025)] {
                let png = CollageGeneratorView.renderPNG(items: collageItems, images: [:], grid: grid, metric: .scrobbles, showTitles: true, showStats: true, showPeriod: false)
                let bitmap = png.flatMap { NSBitmapImageRep(data: $0) }
                check("the collage renders at \(width) × \(height) (\(grid.rawValue))", bitmap?.pixelsWide == width && bitmap?.pixelsHigh == height, "\(bitmap?.pixelsWide ?? -1)x\(bitmap?.pixelsHigh ?? -1)")
                check("…and is not blank (\(grid.rawValue))", bitmap.map { luminanceSpread($0) > 0.02 } ?? false)
            }

            // The caption under a collage: what and when, the name, the tag; each only when chosen, and the saved size grows by the strip
            let plainCollage = CollageGeneratorView.renderPNG(items: collageItems, images: [:], grid: .three, metric: .scrobbles, showTitles: true, showStats: true, showPeriod: false)
            let footerDetails = CollageFooter(details: "x", identity: .anonymous)
            let footerName = CollageFooter(details: nil, identity: ShareIdentity(name: "someone", showsFooter: false))
            let footerTag = CollageFooter(details: nil, identity: ShareIdentity(name: nil, showsFooter: true))
            check("nothing chosen means no strip", CollageFooter.none.isEmpty && !footerDetails.isEmpty && !footerName.isEmpty && !footerTag.isEmpty && CollageFooter(details: nil, identity: ShareIdentity(name: "", showsFooter: false)).isEmpty)
            for (label, footer) in [("details", footerDetails), ("name", footerName), ("tag", footerTag)] {
                for (grid, width, height) in [(CollageGrid.three, 3600, 3852), (CollageGrid.widescreen, 3600, 2277)] {
                    let png = CollageGeneratorView.renderPNG(items: collageItems, images: [:], grid: grid, metric: .scrobbles, showTitles: true, showStats: true, showPeriod: false, footer: footer)
                    let bitmap = png.flatMap { NSBitmapImageRep(data: $0) }
                    check("a collage with the \(label) strip is \(width) × \(height) (\(grid.rawValue))", bitmap?.pixelsWide == width && bitmap?.pixelsHigh == height, "\(bitmap?.pixelsWide ?? -1)x\(bitmap?.pixelsHigh ?? -1)")
                }
            }
            let collageWithName = CollageGeneratorView.renderPNG(items: collageItems, images: [:], grid: .three, metric: .scrobbles, showTitles: true, showStats: true, showPeriod: false, footer: footerName)
            let collageWithTag = CollageGeneratorView.renderPNG(items: collageItems, images: [:], grid: .three, metric: .scrobbles, showTitles: true, showStats: true, showPeriod: false, footer: footerTag)
            check("the name and the tag draw differently, and a collage without them is unchanged", collageWithName != collageWithTag && collageWithName != plainCollage && plainCollage == CollageGeneratorView.renderPNG(items: collageItems, images: [:], grid: .three, metric: .scrobbles, showTitles: true, showStats: true, showPeriod: false, footer: .none))
            let when = Date(timeIntervalSince1970: 1_760_500_000)
            let dateText = when.formatted(date: .abbreviated, time: .omitted)
            let topCaption = CollageCaption.make(source: .top, entity: .album, metric: .scrobbles, period: .year, rangeLabel: "Last 365 days")
            check("the caption says what, the period, how it is ranked and the date", topCaption.text(date: when) == "Top Albums · Last 365 days · Ranked by scrobbles · \(dateText)", topCaption.text(date: when))
            let eraCaption = CollageCaption.make(source: .period, entity: .track, metric: .timeListened, period: .decade, rangeLabel: "ignored")
            check("a release-period collage says one favorite per period instead of a range", eraCaption.text(date: when) == "Top Tracks · One favorite per release decade · Ranked by time listened · \(dateText)", eraCaption.text(date: when))
            check("the strip's height is a fixed share of the width", CollageCanvas.heightRatio(grid: .three, footer: .none) == 1 && abs(CollageCanvas.heightRatio(grid: .three, footer: footerDetails) - 1.07) < 0.0001)

            // MARK: One artist, album or track
            let profileCard = sampleProfileCard()
            check("no card until the page's numbers have loaded", ShareCards.profile(entity: .album, name: "Album A", artist: "Artist A", album: nil, imageURL: nil, periodLabel: "All time", stats: nil, metric: .scrobbles, timeListenedSeconds: nil, facts: [], yearlyTopRanks: []) == nil)
            check("a page card says what it is", profileCard.title == "Album A" && profileCard.period == "Last 12 months" && profileCard.kindID == "page.album" && profileCard.profile?.kind == "Album" && profileCard.profile?.subtitle == "Artist A" && profileCard.profile?.heroImageURL == "file:///art/a.jpg")
            check("its tiles are the headline numbers then the page's facts that have a value", profileCard.profile?.stats.map(\.label) == ["Scrobbles", "First scrobble", "Last scrobble", "Play frequency", "Released", "Turnover rate"], "\(profileCard.profile?.stats.map(\.label) ?? [])")
            check("the plays tile reads as the page shows it", profileCard.profile?.stats.first?.value == 1234.formatted())
            check("rank chips then the three highest milestones, highest first", profileCard.profile?.chips.map(\.text) == ["#3 of 2024", "#7 of 2022", "5K plays · " + Date(timeIntervalSince1970: 1_700_000_000).formatted(date: .abbreviated, time: .omitted), "1K plays · " + Date(timeIntervalSince1970: 1_650_000_000).formatted(date: .abbreviated, time: .omitted), "500 plays · " + Date(timeIntervalSince1970: 1_600_000_000).formatted(date: .abbreviated, time: .omitted)], "\(profileCard.profile?.chips.map(\.text) ?? [])")
            check("the trend carries each bucket's plays", profileCard.profile?.trend == [0, 4, 9, 2, 7, 3])
            let timeCard = ShareCards.profile(entity: .track, name: "Song A", artist: "Artist A", album: "Album A", imageURL: nil, periodLabel: "All time", stats: sampleProfileStats(), metric: .timeListened, timeListenedSeconds: 7_320, facts: [], yearlyTopRanks: [])
            check("by time listened the first tile and the text label change", timeCard?.profile?.stats.first?.label == "Time Listened" && timeCard?.valueLabel == "Time" && timeCard?.profile?.subtitle == "Artist A · Album A" && timeCard?.profile?.kind == "Track")
            let pageArtistCard = ShareCards.profile(entity: .artist, name: "Artist A", artist: nil, album: nil, imageURL: nil, periodLabel: "All time", stats: sampleProfileStats(), metric: .scrobbles, timeListenedSeconds: nil, facts: [], yearlyTopRanks: [])
            check("an artist card has no subtitle", pageArtistCard?.profile?.subtitle == "" && pageArtistCard?.profile?.kind == "Artist")
            var profileOptions = ShareOptions()
            let wideStats = ShareCard(title: "T", period: "P", measure: "", rows: [], valueLabel: "Plays", hasMovement: false, kindID: "page.album", profile: ShareProfile(kind: "Album", subtitle: "", heroImageURL: nil, stats: (1...10).map { ShareStat(label: "L\($0)", value: "\($0)") }, chips: [], trend: []))
            check("a square card has room for six tiles, a portrait one nine, a wide one eight", { profileOptions.size = .square; let a = wideStats.visibleStats(for: profileOptions).count; profileOptions.size = .portrait; let b = wideStats.visibleStats(for: profileOptions).count; profileOptions.size = .wide; return (a, b, wideStats.visibleStats(for: profileOptions).count) == (6, 9, 8) }())
            check("a page card draws only its hero picture", profileCard.pictureURLs(for: ShareOptions()) == ["file:///art/a.jpg"] && !profileCard.isList)
            profileOptions = ShareOptions()
            let profileTable = ShareText.markdownTable(profileCard, options: profileOptions)
            check("the table gives every tile, the ranks and the milestones", profileTable.contains("| Scrobbles | \(1234.formatted()) |") && profileTable.contains("| Top ranks | \\#3 of 2024, \\#7 of 2022 |") && profileTable.contains("| Milestones |") && profileTable.contains("**Album A** — Artist A · Last 12 months"), profileTable)
            check("the list uses bullets and bold labels", ShareText.markdownList(profileCard, options: profileOptions).contains("- **Scrobbles:** \(1234.formatted())"))
            let plainProfile = ShareText.plain(profileCard, options: profileOptions)
            check("plain text has no formatting characters", plainProfile.contains("Scrobbles: \(1234.formatted())") && !plainProfile.contains("**") && plainProfile.hasPrefix("Album A — Artist A · Last 12 months"), plainProfile)
            var pageHidden = profileOptions; pageHidden.showValues = false; pageHidden.showDate = false
            check("a page card ignores the plays switch (it has none), and the date goes with its switch", ShareText.markdownList(profileCard, options: pageHidden).contains("Scrobbles") && !ShareText.plain(profileCard, options: pageHidden).contains(ShareText.dateText(profileCard)) && ShareText.plain(profileCard, options: profileOptions).contains(ShareText.dateText(profileCard)))
            check("the plays switch is for lists only", ShareCards.topChart(entries: sampleEntries(), entity: .album, metric: .scrobbles, periodLabel: "P").isList && !profileCard.isList)
            var pageOdd = profileCard; pageOdd.title = "Song *1* | one"
            check("names are escaped in the table", ShareText.markdownTable(pageOdd, options: profileOptions).contains("Song \\*1\\* \\| one"))
            let profileNamed = ShareText.markdownTable(profileCard, options: profileOptions, identity: ShareIdentity(name: "someone_88", showsFooter: true))
            check("a chosen name and the footer appear once each in a page card's text; by default neither", profileNamed.components(separatedBy: "someone\\_88").count == 2 && profileNamed.components(separatedBy: "Scroblytics").count == 2 && !profileTable.contains("Scroblytics") && !profileTable.contains("someone"))
            let linePoints = ShareTrendLine.points([0, 5, 10], in: CGSize(width: 100, height: 50))
            check("the trend line runs from the left edge to the right, busiest at the top", linePoints.count == 3 && linePoints[0] == CGPoint(x: 0, y: 46) && linePoints[1] == CGPoint(x: 50, y: 25) && linePoints[2] == CGPoint(x: 100, y: 4), "\(linePoints)")
            check("fewer than two buckets draw no line", ShareTrendLine.points([5], in: CGSize(width: 100, height: 50)).isEmpty)
            let heroSwatch = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in NSColor.systemTeal.setFill(); rect.fill(); return true }
            for size in ShareSize.allCases {
                var o = ShareOptions(); o.size = size
                let png = ShareRenderer.png(card: profileCard, options: o, identity: .anonymous, images: [:])
                let image = png.flatMap { NSBitmapImageRep(data: $0) }
                check("page card, \(size.label): a PNG at 2x the card size", image?.pixelsWide == Int(size.points.width) * 2 && image?.pixelsHigh == Int(size.points.height) * 2)
                check("page card, \(size.label): something is drawn", image.map { luminanceSpread($0) > 0.05 } ?? false)
                let withHero = ShareRenderer.png(card: profileCard, options: o, identity: .anonymous, images: ["file:///art/a.jpg": heroSwatch])
                let withFooter = ShareRenderer.png(card: profileCard, options: o, identity: ShareIdentity(name: "someone", showsFooter: true), images: [:])
                check("page card, \(size.label): the hero picture and the identity footer change the image", withHero != png && withFooter != png)
                let bare = ShareCard(title: "日本語のとても長いタイトルがここに入りますよ and a very long name that never fits on a single line of a card", period: "A very long period name", measure: "", rows: [], valueLabel: "Plays", hasMovement: false, kindID: "page.artist", profile: ShareProfile(kind: "Artist", subtitle: "", heroImageURL: nil, stats: [ShareStat(label: "Scrobbles", value: "1")], chips: [], trend: []))
                check("page card, \(size.label): one tile, no chips and no trend still renders", (ShareRenderer.png(card: bare, options: o, identity: named, images: [:]).flatMap { NSBitmapImageRep(data: $0) }?.pixelsWide ?? 0) == Int(size.points.width) * 2)
            }

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
        // The page cards: the top artist, album and track of the period, built from the same engines the pages use, against plain counts.
        let context = container.mainContext
        for entity in TopChartsEntity.allCases {
            guard let top = (try? await TopChartsEngine.fetchRankings(container: container, entity: entity, range: range, compareRange: nil, limit: 1, includePeak: false))?.first else {
                check("\(entity.displayName): a top entry for the page card", false); continue
            }
            let stats: EntityStats?
            switch entity {
            case .artist: stats = try? EntityStatsEngine.fetchArtistStats(context: context, artist: top.name, range: range)
            case .album: stats = try? EntityStatsEngine.fetchAlbumStats(context: context, artist: top.artist ?? "", album: top.name, range: range)
            case .track: stats = try? EntityStatsEngine.fetchTrackStats(context: context, artist: top.artist ?? "", track: top.name, range: range)
            }
            let ranks = (try? await TopChartsEngine.fetchYearlyTopRanks(container: container, entity: entity, name: top.name, artist: entity == .artist ? nil : top.artist)) ?? []
            guard let card = ShareCards.profile(entity: entity, name: top.name, artist: entity == .artist ? nil : top.artist, album: nil, imageURL: top.imageURL, periodLabel: "Last 365 days", stats: stats, metric: .scrobbles, timeListenedSeconds: nil, facts: [], yearlyTopRanks: ranks) else {
                check("\(entity.displayName): the page card builds", false); continue
            }
            let artistKey = top.artist.map(TextNormalization.artistIdentityKey)
            let plays = inRange.filter { play in
                switch entity {
                case .artist: TextNormalization.artistIdentityKey(play.artistName) == TextNormalization.artistIdentityKey(top.name)
                case .album: play.albumName == top.name && TextNormalization.artistIdentityKey(play.artistName) == artistKey
                case .track: play.trackName == top.name && TextNormalization.artistIdentityKey(play.artistName) == artistKey
                }
            }
            let tiles = Dictionary(uniqueKeysWithValues: (card.profile?.stats ?? []).map { ($0.label, $0.value) })
            func day(_ date: Date?) -> String { date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—" }
            check("\(entity.displayName) page card: scrobbles equal an independent count (\(plays.count))", tiles["Scrobbles"] == plays.count.formatted(), "\(tiles["Scrobbles"] ?? "none")")
            check("\(entity.displayName) page card: first and last scrobble equal the history's own", tiles["First scrobble"] == day(plays.map(\.playedAt).min()) && tiles["Last scrobble"] == day(plays.map(\.playedAt).max()), "\(tiles["First scrobble"] ?? "none") / \(tiles["Last scrobble"] ?? "none")")
            check("\(entity.displayName) page card: the trend adds up to the plays", (card.profile?.trend.reduce(0, +) ?? 0) == plays.count, "\(card.profile?.trend.reduce(0, +) ?? -1) vs \(plays.count)")
            if entity == .artist, let rankChip = ranks.first {
                let yearPlays = history.filter { AppCalendars.listening.component(.year, from: $0.playedAt) == rankChip.year }
                let counts = Dictionary(grouping: yearPlays, by: { TextNormalization.artistIdentityKey($0.artistName) }).mapValues(\.count)
                let mine = counts[TextNormalization.artistIdentityKey(top.name)] ?? 0
                let better = counts.values.filter { $0 > mine }.count
                let tied = counts.values.filter { $0 == mine }.count
                check("artist page card: the \(rankChip.year) rank chip (#\(rankChip.rank)) fits an independent ranking (\(better + 1)–\(better + tied))", rankChip.rank >= better + 1 && rankChip.rank <= better + tied)
            }
            let urls = ShareRenderer.imageURLs(card: card, options: ShareOptions())
            let images = await ShareArtwork.load(urls)
            for size in ShareSize.allCases {
                var options = ShareOptions(); options.size = size
                let start = Date()
                let png = ShareRenderer.png(card: card, options: options, identity: .anonymous, images: images)
                let seconds = Date().timeIntervalSince(start)
                if let png { try? png.write(to: URL(fileURLWithPath: folder).appending(path: "real-page-\(entity.rawValue)-\(size.rawValue).png")) }
                check("\(entity.displayName) page card, \(size.label): rendered in \(String(format: "%.2f", seconds)) s (\(images.count) of \(urls.compactMap { $0 }.count) pictures)", png != nil && seconds < 3)
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


    // MARK: Page card samples

    static func sampleProfileStats() -> EntityStats {
        let achieved: [(milestone: Int, achievedAt: Date, firstAt: Date)] = [
            (500, Date(timeIntervalSince1970: 1_600_000_000), Date(timeIntervalSince1970: 1_500_000_000)),
            (5000, Date(timeIntervalSince1970: 1_700_000_000), Date(timeIntervalSince1970: 1_500_000_000)),
            (1000, Date(timeIntervalSince1970: 1_650_000_000), Date(timeIntervalSince1970: 1_500_000_000)),
            (100, Date(timeIntervalSince1970: 1_550_000_000), Date(timeIntervalSince1970: 1_500_000_000)),
        ]
        let counts = [0, 4, 9, 2, 7, 3]
        return EntityStats(
            plays: 1234, firstScrobble: Date(timeIntervalSince1970: 1_500_000_000), lastScrobble: Date(timeIntervalSince1970: 1_760_000_000), imageURL: nil, loved: false,
            trend: counts.enumerated().map { TrendBucket(start: Date(timeIntervalSince1970: 1_500_000_000 + Double($0.offset) * 86_400), count: $0.element) },
            milestones: MilestonesEngine.EntityMilestones(achieved: achieved, upcoming: nil)
        )
    }

    @MainActor
    static func sampleProfileCard(imageURL: String? = "file:///art/a.jpg") -> ShareCard {
        let facts = [
            DetailFact(id: "released", label: "Released", value: .text("Sep 12, 2018")),
            DetailFact(id: "turnover", label: "Turnover rate", value: .text("1.4 per year")),
            DetailFact(id: "tempo", label: "Tempo", value: .loading),
            DetailFact(id: "length", label: "Length", value: .unknown),
        ]
        return ShareCards.profile(
            entity: .album, name: "Album A", artist: "Artist A", album: nil, imageURL: imageURL, periodLabel: "Last 12 months",
            stats: sampleProfileStats(), metric: .scrobbles, timeListenedSeconds: nil, facts: facts,
            yearlyTopRanks: [TopChartsEngine.YearlyRank(year: 2024, rank: 3), TopChartsEngine.YearlyRank(year: 2022, rank: 7)],
            now: Date(timeIntervalSince1970: 1_760_500_000)
        )!
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
        // The page cards: an album with everything, a track with a long name and few numbers, an artist with no picture.
        let hero = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in NSColor(hue: 0.08, saturation: 0.6, brightness: 0.85, alpha: 1).setFill(); rect.fill(); return true }
        var longTrack = sampleProfileCard()
        longTrack.title = "An extremely long track title that will never fit on a single line of a card 🎵"
        longTrack.profile?.kind = "Track"
        longTrack.profile?.subtitle = "Artist with a long name & Friends · An album with an equally long title"
        let fewStats = Array((longTrack.profile?.stats ?? []).prefix(4))
        longTrack.profile?.stats = fewStats
        longTrack.profile?.chips = []
        var noPicture = sampleProfileCard(imageURL: nil)
        noPicture.profile?.kind = "Artist"
        noPicture.profile?.subtitle = ""
        for (name, c, images, identity) in [("page-album", sampleProfileCard(), ["file:///art/a.jpg": hero], ShareIdentity(name: "someone", showsFooter: true)), ("page-longtrack", longTrack, ["file:///art/a.jpg": hero], ShareIdentity.anonymous), ("page-artist", noPicture, [:], ShareIdentity.anonymous)] {
            for size in ShareSize.allCases {
                var o = ShareOptions(); o.size = size
                if let png = ShareRenderer.png(card: c, options: o, identity: identity, images: images, scale: 1) {
                    try? png.write(to: URL(fileURLWithPath: folder).appending(path: "\(name)-\(size.rawValue).png"))
                }
            }
        }
        for style in LastfmLogoStyle.allCases {
            var o = ShareOptions(); o.size = .square
            if let png = ShareRenderer.png(card: card, options: o, identity: ShareIdentity(name: "someone", showsFooter: true, logo: style), images: swatches, scale: 1) {
                try? png.write(to: URL(fileURLWithPath: folder).appending(path: "logo-\(style.rawValue).png"))
            }
        }
        // The collage with its caption: what and when, the name and the tag.
        let collageItems = (1...9).map { CollageItem(id: "c\($0)", name: "Album \($0)", artist: "Artist \($0)", album: nil, metricValue: 100 - $0, imageURL: nil, periodLabel: nil) }
        let collageFooter = CollageFooter(
            details: CollageCaption.make(source: .top, entity: .album, metric: .scrobbles, period: .year, rangeLabel: "Last 365 days").text(date: Date()),
            identity: ShareIdentity(name: "someone", showsFooter: true)
        )
        for (name, grid) in [("collage-3x3", CollageGrid.three), ("collage-wide", CollageGrid.widescreen)] {
            if let png = CollageGeneratorView.renderPNG(items: collageItems, images: [:], grid: grid, metric: .scrobbles, showTitles: true, showStats: true, showPeriod: false, footer: collageFooter) {
                try? png.write(to: URL(fileURLWithPath: folder).appending(path: "\(name).png"))
            }
        }
    }
}
#endif
