import AppKit
import Foundation
import MachO
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
        if let folder = env["SCROBLYTICS_SHARE_SNAPSHOT_TRENDS"] {
            Task { @MainActor in await writeTrendsSnapshots(into: folder) }
            return
        }
        if env["SCROBLYTICS_SHARE_STRESS"] != nil {
            Task { @MainActor in stress() }
            return
        }
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

            // MARK: The profile picture beside the name
            func info(_ images: String) -> Data { Data(#"{"user": {"name": "someone", "playcount": "10", "image": \#(images)}}"#.utf8) }
            let sized = ##"[{"#text": "https://img.example/s.png", "size": "small"}, {"#text": "https://img.example/xl.png", "size": "extralarge"}, {"#text": "https://img.example/l.png", "size": "large"}]"##
            check("the biggest listed picture is the one used", LastfmAPIClient.avatarURL(inUserInfo: info(sized))?.absoluteString == "https://img.example/xl.png")
            check("with only smaller sizes the biggest of those is used", LastfmAPIClient.avatarURL(inUserInfo: info(##"[{"#text": "https://img.example/m.png", "size": "medium"}, {"#text": "https://img.example/s.png", "size": "small"}]"##))?.absoluteString == "https://img.example/m.png")
            check("an account with no picture (empty addresses) has none", LastfmAPIClient.avatarURL(inUserInfo: info(##"[{"#text": "", "size": "large"}, {"#text": "", "size": "extralarge"}]"##)) == nil)
            check("a missing or oddly shaped image list gives none, not an error", LastfmAPIClient.avatarURL(inUserInfo: info("[]")) == nil && LastfmAPIClient.avatarURL(inUserInfo: info(#""none""#)) == nil && LastfmAPIClient.avatarURL(inUserInfo: Data(#"{"user": {"playcount": "3"}}"#.utf8)) == nil)
            check("an address that isn't https is refused", LastfmAPIClient.avatarURL(inUserInfo: info(##"[{"#text": "http://img.example/xl.png", "size": "extralarge"}]"##)) == nil)

            let avatarBase = FileManager.default.temporaryDirectory.appending(path: "scroblytics-avatar-check-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: avatarBase) }
            func pictureData(_ color: NSColor) -> Data {
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                color.setFill(); NSRect(x: 0, y: 0, width: 64, height: 64).fill()
                NSGraphicsContext.restoreGraphicsState()
                return rep.representation(using: .png, properties: [:])!
            }
            let redPicture = pictureData(.red)
            final class Counter: @unchecked Sendable { var fetches = 0; var downloads = 0 }
            let counter = Counter()
            let address = URL(string: "https://img.example/xl.png")!
            func loadAvatar(at now: Date, address: URL? = address, bytes: Data? = redPicture, failing: Bool = false) async -> Data? {
                await ShareAvatar.load(username: "SomeOne", base: avatarBase, now: now, fetchURL: { counter.fetches += 1; if failing { throw URLError(.notConnectedToInternet) }; return address }, download: { _ in counter.downloads += 1; if failing { throw URLError(.notConnectedToInternet) }; return bytes ?? Data() })
            }
            let day0 = Date()
            let first = await loadAvatar(at: day0)
            check("the first load asks Last.fm and keeps the picture", first == redPicture && counter.fetches == 1 && counter.downloads == 1)
            check("the saved file name does not contain the account name", !ShareAvatar.fileURL(username: "SomeOne", base: avatarBase).lastPathComponent.lowercased().contains("someone") && ShareAvatar.fileURL(username: "SomeOne", base: avatarBase) == ShareAvatar.fileURL(username: "someone", base: avatarBase))
            let withinWeek = await loadAvatar(at: day0.addingTimeInterval(3 * 86_400))
            check("within a week the saved picture is used with no request", withinWeek == redPicture && counter.fetches == 1 && counter.downloads == 1)
            let blue = pictureData(.blue)
            let week = await loadAvatar(at: day0.addingTimeInterval(8 * 86_400), bytes: blue)
            check("after a week it is refreshed", week == blue && counter.fetches == 2)
            let offlineLater = await loadAvatar(at: day0.addingTimeInterval(20 * 86_400), failing: true)
            check("when the refresh fails (offline) the older saved picture is still used", offlineLater == blue)
            let notAPicture = await loadAvatar(at: day0.addingTimeInterval(40 * 86_400), bytes: Data("<html>not a picture</html>".utf8))
            check("an answer that isn't a picture is not saved over the good one", notAPicture == blue && ShareAvatar.cached(username: "someone", base: avatarBase, now: day0)?.data == blue)
            let noPicture = await loadAvatar(at: day0.addingTimeInterval(60 * 86_400), address: nil)
            check("an account with no picture keeps the saved one rather than blanking it", noPicture == blue)
            let strangerBase = avatarBase.appending(path: "other")
            let stranger = await ShareAvatar.load(username: "nobody", base: strangerBase, fetchURL: { throw URLError(.notConnectedToInternet) }, download: { _ in Data() })
            check("with nothing saved and no network there is no picture", stranger == nil && ShareAvatar.cached(username: "nobody", base: strangerBase) == nil)

            let avatarSuite = UserDefaults(suiteName: "share-avatar-\(UUID().uuidString)")!
            check("the picture switch starts off", !ShareSettings.showsAvatar(defaults: avatarSuite))
            let nameRow = SyncState(username: "SomeOne")
            let avatarContainer = try! ModelContainer(for: Schema([SyncState.self]), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            avatarContainer.mainContext.insert(nameRow)
            try? avatarContainer.mainContext.save()
            @MainActor func identityWith(name: Bool, picture: Bool) -> ShareIdentity {
                avatarSuite.set(name, forKey: ShareSettings.showsNameKey); avatarSuite.set(picture, forKey: ShareSettings.showsAvatarKey)
                return ShareSettings.identity(context: avatarContainer.mainContext, defaults: avatarSuite, base: avatarBase)
            }
            check("name and picture on: the identity carries the saved picture", identityWith(name: true, picture: true).avatar == blue)
            check("the picture alone never shows (it goes with the name)", identityWith(name: false, picture: true).avatar == nil && identityWith(name: false, picture: true).name == nil)
            check("name on, picture off: just the name", identityWith(name: true, picture: false).avatar == nil && identityWith(name: true, picture: false).name == "SomeOne")

            var avatarOptions = ShareOptions(); avatarOptions.size = .square
            let withoutPicture = ShareRenderer.png(card: card, options: avatarOptions, identity: ShareIdentity(name: "someone", showsFooter: false), images: [:])
            let withPicture = ShareRenderer.png(card: card, options: avatarOptions, identity: ShareIdentity(name: "someone", showsFooter: false, avatar: redPicture), images: [:])
            check("a card with the picture differs from one with just the name, at the same size",
                  withoutPicture != nil && withPicture != nil && withoutPicture != withPicture
                    && NSBitmapImageRep(data: withPicture!)?.pixelsWide == NSBitmapImageRep(data: withoutPicture!)?.pixelsWide
                    && NSBitmapImageRep(data: withPicture!)?.pixelsHigh == NSBitmapImageRep(data: withoutPicture!)?.pixelsHigh)
            let pictureOnly = ShareRenderer.png(card: card, options: avatarOptions, identity: ShareIdentity(name: nil, showsFooter: false, avatar: redPicture), images: [:])
            check("a picture without a name draws nothing", pictureOnly == ShareRenderer.png(card: card, options: avatarOptions, identity: .anonymous, images: [:]))
            check("the picture does not enter the text forms", ShareText.plain(card, options: options, identity: ShareIdentity(name: "someone", showsFooter: false, avatar: redPicture)) == ShareText.plain(card, options: options, identity: ShareIdentity(name: "someone", showsFooter: false)))
            check("the picture is a circle: its corners are the card's, its middle is the picture",
                  { () -> Bool in
                      guard let data = withPicture, let rep = NSBitmapImageRep(data: data) else { return false }
                      // The footer's picture sits at the bottom left; find red pixels there and none in the far corner.
                      var red = 0
                      for y in stride(from: rep.pixelsHigh - 160, to: rep.pixelsHigh, by: 2) { for x in stride(from: 0, to: 400, by: 2) {
                          if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.redComponent > 0.8, c.greenComponent < 0.25, c.blueComponent < 0.25 { red += 1 }
                      } }
                      return red > 20
                  }())

            // A square card can't hold twenty rows readably: it shows at most fifteen, however many were asked for
            var twenty = ShareOptions(); twenty.rowCount = 20
            var squareTwenty = twenty; squareTwenty.size = .square
            var portraitTwenty = twenty; portraitTwenty.size = .portrait
            let manyRows = ShareCard(title: "T", period: "P", measure: "", rows: (1...20).map { ShareRow(rank: $0, title: "Track \($0)", subtitle: "Artist · Album", value: "1", change: .none, imageURL: nil) }, valueLabel: "Plays", hasMovement: false, kindID: "x")
            check("a square list shows at most 15 rows, a portrait or wide one 20", manyRows.visibleRows(for: squareTwenty).count == 15 && manyRows.visibleRows(for: portraitTwenty).count == 20 && ShareSize.wide.maxRows == 20)
            for size in ShareSize.allCases {
                var o = twenty; o.size = size
                let png = ShareRenderer.png(card: manyRows, options: o, identity: .anonymous, images: [:])
                check("twenty long rows, \(size.label): render", png != nil)
            }

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

            // A result with tens of thousands of rows (a library's every track) makes a card from the first rows only, at once
            do {
                let plays = QueryFieldRef("plays")
                if let column = try? QueryFieldRegistry.standard.resolve(plays, target: .track) {
                    let bigRows = (0..<60_000).map { i in
                        QueryDisplayRow(row: QueryRow(entity: QueryEntity(id: QueryEntityID(target: .track, artist: "Artist \(i % 700)", name: "Track \(i)")), cells: [column.cacheKey: .value(.number(Double(60_000 - i)))]), imageURL: nil, subtitle: "Artist \(i % 700)")
                    }
                    let started = Date()
                    let bigCard = ShareCards.queryResult(title: "everything", target: .track, measure: "", rows: bigRows, columns: [column], sortedColumn: 0)
                    let took = Date().timeIntervalSince(started)
                    check("a 60,000-row result makes a card of at most 20 rows, quickly (\(String(format: "%.3f", took)) s)", bigCard.rows.count == 20 && bigCard.rows[0].title == "Track 0" && bigCard.rows[19].rank == 20 && took < 0.5)
                } else {
                    check("the plays field resolves for tracks", false)
                }
            }

            // A query broken down by year: each row says its year, and the rows are not numbered 1…N across the years
            if let column = try? QueryFieldRegistry.standard.resolve(QueryFieldRef("plays"), target: .artist) {
                func yearRow(_ name: String, _ year: Int, _ plays: Double) -> QueryDisplayRow {
                    QueryDisplayRow(row: QueryRow(entity: QueryEntity(id: QueryEntityID(target: .artist, artist: name, name: name)), cells: [column.cacheKey: .value(.number(plays))], period: year), imageURL: nil, subtitle: nil)
                }
                let yearly = ShareCards.queryResult(title: "my top artists of each year", target: .artist, measure: "", rows: [yearRow("Artist A", 2019, 5), yearRow("Artist B", 2019, 3), yearRow("Artist A", 2020, 9)], columns: [column], sortedColumn: 0)
                check("rows of a yearly query say their year and are not numbered across years", yearly.rows.map(\.subtitle) == ["2019", "2019", "2020"] && !yearly.numbered, "\(yearly.rows.map(\.subtitle))")
                check("…and the text keeps the year beside each name", ShareText.markdownTable(yearly, options: ShareOptions()).contains("| Artist A | 2020 | 9 |") && !ShareText.markdownTable(yearly, options: ShareOptions()).contains("| # |"), ShareText.markdownTable(yearly, options: ShareOptions()))
                check("…and it renders", ShareRenderer.png(card: yearly, options: ShareOptions(), identity: .anonymous, images: [:]) != nil)
            }

            // MARK: A Rabbit Hole path
            func rhTrack(_ artist: String, _ name: String, plays: Int, why: String?) -> RabbitHoleTrack {
                RabbitHoleTrack(artist: artist, track: name, album: "Album X", imageURL: nil, playCount: plays, lastPlayed: Date(timeIntervalSince1970: 1_700_000_000 + Double(plays) * 86_400), matchScore: 80, source: "lastfm", reasons: why.map { [RabbitHoleReason(kind: .similar, text: $0)] })
            }
            let rhTracks = [rhTrack("Artist A", "Start *Here*", plays: 40, why: nil), rhTrack("Artist B", "Second", plays: 12, why: "Last.fm: similar to Start"), rhTrack("Artist C", "Third", plays: 3, why: "you often play it after Second (6 times)"), rhTrack("Artist D", "Fourth", plays: 25, why: "shares tags: dream pop")]
            var rhNodes: [RabbitHoleNode] = []
            for (index, track) in rhTracks.enumerated() {
                rhNodes.append(RabbitHoleNode(id: UUID(), track: track, parentID: index == 0 ? nil : rhNodes[index - 1].id, candidates: nil, childIDs: []))
            }
            let rhCard = ShareCards.rabbitHole(path: rhNodes)
            check("a path card lists the tracks in order from the start, numbered", rhCard.rows.map(\.title) == ["Start *Here*", "Second", "Third", "Fourth"] && rhCard.rows.map(\.rank) == [1, 2, 3, 4] && rhCard.numbered && rhCard.period.isEmpty && rhCard.measure.isEmpty && rhCard.kindID == "rabbitHole" && rhCard.compactTitles)
            check("each row has its artist, its plays and last play, and why it was chosen", rhCard.rows[1].subtitle == "Artist B" && rhCard.rows[1].values == ["12", Date(timeIntervalSince1970: 1_700_000_000 + 12 * 86_400).formatted(date: .abbreviated, time: .omitted), "80%"] && rhCard.rows[1].note == "Last.fm: similar to Start" && rhCard.rows[0].note == nil && rhCard.valueColumns == ["Plays", "Last played", "Match score"] && rhCard.rows[1].values[2] == "80%" && rhCard.rows[0].values[2] == "—" && rhCard.hasNotes)
            var rhOptions = ShareOptions()
            check("with notes on the line under a track carries the artist and why; the start has only its artist", rhCard.detailLine(rhCard.rows[2], options: rhOptions) == "Artist C — you often play it after Second (6 times)" && rhCard.detailLine(rhCard.rows[0], options: rhOptions) == "Artist A")
            rhOptions.showNotes = false
            check("with notes off, only the artist", rhCard.detailLine(rhCard.rows[2], options: rhOptions) == "Artist C")
            let rhTable = ShareText.markdownTable(rhCard, options: ShareOptions())
            check("the table has the artist, both columns and a Why column, escaped", rhTable.contains("| # | Name | Artist | Plays | Last played | Match score | Why |") && rhTable.contains("| 1 | Start \\*Here\\* | Artist A | 40 |") && rhTable.contains("| 3 | Third | Artist C | 3 |") && rhTable.contains("| 80% | Last.fm: similar to Start |") && rhTable.contains("you often play it after Second (6 times) |"), rhTable)
            check("…and no Why column when notes are off", !ShareText.markdownTable(rhCard, options: rhOptions).contains("Why"))
            check("the plain list says why after the artist", ShareText.plain(rhCard, options: ShareOptions()).contains("2. Second — Artist B — Last.fm: similar to Start (Plays: 12, Last played:"), ShareText.plain(rhCard, options: ShareOptions()))
            let noNotesData = Data(#"{"size":"square","rowCount":10,"showValues":true,"showMovement":true,"showDate":true}"#.utf8)
            check("options saved before the notes switch existed show notes", (try? JSONDecoder().decode(ShareOptions.self, from: noNotesData))?.showNotes == true)
            for size in ShareSize.allCases {
                var o = ShareOptions(); o.size = size
                let png = ShareRenderer.png(card: rhCard, options: o, identity: .anonymous, images: [:])
                let image = png.flatMap { NSBitmapImageRep(data: $0) }
                check("a path card, \(size.label): a PNG at 2x, not blank", image?.pixelsWide == Int(size.points.width) * 2 && (image.map { luminanceSpread($0) > 0.05 } ?? false))
            }
            var rhTitle = ShareOptions(); rhTitle.customTitle = "  My Friday detour  "
            check("a title the person types replaces the card's, trimmed, in the image and every text form; blank keeps the card's", rhCard.displayTitle(for: rhTitle) == "My Friday detour" && rhCard.displayTitle(for: ShareOptions()) == "Down the rabbit hole" && ShareText.markdownTable(rhCard, options: rhTitle).hasPrefix("**My Friday detour** · ") && ShareText.plain(rhCard, options: rhTitle).hasPrefix("My Friday detour, ") && ShareText.markdownList(rhCard, options: rhTitle).hasPrefix("**My Friday detour**") && ShareRenderer.png(card: rhCard, options: rhTitle, identity: .anonymous, images: [:]) != ShareRenderer.png(card: rhCard, options: ShareOptions(), identity: .anonymous, images: [:]))
            var rhBlank = ShareOptions(); rhBlank.customTitle = "   "
            let rhProfile = ShareCard(title: "Page", period: "", measure: "", rows: [], valueLabel: "", hasMovement: false, kindID: "x", profile: ShareProfile(kind: "", subtitle: "", heroImageURL: nil, stats: [], chips: [], trend: []))
            let blankIsNone = rhCard.displayTitle(for: rhBlank) == "Down the rabbit hole"
            let profileTakes = rhProfile.displayTitle(for: rhTitle) == "My Friday detour" && rhProfile.displayTitle(for: rhBlank) == "Page"
            check("a title of only spaces counts as none, and every kind of card takes a typed one", blankIsNone && profileTakes)
            check("the typed title is not remembered with the options", { let data = try? JSONEncoder().encode(rhTitle); return data.flatMap { try? JSONDecoder().decode(ShareOptions.self, from: $0) }?.customTitle == "" }())
            var rhMatch = ShareOptions(); rhMatch.valueColumn = 2
            check("the match score can be the column shown", rhCard.valueText(rhCard.rows[1], options: rhMatch) == "80%" && rhCard.valueName(for: rhMatch) == "Match score")
            var rhNone = ShareOptions(); rhNone.showValues = false
            check("None leaves the numbers, the column label and the table's columns out", ShareRenderer.png(card: rhCard, options: rhNone, identity: .anonymous, images: [:]) != ShareRenderer.png(card: rhCard, options: ShareOptions(), identity: .anonymous, images: [:]) && !ShareText.markdownTable(rhCard, options: rhNone).contains("Plays") && !ShareText.markdownTable(rhCard, options: rhNone).contains("Match score") && ShareText.markdownTable(rhCard, options: rhNone).contains("| Why |"))
            // The same path as a tree: what was offered at each step and not taken hangs beside the step
            let rhOffer1 = rhTrack("Artist X", "Offer One", plays: 1, why: nil), rhOffer2 = rhTrack("Artist Y", "Offer Two", plays: 2, why: nil), rhOffer3 = rhTrack("Artist Z", "Offer Three", plays: 3, why: nil)
            var rhTreeNodes = rhNodes
            rhTreeNodes[0].candidates = [rhOffer1, rhTracks[1], rhOffer2]
            rhTreeNodes[1].candidates = [rhTracks[2], rhOffer3]
            let rhExplored = RabbitHoleNode(id: UUID(), track: rhOffer2, parentID: rhTreeNodes[1].id, candidates: nil, childIDs: [])
            rhTreeNodes[1].childIDs = [rhTreeNodes[2].id, rhExplored.id]
            var rhTreeDict = Dictionary(uniqueKeysWithValues: rhTreeNodes.map { ($0.id, $0) })
            rhTreeDict[rhExplored.id] = rhExplored
            let treeCard = ShareCards.rabbitHole(path: rhTreeNodes, tree: RabbitHoleTree(rootID: rhTreeNodes[0].id, nodes: rhTreeDict, currentID: rhTreeNodes[3].id))
            let treeSteps = treeCard.tree?.steps ?? []
            check("the tree has a step per track, in order", treeSteps.map(\.chosen.title) == ["Start *Here*", "Second", "Third", "Fourth"])
            check("the start has nothing beside it; a later step has what was offered before it and not taken", treeSteps[0].others.isEmpty && treeSteps[1].others.map(\.title) == ["Offer One", "Offer Two"], "\(treeSteps.map { $0.others.map(\.title) })")
            check("branches explored from the step before count, the taken one never does, and a track isn't listed twice", treeSteps[2].others.map(\.title) == ["Offer Three", "Offer Two"] && treeSteps[3].others.isEmpty, "\(treeSteps.map { $0.others.map(\.title) })")
            check("a path with no recorded offers still makes a tree, of one track at each step", ShareCards.rabbitHole(path: rhNodes).tree?.steps.allSatisfy { $0.others.isEmpty } == true)
            var treeOptions = ShareOptions(); treeOptions.layout = .tree
            check("the tree layout draws a tree only when asked and when there is one", treeCard.drawsTree(for: treeOptions) && !treeCard.drawsTree(for: ShareOptions()) && !ShareCards.milestones(category: "Albums", tierLabel: "", rows: []).drawsTree(for: treeOptions))
            check("the tree's pictures are the steps' and their offers'", treeCard.pictureURLs(for: treeOptions).count == 4 + 4 && treeCard.pictureURLs(for: ShareOptions()).count == 4)
            for size in ShareSize.allCases {
                var o = treeOptions; o.size = size
                let png = ShareRenderer.png(card: treeCard, options: o, identity: .anonymous, images: [:])
                let image = png.flatMap { NSBitmapImageRep(data: $0) }
                check("a tree card, \(size.label): a PNG at 2x, not blank", image?.pixelsWide == Int(size.points.width) * 2 && image?.pixelsHigh == Int(size.points.height) * 2 && (image.map { luminanceSpread($0) > 0.05 } ?? false))
                var list = o; list.layout = .list
                check("a tree card, \(size.label): differs from the list", png != ShareRenderer.png(card: treeCard, options: list, identity: .anonymous, images: [:]))
            }
            var treeTitle = treeOptions; treeTitle.customTitle = "Friday detour"
            check("a typed title shows on the tree as well", ShareRenderer.png(card: treeCard, options: treeTitle, identity: .anonymous, images: [:]) != ShareRenderer.png(card: treeCard, options: treeOptions, identity: .anonymous, images: [:]))
            var treeFew = treeOptions; treeFew.rowCount = 2
            check("the Rows choice limits the tree's steps", ShareRenderer.png(card: treeCard, options: treeFew, identity: .anonymous, images: [:]) != ShareRenderer.png(card: treeCard, options: treeOptions, identity: .anonymous, images: [:]))
            check("the layout is remembered with the options, old saved options read as list", { let data = try? JSONEncoder().encode(treeOptions); return data.flatMap { try? JSONDecoder().decode(ShareOptions.self, from: $0) }?.layout == .tree }() && (try? JSONDecoder().decode(ShareOptions.self, from: Data(#"{"size":"square"}"#.utf8)))?.layout == .list)
            var rhOff = ShareOptions(); rhOff.showNotes = false
            check("turning the notes off changes the image", ShareRenderer.png(card: rhCard, options: rhOff, identity: .anonymous, images: [:]) != ShareRenderer.png(card: rhCard, options: ShareOptions(), identity: .anonymous, images: [:]))

            // MARK: Query results
            let qBase = Date(timeIntervalSince1970: 1_700_000_000)
            let qLibrary: [(artist: String, album: String, tracks: [(String, Int)])] = [
                ("Artist A", "Album One", [("one x", 7), ("one y", 5)]), ("Artist A", "Album Two", [("two x", 4)]),
                ("Artist B", "Album Three", [("three x", 9), ("three y", 6), ("three z", 3)]), ("Artist C", "Album *Four* | 4", [("four x", 1)]),
            ]
            var qPlays: [ScrobbleSnapshot] = []
            var qLast: [String: Date] = [:]
            var qTime = qBase
            for album in qLibrary {
                for (track, count) in album.tracks {
                    for _ in 0..<count {
                        qPlays.append(ScrobbleSnapshot(artistName: album.artist, albumName: album.album, trackName: track, imageURL: nil, playedAt: qTime))
                        qLast[album.album] = qTime
                        qTime = qTime.addingTimeInterval(3600)
                    }
                }
            }
            var qSpec = QuerySpec(target: .album)
            qSpec.sorts = [QuerySort(key: .field(QueryFieldRef("plays")), direction: .descending)]
            qSpec.columns = [QueryFieldRef("lastPlayed"), QueryFieldRef("plays")]
            qSpec.limit = 3
            let qResult: QueryResult? = (try? qSpec.validate(against: .standard)).map { validated in
                QueryEngine.evaluate(validated, run: QueryRun(target: .album, asOf: qTime, scrobbles: qPlays, allTimeScrobbles: qPlays, snapshots: QuerySnapshots()))
            }
            check("the made-up query runs", qResult != nil && qResult?.rows.count == 3, "\(qResult?.rows.count ?? -1)")
            if let qResult {
                let qRows = QueryDisplayRow.make(from: qResult, imageLookup: [:])
                let sortedIndex = ShareCards.sortedColumnIndex(columns: qResult.columns, sorts: qSpec.sorts, target: .album, registry: .standard)
                check("the column the query sorts on is the default value", sortedIndex == 1 && qResult.columns[1].field.id == "plays")
                let qCard = ShareCards.queryResult(title: "my most played albums", target: .album, measure: "3 of 4 match · Sorted by Plays ↓", rows: qRows, columns: qResult.columns, sortedColumn: sortedIndex)
                // Independent expectation: plays per album, counted straight from the made-up plays.
                let expected = Dictionary(grouping: qPlays, by: \.albumName).mapValues(\.count).sorted { $0.value > $1.value }.prefix(3)
                check("the rows are the top three by an independent count, in order, ranked from 1", qCard.rows.map(\.title) == expected.map(\.key) && qCard.rows.map(\.rank) == [1, 2, 3], "\(qCard.rows.map(\.title))")
                check("the image's value is the plays, each column's value is kept", qCard.rows.map(\.value) == expected.map { $0.value.formatted() } && qCard.rows.allSatisfy { $0.values.count == 2 } && qCard.valueColumns == qResult.columns.map(\.title), "\(qCard.rows.map(\.value))")
                check("a row's other column is written as the table writes it", qCard.rows[0].values[0] == QueryCellText.date(qLast[qCard.rows[0].title]!, fieldID: "lastPlayed"))
                check("a query card says what it is, and has a subtitle for the artist", qCard.title == "my most played albums" && qCard.period == "Albums" && qCard.kindID == "query.album" && qCard.rows[0].subtitle == "Artist B" && qCard.numbered)
                var qOptions = ShareOptions()
                check("by default the image shows the sorted column, by choice another", qCard.valueText(qCard.rows[0], options: qOptions) == qCard.rows[0].values[1] && { qOptions.valueColumn = 0; return qCard.valueText(qCard.rows[0], options: qOptions) == qCard.rows[0].values[0] && qCard.valueName(for: qOptions) == qCard.valueColumns[0] }())
                qOptions.valueColumn = 99
                check("a column that doesn't exist falls back to the last one", qCard.valueColumnIndex(for: qOptions) == 1)
                qOptions.valueColumn = 0
                check("the chosen column is not remembered with the options", { let data = try? JSONEncoder().encode(qOptions); return data.flatMap { try? JSONDecoder().decode(ShareOptions.self, from: $0) }?.valueColumn == nil }())
                var qOther = ShareOptions(); qOther.valueColumn = 0
                var qSorted = ShareOptions(); qSorted.size = .square; qOther.size = .square
                check("choosing the other column changes the image", ShareRenderer.png(card: qCard, options: qOther, identity: .anonymous, images: [:]) != ShareRenderer.png(card: qCard, options: qSorted, identity: .anonymous, images: [:]))
                let qTable = ShareText.markdownTable(qCard, options: ShareOptions())
                check("the table carries every column", qTable.contains("| # | Name | Artist | \(qCard.valueColumns[0]) | \(qCard.valueColumns[1]) |") && qTable.contains("| 1 | Album Three | Artist B |") && qTable.contains("| \(expected.first!.value.formatted()) |"), qTable)
                check("the list and plain forms name each column", ShareText.markdownList(qCard, options: ShareOptions()).contains("\(qCard.valueColumns[1]): \(expected.first!.value.formatted())") && ShareText.plain(qCard, options: ShareOptions()).contains("1. Album Three — Artist B (\(qCard.valueColumns[0]): "))
                check("the title is the first line of every text form", ShareText.markdownTable(qCard, options: ShareOptions()).hasPrefix("**my most played albums** · Albums") && ShareText.plain(qCard, options: ShareOptions()).hasPrefix("my most played albums — Albums"))
                var qOdd = qCard
                qOdd.rows[0].title = "Album *Four* | 4"
                check("names are escaped in a query table", ShareText.markdownTable(qOdd, options: ShareOptions()).contains("Album \\*Four\\* \\| 4"))
                for size in ShareSize.allCases {
                    var o = ShareOptions(); o.size = size
                    let png = ShareRenderer.png(card: qCard, options: o, identity: .anonymous, images: [:])
                    let image = png.flatMap { NSBitmapImageRep(data: $0) }
                    check("a query card (a sentence for a title), \(size.label): a PNG at 2x, not blank", image?.pixelsWide == Int(size.points.width) * 2 && (image.map { luminanceSpread($0) > 0.05 } ?? false))
                }
                var qNone = qCard
                qNone.valueColumns = []
                qNone.rows = qNone.rows.map { var r = $0; r.values = []; return r }
                check("a result with no columns still renders and shows no value", ShareRenderer.png(card: qNone, options: ShareOptions(), identity: .anonymous, images: [:]) != nil && qNone.valueText(qNone.rows[0], options: ShareOptions()) == qNone.rows[0].value)
                // The question describes the results only while the query is unchanged
                let asked = AskedQuestion(text: "my most played albums", spec: qSpec)
                var edited = qSpec; edited.limit = 5
                var reordered = qSpec; reordered.columns = [QueryFieldRef("plays"), QueryFieldRef("lastPlayed")]
                var filtered = qSpec; filtered.target = .track
                check("the question holds while the query is the same, or only its columns are reordered", asked.text(whenQueryIs: qSpec) == "my most played albums" && asked.text(whenQueryIs: reordered) == "my most played albums")
                check("…and is dropped once the limit or the target changes", asked.text(whenQueryIs: edited) == nil && asked.text(whenQueryIs: filtered) == nil)
                var withSort = qSpec; withSort.sorts = [QuerySort(key: .field(QueryFieldRef("lastPlayed")), direction: .descending)]
                check("…or a sort", asked.text(whenQueryIs: withSort) == nil)
            }
            check("an Ask request carries the question, and defaults to none", AskQueryRequest(spec: QuerySpec(target: .album), action: .run, question: "q").question == "q" && AskQueryRequest(spec: QuerySpec(target: .album), action: .run).question == nil)

            // MARK: A chart (a picture of what is on screen, in a card)
            func chartPicture(_ color: NSColor) -> NSImage {
                NSImage(size: NSSize(width: 900, height: 300), flipped: false) { rect in color.setFill(); rect.fill(); NSColor.white.setFill(); NSRect(x: 60, y: 40, width: 700, height: 6).fill(); return true }
            }
            let chartA = ShareSnapshot(image: chartPicture(.systemBlue)), chartB = ShareSnapshot(image: chartPicture(.systemOrange))
            let chartCard = ShareCard(title: "Volume over time", period: "Last 6 months", measure: "Compared with the 6 months before", rows: [], valueLabel: "", hasMovement: false, kindID: "trends.volume-over-time", snapshot: chartA)
            check("a chart card is not a list, has no pictures to load and starts wide", !chartCard.isList && chartCard.pictureURLs(for: ShareOptions()).isEmpty && chartCard.defaultOptions.size == .wide && card.defaultOptions.size == .square)
            check("two snapshots are two different pictures", chartA == chartA && chartA != chartB)
            check("a card remembers nothing until chosen, then the choice", ShareSettings.options(for: chartCard.kindID, fallback: chartCard.defaultOptions, defaults: suite).size == .wide && { var chosen = chartCard.defaultOptions; chosen.size = .portrait; ShareSettings.save(chosen, for: chartCard.kindID, defaults: suite); return ShareSettings.options(for: chartCard.kindID, fallback: chartCard.defaultOptions, defaults: suite).size == .portrait }())
            for size in ShareSize.allCases {
                var o = ShareOptions(); o.size = size
                let png = ShareRenderer.png(card: chartCard, options: o, identity: .anonymous, images: [:])
                let image = png.flatMap { NSBitmapImageRep(data: $0) }
                check("a chart card, \(size.label): a PNG at 2x, not blank", image?.pixelsWide == Int(size.points.width) * 2 && image?.pixelsHigh == Int(size.points.height) * 2 && (image.map { luminanceSpread($0) > 0.05 } ?? false))
                var other = chartCard; other.snapshot = chartB
                check("a chart card, \(size.label): shows its picture, and the footer", png != ShareRenderer.png(card: other, options: o, identity: .anonymous, images: [:]) && png != ShareRenderer.png(card: chartCard, options: o, identity: ShareIdentity(name: "someone", showsFooter: true), images: [:]))
            }
            var fitOptions = chartCard.defaultOptions
            check("a chart card starts shaped to its chart; other cards never are", fitOptions.fitToChart && chartCard.fitsChart(for: fitOptions) && !card.fitsChart(for: card.defaultOptions) && !chartCard.fitsChart(for: ShareOptions()))
            let fitPng = ShareRenderer.png(card: chartCard, options: fitOptions, identity: .anonymous, images: [:]).flatMap { NSBitmapImageRep(data: $0) }
            check("a fitted chart card is as wide as the picture plus margins (1,028 for this 900 pt picture), twice that in pixels", fitPng?.pixelsWide == 2056 && chartCard.fittedWidth == 1028, "\(fitPng?.pixelsWide ?? 0) × \(fitPng?.pixelsHigh ?? 0)")
            check("it has no empty band: much shorter than the square card, taller than its picture", (fitPng?.pixelsHigh ?? 0) > 2 * 300 && (fitPng?.pixelsHigh ?? 9_999) < 1800, "\(fitPng?.pixelsHigh ?? 0)")
            check("a fitted card is not blank and shows its picture", fitPng.map { luminanceSpread($0) > 0.05 } == true && ShareRenderer.png(card: chartCard, options: fitOptions, identity: .anonymous, images: [:]) != { var other = chartCard; other.snapshot = chartB; return ShareRenderer.png(card: other, options: fitOptions, identity: .anonymous, images: [:]) }())
            fitOptions.fitToChart = false
            check("with the fit off the chosen size applies again", ShareRenderer.png(card: chartCard, options: fitOptions, identity: .anonymous, images: [:]).flatMap { NSBitmapImageRep(data: $0) }?.pixelsWide == Int(fitOptions.size.points.width) * 2)
            check("options saved before the switch existed fit the chart", (try? JSONDecoder().decode(ShareOptions.self, from: Data("{\"size\":\"portrait\"}".utf8)))?.fitToChart == true)
            var withSummary = chartCard
            withSummary.chartSummary = ShareChartSummary(headline: "12,345 scrobbles", change: "+8% vs Jan 1, 2025 – Oct 17, 2025", isUp: true)
            var withDown = withSummary
            withDown.chartSummary?.isUp = false
            var withDetail = chartCard
            withDetail.chartSummary = ShareChartSummary(headline: "Busiest: Fri 9 PM", detail: "412 scrobbles")
            check("the chart's headline numbers are printed above its picture; down is drawn differently from up; a plain detail line works", ShareRenderer.png(card: withSummary, options: ShareOptions(), identity: .anonymous, images: [:]) != ShareRenderer.png(card: chartCard, options: ShareOptions(), identity: .anonymous, images: [:]) && ShareRenderer.png(card: withSummary, options: ShareOptions(), identity: .anonymous, images: [:]) != ShareRenderer.png(card: withDown, options: ShareOptions(), identity: .anonymous, images: [:]) && ShareRenderer.png(card: withDetail, options: ShareOptions(), identity: .anonymous, images: [:]) != ShareRenderer.png(card: chartCard, options: ShareOptions(), identity: .anonymous, images: [:]))
            var dateOff = ShareOptions(); dateOff.showDate = false
            check("the date can be left off a chart card", ShareRenderer.png(card: chartCard, options: dateOff, identity: .anonymous, images: [:]) != ShareRenderer.png(card: chartCard, options: ShareOptions(), identity: .anonymous, images: [:]))

            // MARK: The Overview recap
            func ovTop(_ name: String, _ artist: String?, plays: Int, seconds: Int? = nil) -> OverviewTopEntry {
                OverviewTopEntry(name: name, artist: artist, album: nil, playcount: plays, imageURL: "file:///art/\(name).jpg", loved: false, timeListenedSeconds: seconds)
            }
            let ovTotals = OverviewTotals(
                scrobbles: 1200, artists: 80, albums: 150, tracks: 700, trackKeys: [], perDay: 3.3333, newArtists: 12,
                compare: OverviewCompare(scrobbles: 1000, artists: 70, albums: 140, tracks: 650),
                topArtist: ovTop("Artist A", nil, plays: 90, seconds: 36_000), topAlbum: ovTop("Album A", "Artist A", plays: 40, seconds: 14_000), topTrack: ovTop("Song A", "Artist B", plays: 1, seconds: 200)
            )
            func ovInput(metric: TopChartsMetric = .scrobbles, seconds: Int? = nil, allTime: Bool = false, compareLabel: String? = "30 days ago", totals: OverviewTotals = ovTotals, streak: Int? = 5) -> ShareCards.OverviewRecapInput {
                ShareCards.OverviewRecapInput(totals: totals, metric: metric, timeListenedSeconds: seconds, periodLabel: allTime ? "All time" : "Year to date", isAllTime: allTime, compareLabel: compareLabel, firstScrobble: Date(timeIntervalSince1970: 1_600_000_000), currentStreak: streak)
            }
            let ovCard = ShareCards.overviewRecap(ovInput())!
            let ovLabels = ovCard.profile?.stats.map(\.label) ?? []
            check("the recap says its period, and its figures are the page's", ovCard.title == "Year to date" && ovCard.kindID == "overview.recap" && ovCard.profile?.kind == "Listening recap" && ovLabels.prefix(4) == ["Scrobbles", "Artists", "Albums", "Tracks"] && ovCard.profile?.stats[0].value == 1200.formatted() && ovCard.profile?.stats[1].value == "80" && ovCard.profile?.stats[3].value == "700", "\(ovLabels)")
            check("the comparison is the page's own percentage (+20% on 1000 → 1200), named for what it is against", ovLabels[4] == "Vs 30 days ago" && ovCard.profile?.stats[4].value == "+20%", "\(ovLabels)")
            check("then new artists, per day and the streak", Array(ovLabels.dropFirst(5)) == ["New artists", "Per day", "Current streak"] && ovCard.profile?.stats[6].value == "3.3" && ovCard.profile?.stats[7].value == "5 days")
            check("the three top picks, with artists and plays", ovCard.profile?.highlights.map(\.role) == ["Top Artist", "Top Album", "Top Track"] && ovCard.profile?.highlights.map(\.value) == ["90 plays", "40 plays", "1 play"] && ovCard.profile?.highlights[1].subtitle == "Artist A" && ovCard.profile?.highlights[0].subtitle == nil)
            let ovAll = ShareCards.overviewRecap(ovInput(allTime: true, compareLabel: nil))!
            check("All time has no comparison; it says since when instead", !(ovAll.profile?.stats.map(\.label) ?? []).contains { $0.hasPrefix("Vs ") } && ovAll.profile?.stats[4].label == "Scrobbling since" && ovAll.profile?.stats[4].value == Date(timeIntervalSince1970: 1_600_000_000).formatted(date: .abbreviated, time: .omitted))
            let ovAllWithCompare = ShareCards.overviewRecap(ovInput(allTime: true))!
            check("…even if a comparison happens to be set", !(ovAllWithCompare.profile?.stats.map(\.label) ?? []).contains { $0.hasPrefix("Vs ") })
            let ovNoCompare = ShareCards.overviewRecap(ovInput(compareLabel: nil))!
            check("with no comparison chosen the tile is left out, not shown empty", !(ovNoCompare.profile?.stats.map(\.label) ?? []).contains { $0.hasPrefix("Vs ") } && ovNoCompare.profile?.stats.count == 7)
            let ovShort = OverviewTotals(scrobbles: 1200, artists: 80, albums: 150, tracks: 700, trackKeys: [], perDay: 3, newArtists: 1, compare: nil, topArtist: nil, topAlbum: nil, topTrack: nil)
            check("a period too short to compare leaves it out, and no tops means no picks", !(ShareCards.overviewRecap(ovInput(totals: ovShort))!.profile?.stats.map(\.label) ?? []).contains { $0.hasPrefix("Vs ") } && ShareCards.overviewRecap(ovInput(totals: ovShort))!.profile?.highlights.isEmpty == true)
            let ovZero = OverviewTotals(scrobbles: 50, artists: 5, albums: 5, tracks: 5, trackKeys: [], perDay: 1, newArtists: 5, compare: OverviewCompare(scrobbles: 0, artists: 0, albums: 0, tracks: 0), topArtist: nil, topAlbum: nil, topTrack: nil)
            check("growth from nothing says New, as the page's badge does", ShareCards.overviewRecap(ovInput(totals: ovZero))!.profile?.stats[4].value == "New")
            let ovDown = OverviewTotals(scrobbles: 800, artists: 80, albums: 150, tracks: 700, trackKeys: [], perDay: 3, newArtists: 1, compare: OverviewCompare(scrobbles: 1000, artists: 70, albums: 140, tracks: 650), topArtist: nil, topAlbum: nil, topTrack: nil)
            check("a fall is written with its minus", ShareCards.overviewRecap(ovInput(totals: ovDown))!.profile?.stats[4].value == "-20%")
            check("by time listened the first tile and the picks are times, and there is no scrobbles comparison (the page has none)", {
                let card = ShareCards.overviewRecap(ovInput(metric: .timeListened, seconds: 7_200))!
                let labels = card.profile?.stats.map(\.label) ?? []
                return labels[0] == "Time Listened" && card.profile?.stats[0].value == DurationEngine.formatTimeListened(7_200) && !labels.contains { $0.hasPrefix("Vs ") } && card.profile?.highlights[0].value == DurationEngine.formatTimeListened(36_000)
            }())
            check("while the time is still being worked out there is no card yet", ShareCards.overviewRecap(ovInput(metric: .timeListened, seconds: nil)) == nil)
            check("no streak, no tile", !(ShareCards.overviewRecap(ovInput(streak: 0))!.profile?.stats.map(\.label) ?? []).contains("Current streak"))
            for size in ShareSize.allCases {
                var o = ShareOptions(); o.size = size
                let png = ShareRenderer.png(card: ovCard, options: o, identity: .anonymous, images: [:])
                let image = png.flatMap { NSBitmapImageRep(data: $0) }
                check("the recap, \(size.label): a PNG at 2x, not blank", image?.pixelsWide == Int(size.points.width) * 2 && image?.pixelsHigh == Int(size.points.height) * 2 && (image.map { luminanceSpread($0) > 0.05 } ?? false))
                check("the recap, \(size.label): shows only as many tiles as fit", ovCard.visibleStats(for: o).count == min(8, size.statLimit))
            }

            // MARK: Milestones and Timeline
            let reached = Date(timeIntervalSince1970: 1_700_000_000), firstPlay = Date(timeIntervalSince1970: 1_690_000_000)
            let reachedText = reached.formatted(date: .abbreviated, time: .omitted)
            let milestoneCard = ShareCards.milestone(kind: "Album", name: "Album A", artist: "Artist A", imageURL: "file:///art/m.jpg", milestone: 1000, achievedAt: reached, firstAt: firstPlay)
            check("a milestone card says what was reached, when, and how long it took", milestoneCard.profile?.stats.map(\.label) == ["Reached", "Time to get there", "First scrobble"] && milestoneCard.profile?.headline == "\(1000.formatted()) plays" && milestoneCard.profile?.stats[0].value == reachedText && milestoneCard.profile?.stats[1].value == MilestoneFormatting.formatElapsedDays(reached.timeIntervalSince(firstPlay) / 86400) && milestoneCard.profile?.kind == "Album milestone" && milestoneCard.profile?.subtitle == "Artist A" && milestoneCard.kindID == "milestone.album")
            check("the milestone's text says what was reached", ShareText.markdownTable(milestoneCard, options: ShareOptions()).contains("| Milestone | \(1000.formatted()) plays |") && ShareText.markdownList(milestoneCard, options: ShareOptions()).contains("- **Milestone:** \(1000.formatted()) plays") && ShareText.plain(milestoneCard, options: ShareOptions()).contains("• Milestone: \(1000.formatted()) plays"))
            check("a library-wide milestone has no artist line", ShareCards.milestone(kind: "Total", name: "1,000 scrobbles", artist: nil, imageURL: nil, milestone: 1000, achievedAt: reached, firstAt: firstPlay).profile?.subtitle == "")
            let milestoneList = ShareCards.milestones(category: "Albums", tierLabel: "1K milestones", rows: [
                ShareCards.MilestoneRow(name: "Album A", artist: "Artist A", imageURL: nil, milestone: 1000, achievedAt: reached),
                ShareCards.MilestoneRow(name: "Album *B*", artist: "Artist B", imageURL: nil, milestone: 250, achievedAt: firstPlay),
            ])
            check("the milestone list is in the order given, not numbered, and says its category and filter", milestoneList.rows.map(\.title) == ["Album A", "Album *B*"] && !milestoneList.numbered && milestoneList.period == "Albums" && milestoneList.measure == "1K milestones" && milestoneList.rows[0].value == "1K · \(reachedText)")
            check("each milestone row carries its tier and date for the coloured pill", milestoneList.rows[0].milestone == ShareMilestone(tier: 1000, date: reachedText) && milestoneList.rows[1].milestone?.tier == 250)
            let allTiers = ShareCards.milestones(category: "Albums", tierLabel: "", rows: [ShareCards.MilestoneRow(name: "A", artist: nil, imageURL: nil, milestone: 100, achievedAt: reached)])
            check("with no tier chosen the card has no filter label, in the text either", allTiers.measure.isEmpty && !ShareText.markdownTable(allTiers, options: ShareOptions()).contains("All milestones") && ShareText.markdownTable(allTiers, options: ShareOptions()).hasPrefix("**Milestones reached** · Albums · \(ShareText.dateText(allTiers))\n") && ShareText.plain(allTiers, options: ShareOptions()).hasPrefix("Milestones reached — Albums, \(ShareText.dateText(allTiers))\n"), ShareText.plain(allTiers, options: ShareOptions()))
            check("a milestone row's text isn't followed by the word milestone", ShareText.plain(allTiers, options: ShareOptions()).contains("• A (100 · \(reachedText))") && ShareText.markdownList(allTiers, options: ShareOptions()).contains("- **A** (100 · \(reachedText))"), ShareText.plain(allTiers, options: ShareOptions()))
            check("a chosen tier is lowercased only at its first letter in the text", ShareText.plain(milestoneList, options: ShareOptions()).hasPrefix("Milestones reached — Albums, 1K milestones, "), ShareText.plain(milestoneList, options: ShareOptions()))
            let totalList = ShareCards.milestones(category: "Total", tierLabel: "", rows: [ShareCards.MilestoneRow(name: "1,000 scrobbles", artist: nil, imageURL: nil, milestone: 1000, achievedAt: reached)])
            check("a list of totals offers the trophy or Last.fm picture; a list with pictures does not", totalList.iconChoice && !milestoneList.iconChoice && ShareCards.milestone(kind: "Total", name: "x", artist: nil, imageURL: nil, milestone: 100, achievedAt: reached, firstAt: firstPlay).iconChoice && !milestoneCard.iconChoice)
            var trophyOptions = ShareOptions(); trophyOptions.icon = .trophy
            var lastfmOptions = ShareOptions(); lastfmOptions.icon = .lastfm
            let trophyPNG = ShareRenderer.png(card: totalList, options: trophyOptions, identity: .anonymous, images: [:])
            let lastfmPNG = ShareRenderer.png(card: totalList, options: lastfmOptions, identity: .anonymous, images: [:])
            check("the two pictures for a total draw differently", trophyPNG != nil && trophyPNG != lastfmPNG)
            let oldOptions = try? JSONDecoder().decode(ShareOptions.self, from: Data(#"{"size":"portrait","rowCount":15,"showValues":false,"showMovement":true,"showDate":true}"#.utf8))
            check("options remembered before the picture choice existed still load, with the trophy", oldOptions?.size == .portrait && oldOptions?.rowCount == 15 && oldOptions?.showValues == false && oldOptions?.icon == .trophy)
            let listTable = ShareText.markdownTable(milestoneList, options: ShareOptions())
            check("an unnumbered list has no number column, and bullets instead of numbers", !listTable.contains("| # |") && listTable.contains("| Album A | Artist A | 1K · \(reachedText) |") && ShareText.markdownList(milestoneList, options: ShareOptions()).contains("\n- **Album A**") && ShareText.plain(milestoneList, options: ShareOptions()).contains("\n• Album A") && !ShareText.plain(milestoneList, options: ShareOptions()).contains("1. "), listTable)
            check("a ranked list is still numbered", ShareText.markdownTable(card, options: options).contains("| # | Name |") && ShareText.plain(card, options: options).contains("\n1. "))
            for size in ShareSize.allCases {
                var o = ShareOptions(); o.size = size
                let png = ShareRenderer.png(card: milestoneList, options: o, identity: .anonymous, images: [:])
                let image = png.flatMap { NSBitmapImageRep(data: $0) }
                check("the milestone list, \(size.label): renders, not blank", image?.pixelsWide == Int(size.points.width) * 2 && (image.map { luminanceSpread($0) > 0.05 } ?? false))
                let single = ShareRenderer.png(card: milestoneCard, options: o, identity: .anonymous, images: [:])
                check("a milestone card, \(size.label): renders", (single.flatMap { NSBitmapImageRep(data: $0) }?.pixelsWide ?? 0) == Int(size.points.width) * 2)
            }
            let monthStart = Date(timeIntervalSince1970: 1_759_000_000)
            func topItem(_ entity: TopChartsEntity, _ name: String, _ artist: String?, plays: Int, seconds: Int?) -> TimelineTopItem {
                TimelineTopItem(entity: entity, name: name, artist: artist, album: nil, playcount: plays, timeListenedSeconds: seconds, imageURL: "file:///art/\(name).jpg", loved: false)
            }
            let timelineMonth = TimelineMonth(
                monthStart: monthStart,
                top: TimelinePeriodTop(artist: topItem(.artist, "Artist A", nil, plays: 41, seconds: 9_000), album: topItem(.album, "Album A", "Artist A", plays: 30, seconds: 7_200), track: topItem(.track, "Song A", "Artist A", plays: 1, seconds: 200)),
                weeks: [], totals: TimelineMonthTotals(plays: 412, artists: 61, albums: 88, tracks: 230),
                milestones: [TimelineMilestone(kind: .artist, name: "Artist A", artist: nil, milestone: 1000, achievedAt: monthStart), TimelineMilestone(kind: .total, name: "", artist: nil, milestone: 25_000, achievedAt: monthStart), TimelineMilestone(kind: .artist, name: "Artist B", artist: nil, milestone: 5000, achievedAt: monthStart)]
            )
            let monthCard = ShareCards.timelineMonth(timelineMonth, metric: .scrobbles)
            check("a month card has its name, totals and the three picks", monthCard.title == monthStart.formatted(.dateTime.month(.wide).year()) && monthCard.profile?.stats.map(\.value) == ["412", "61", "88", "230"] && monthCard.profile?.highlights.map(\.role) == ["Top Artist", "Top Album", "Top Track"] && monthCard.profile?.highlights[0].value == "41 plays" && monthCard.profile?.highlights[2].value == "1 play" && monthCard.profile?.highlights[1].subtitle == "Artist A" && monthCard.profile?.highlights[0].subtitle == nil)
            check("its milestones are grouped by kind, biggest first", monthCard.profile?.chips.map(\.text) == ["25K · Total", "5K · Artist B", "1K · Artist A"], "\(monthCard.profile?.chips.map(\.text) ?? [])")
            check("by time listened the picks show time", ShareCards.timelineMonth(timelineMonth, metric: .timeListened).profile?.highlights[0].value == DurationEngine.formatTimeListened(9_000))
            check("a recap draws its three pictures", monthCard.pictureURLs(for: ShareOptions()).compactMap { $0 }.count == 3)
            let monthTable = ShareText.markdownTable(monthCard, options: ShareOptions())
            check("the month's text carries the picks", monthTable.contains("| Top Artist | Artist A (41 plays) |") && monthTable.contains("| Top Album | Album A — Artist A (30 plays) |") && ShareText.plain(monthCard, options: ShareOptions()).contains("• Top Track: Song A — Artist A (1 play)"), monthTable)
            check("a month's milestone chips carry their tier and what they were for", monthCard.profile?.chips.map(\.tier) == [25_000, 5000, 1000] && monthCard.profile?.chips.map(\.detail) == ["Total", "Artist B", "Artist A"])
            var recoloured = monthCard
            recoloured.profile?.chips[2].tier = 100
            check("the chip colour follows the tier (same words, different tier, different image)", ShareRenderer.png(card: recoloured, options: ShareOptions(), identity: .anonymous, images: [:]) != ShareRenderer.png(card: monthCard, options: ShareOptions(), identity: .anonymous, images: [:]))
            check("a milestone card's headline carries its tier", milestoneCard.profile?.headlineTier == 1000)
            var otherTier = milestoneCard
            otherTier.profile?.headlineTier = 100
            check("…and its colour follows it", ShareRenderer.png(card: otherTier, options: ShareOptions(), identity: .anonymous, images: [:]) != ShareRenderer.png(card: milestoneCard, options: ShareOptions(), identity: .anonymous, images: [:]))
            check("the tier colours are the app's, gold for the prestige tiers", ShareCardStyle.milestoneColor(25_000) == ShareCardStyle.gold && ShareCardStyle.milestoneColor(100) == MilestoneFormatting.milestoneColor(100) && ShareCardStyle.milestoneColor(100) != ShareCardStyle.milestoneColor(1000))
            let recapSwatch = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in NSColor.systemPurple.setFill(); rect.fill(); return true }
            for size in ShareSize.allCases {
                var o = ShareOptions(); o.size = size
                let png = ShareRenderer.png(card: monthCard, options: o, identity: .anonymous, images: [:])
                let image = png.flatMap { NSBitmapImageRep(data: $0) }
                check("a month card, \(size.label): a PNG at 2x, not blank", image?.pixelsWide == Int(size.points.width) * 2 && image?.pixelsHigh == Int(size.points.height) * 2 && (image.map { luminanceSpread($0) > 0.05 } ?? false))
                let withArt = ShareRenderer.png(card: monthCard, options: o, identity: .anonymous, images: ["file:///art/Album A.jpg": recapSwatch])
                let withName = ShareRenderer.png(card: monthCard, options: o, identity: ShareIdentity(name: "someone", showsFooter: true), images: [:])
                check("a month card, \(size.label): pictures and the footer change the image", withArt != png && withName != png)
            }
            let emptyMonth = TimelineMonth(monthStart: monthStart, top: TimelinePeriodTop(artist: nil, album: nil, track: nil), weeks: [], totals: TimelineMonthTotals(plays: 0, artists: 0, albums: 0, tracks: 0), milestones: [])
            let emptyCard = ShareCards.timelineMonth(emptyMonth, metric: .scrobbles)
            check("a month with no picks still makes a card that renders", emptyCard.profile?.highlights.isEmpty == true && (ShareRenderer.png(card: emptyCard, options: ShareOptions(), identity: .anonymous, images: [:]).flatMap { NSBitmapImageRep(data: $0) }?.pixelsWide ?? 0) == 2160)

            // MARK: One artist, album or track
            let profileCard = sampleProfileCard()
            check("no card until the page's numbers have loaded", ShareCards.profile(entity: .album, name: "Album A", artist: "Artist A", album: nil, imageURL: nil, periodLabel: "All time", stats: nil, metric: .scrobbles, timeListenedSeconds: nil, facts: [], yearlyTopRanks: []) == nil)
            check("a page card says what it is", profileCard.title == "Album A" && profileCard.period == "Last 12 months" && profileCard.kindID == "page.album" && profileCard.profile?.kind == "Album" && profileCard.profile?.subtitle == "Artist A" && profileCard.profile?.heroImageURL == "file:///art/a.jpg")
            check("its tiles are the headline numbers then the page's facts that have a value", profileCard.profile?.stats.map(\.label) == ["Scrobbles", "First scrobble", "Last scrobble", "Play frequency", "Released", "Turnover rate"], "\(profileCard.profile?.stats.map(\.label) ?? [])")
            check("the plays tile reads as the page shows it", profileCard.profile?.stats.first?.value == 1234.formatted())
            check("rank chips then the three highest milestones, highest first", profileCard.profile?.chips.map(\.text) == ["#3 of 2024", "#7 of 2022", "5K plays · " + Date(timeIntervalSince1970: 1_700_000_000).formatted(date: .abbreviated, time: .omitted), "1K plays · " + Date(timeIntervalSince1970: 1_650_000_000).formatted(date: .abbreviated, time: .omitted), "500 plays · " + Date(timeIntervalSince1970: 1_600_000_000).formatted(date: .abbreviated, time: .omitted)], "\(profileCard.profile?.chips.map(\.text) ?? [])")
            check("a page's milestone chips carry their tier and date, rank chips none", profileCard.profile?.chips.map(\.tier) == [nil, nil, 5000, 1000, 500] && profileCard.profile?.chips[2].detail == Date(timeIntervalSince1970: 1_700_000_000).formatted(date: .abbreviated, time: .omitted))
            check("the trend carries each bucket's plays", profileCard.profile?.trend == [0, 4, 9, 2, 7, 3])
            let weatherFact = DetailFact(id: "weather", label: "Weather", value: .text("Rain +34%"), detail: "41 of 120 plays", mayHaveDetail: true, systemImage: "cloud.sun")
            let weatherCard = ShareCards.profile(entity: .album, name: "Album A", artist: "Artist A", album: nil, imageURL: nil, periodLabel: "All time", stats: sampleProfileStats(), metric: .scrobbles, timeListenedSeconds: nil, facts: [weatherFact], yearlyTopRanks: [])!
            var weatherOn = ShareOptions(); weatherOn.showWeather = true
            check("weather is offered but not among the ordinary tiles", weatherCard.hasWeather && weatherCard.profile?.weather == ShareStat(label: "Weather", value: "Rain +34%") && !(weatherCard.profile?.stats.map(\.label) ?? []).contains("Weather"))
            check("it is left off the card and the text unless chosen", !weatherCard.visibleStats(for: ShareOptions()).map(\.label).contains("Weather") && !ShareText.plain(weatherCard, options: ShareOptions()).contains("Rain"))
            check("chosen, it is the last tile and is in the text", weatherCard.visibleStats(for: weatherOn).last?.value == "Rain +34%" && ShareText.plain(weatherCard, options: weatherOn).contains("Weather: Rain +34%"))
            let fullCard = ShareCard(title: "T", period: "P", measure: "", rows: [], valueLabel: "Plays", hasMovement: false, kindID: "page.album", profile: ShareProfile(kind: "Album", subtitle: "", heroImageURL: nil, stats: (1...10).map { ShareStat(label: "L\($0)", value: "\($0)") }, chips: [], trend: [], weather: ShareStat(label: "Weather", value: "Rain +34%")))
            check("a full card shows the weather when chosen, in place of its last tile, and the same count either way", fullCard.visibleStats(for: weatherOn).last?.label == "Weather" && fullCard.visibleStats(for: weatherOn).count == 6 && fullCard.visibleStats(for: ShareOptions()).count == 6 && !fullCard.visibleStats(for: ShareOptions()).map(\.label).contains("Weather"))
            check("a card without weather offers none, and the choice changes nothing", !profileCard.hasWeather && profileCard.visibleStats(for: weatherOn) == profileCard.visibleStats(for: ShareOptions()))
            check("options saved before the switch existed decode with it off", (try? JSONDecoder().decode(ShareOptions.self, from: Data("{\"rowCount\":5}".utf8)))?.showWeather == false)
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

            // MARK: Titles, subtitles and chart cards drawn for the card
            func differs(_ a: Data?, _ b: Data?) -> Bool { a != nil && b != nil && a != b }
            @MainActor func rendered(_ card: ShareCard, _ options: ShareOptions, images: [String: NSImage] = [:]) -> Data? {
                ShareRenderer.png(card: card, options: options, identity: .anonymous, images: images)
            }
            var typedTitle = ShareOptions(); typedTitle.customTitle = "My own title"
            var typedSubtitle = ShareOptions(); typedSubtitle.customSubtitle = "My own subtitle"
            check("every kind of card takes a typed title: the page card, the list and the picture of a chart", (typedTitle.customTitle == "My own title") && profileCard.displayTitle(for: typedTitle) == "My own title" && card.displayTitle(for: typedTitle) == "My own title" && chartCard.displayTitle(for: typedTitle) == "My own title" && profileCard.displayTitle(for: ShareOptions()) == "Album A")
            check("…and a typed subtitle replaces the artist line or the measure", profileCard.displaySubtitle(for: typedSubtitle) == "My own subtitle" && card.displaySubtitle(for: typedSubtitle) == "My own subtitle" && profileCard.displaySubtitle(for: ShareOptions()) == "Artist A" && card.displaySubtitle(for: ShareOptions()) == "Ranked by scrobbles")
            for (name, target) in [("page card", profileCard), ("list card", card), ("chart picture card", chartCard)] {
                var plain = target.defaultOptions
                var titled = plain; titled.customTitle = "A different title"
                var subtitled = plain; subtitled.customSubtitle = "A different subtitle"
                plain.size = .square; titled.size = .square; subtitled.size = .square
                check("\(name): a typed title and a typed subtitle each change the image", differs(rendered(target, plain), rendered(target, titled)) && differs(rendered(target, plain), rendered(target, subtitled)))
                check("\(name): the text copies use the typed title", ShareText.plain(target, options: titled).contains("A different title") && ShareText.markdownList(target, options: titled).contains("A different title"))
            }
            // A chart card with its own controls, drawn at the card's size.
            let framework = ShareNativeChart(
                id: "test", caption: "What it shows, in a sentence", footnote: "How it is worked out", preferredSize: .wide,
                controls: [ShareNativeControl(id: "extra", label: "Extra", kind: .toggle(defaultValue: true)), ShareNativeControl(id: "rows", label: "Rows", kind: .count(range: 1...5, defaultValue: 3)), ShareNativeControl(id: "mode", label: "Mode", kind: .choice(["a", "b"], defaultValue: "a"))],
                textLines: ["first line", "second line"]
            ) { layout, options, _ in
                AnyView(VStack(spacing: 4) {
                    ForEach(0..<options.number("rows", 3), id: \.self) { _ in Rectangle().fill(options.flag("extra", true) ? Color.red : Color.blue).frame(height: 30) }
                    Text(options.pick("mode", "a")).foregroundStyle(.white)
                })
            }
            let nativeCard = ShareCard(title: "Native chart", period: "Last 6 months", measure: "", rows: [], valueLabel: "", hasMovement: false, kindID: "test.native", native: framework)
            check("a native chart card opens on the shape the chart prefers, is not a list, and has no pictures to load", nativeCard.defaultOptions.size == .wide && !nativeCard.isList && nativeCard.pictureURLs(for: ShareOptions()).isEmpty && !nativeCard.fitsChart(for: nativeCard.defaultOptions))
            for size in ShareSize.allCases {
                var o = nativeCard.defaultOptions; o.size = size
                let image = rendered(nativeCard, o).flatMap { NSBitmapImageRep(data: $0) }
                check("native chart card, \(size.label): a PNG at 2x the card size, not blank", image?.pixelsWide == Int(size.points.width) * 2 && image?.pixelsHigh == Int(size.points.height) * 2 && (image.map { luminanceSpread($0) > 0.05 } ?? false))
            }
            let base = nativeCard.defaultOptions
            var noExtra = base; noExtra.flags["extra"] = false
            var fewer = base; fewer.numbers["rows"] = 1
            var modeB = base; modeB.picks["mode"] = "b"
            var noCaption = base; noCaption.flags["caption"] = false
            var withFootnote = base; withFootnote.flags["footnote"] = true
            var typedCaption = base; typedCaption.customCaption = "My own caption"
            check("a toggle, a count and a choice each change what the chart draws", differs(rendered(nativeCard, base), rendered(nativeCard, noExtra)) && differs(rendered(nativeCard, base), rendered(nativeCard, fewer)) && differs(rendered(nativeCard, base), rendered(nativeCard, modeB)))
            check("the caption can be left off, retyped, and the method line added", differs(rendered(nativeCard, base), rendered(nativeCard, noCaption)) && differs(rendered(nativeCard, base), rendered(nativeCard, typedCaption)) && differs(rendered(nativeCard, base), rendered(nativeCard, withFootnote)))
            let nativeText = ShareText.plain(nativeCard, options: base)
            check("the text copy has the title, the caption and the lines", nativeText.contains("Native chart") && nativeText.contains("What it shows, in a sentence") && nativeText.contains("• first line") && !nativeText.contains("How it is worked out"))
            check("…a retyped caption replaces the sentence, an off caption removes it, the method line follows its switch", ShareText.plain(nativeCard, options: typedCaption).contains("My own caption") && !ShareText.plain(nativeCard, options: typedCaption).contains("What it shows") && !ShareText.plain(nativeCard, options: noCaption).contains("What it shows") && ShareText.plain(nativeCard, options: withFootnote).contains("How it is worked out"))
            check("…and the Markdown forms use bullets", ShareText.markdownList(nativeCard, options: base).contains("- first line") && ShareText.markdownTable(nativeCard, options: base).contains("- second line"))
            let suiteNative = UserDefaults(suiteName: "share-native-\(UUID().uuidString)")!
            var chosenNative = noExtra; chosenNative.numbers["rows"] = 2; chosenNative.picks["mode"] = "b"; chosenNative.customCaption = "not remembered"
            ShareSettings.save(chosenNative, for: nativeCard.kindID, defaults: suiteNative)
            let remembered = ShareSettings.options(for: nativeCard.kindID, fallback: nativeCard.defaultOptions, defaults: suiteNative)
            check("the choices are remembered per kind of card, a typed caption is not", remembered.flags["extra"] == false && remembered.numbers["rows"] == 2 && remembered.picks["mode"] == "b" && remembered.customCaption.isEmpty)
            check("options saved before these controls existed still load", (try? JSONDecoder().decode(ShareOptions.self, from: Data("{\"size\":\"wide\"}".utf8)))?.flags.isEmpty == true)
            // The Weather & places charts as cards, on made-up listening.
            let natives = await DetailSnapshots.nativeShareCards()
            check("every Trends chart drawn for the card makes one: the five weather and places charts and the nine others", natives.map(\.name) == ["tiles", "grid", "timeline", "leanings", "places", "volume", "heatmap", "discovery", "taste", "eras", "flow", "loyalty", "rankings", "longtail", "volumecompare"], "\(natives.map(\.name))")
            for (name, nativeChartCard, images) in natives {
                for size in ShareSize.allCases {
                    var o = nativeChartCard.defaultOptions; o.size = size
                    let image = rendered(nativeChartCard, o, images: images).flatMap { NSBitmapImageRep(data: $0) }
                    check("\(name) card, \(size.label): a PNG at 2x the card size, with the chart drawn", image?.pixelsWide == Int(size.points.width) * 2 && image?.pixelsHigh == Int(size.points.height) * 2 && (image.map { luminanceSpread($0) > 0.05 } ?? false))
                }
                let o = nativeChartCard.defaultOptions
                check("\(name) card: has a caption, controls and lines to copy", !(nativeChartCard.native?.caption.isEmpty ?? true) && !(nativeChartCard.native?.controls.isEmpty ?? true) && ShareText.plain(nativeChartCard, options: o).contains(nativeChartCard.title))
            }
            let toggles = [
                "tiles": "detail", "grid": "values", "timeline": "markers", "leanings": "artwork", "places": "home", "volume": "area", "heatmap": "hours",
                "discovery": "legend", "taste": "bars", "eras": "legend", "flow": "bars", "loyalty": "summary", "rankings": "points", "longtail": "stats",
            ]
            for (name, nativeChartCard, images) in natives {
                guard let control = toggles[name] else { continue }
                var on = nativeChartCard.defaultOptions, off = on
                on.flags[control] = true; off.flags[control] = false
                check("\(name) card: turning “\(control)” off changes the picture", differs(rendered(nativeChartCard, on, images: images), rendered(nativeChartCard, off, images: images)))
            }
            if let compared = natives.first(where: { $0.name == "volumecompare" }), let native = compared.card.native {
                let off = compared.card.defaultOptions
                var on = off; on.flags["compare"] = true
                check("the comparison is left out until asked for: nothing about it in the sentence, under the title or in the text", !native.displayCaption(for: off).contains(" vs ") && compared.card.displaySubtitle(for: off).isEmpty && !ShareText.plain(compared.card, options: off).contains("Compared with"))
                check("…and including it adds the comparison to the sentence, the subtitle, the text and the chart", native.displayCaption(for: on).contains(" vs ") && compared.card.displaySubtitle(for: on).hasPrefix("Compared with") && ShareText.plain(compared.card, options: on).contains("Compared with") && differs(rendered(compared.card, off, images: compared.images), rendered(compared.card, on, images: compared.images)))
                check("every comparison control starts off", native.controls.filter { $0.id == "compare" }.allSatisfy { if case .toggle(let value) = $0.kind { !value } else { false } } && !native.controls.filter { $0.id == "compare" }.isEmpty)
                var typed = off; typed.customSubtitle = "My subtitle"
                check("a typed subtitle shows whether or not the comparison is in", compared.card.displaySubtitle(for: typed) == "My subtitle")
            }
            if let leanings = natives.first(where: { $0.name == "leanings" }) {
                check("the leanings card loads the artwork its rows show", !leanings.images.isEmpty && !leanings.card.pictureURLs(for: leanings.card.defaultOptions).isEmpty, "\(leanings.images.count)")
                check("its text lists the rows with their plays and days", ShareText.plain(leanings.card, options: leanings.card.defaultOptions).contains("plays on"))
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
        // A Query result: albums by plays over the last year, run through the real engine on the real plays, against plain counts.
        var realSpec = QuerySpec(target: .album)
        realSpec.period = QueryPeriod(from: range.from, to: range.to)
        realSpec.sorts = [QuerySort(key: .field(QueryFieldRef("plays")), direction: .descending)]
        realSpec.columns = [QueryFieldRef("lastPlayed"), QueryFieldRef("plays")]
        realSpec.limit = 10
        if let validated = try? realSpec.validate(against: .standard) {
            let all = (try? await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)) ?? []
            let realResult = QueryEngine.evaluate(validated, run: QueryRun(target: .album, asOf: range.to, scrobbles: realSpec.countedPlays(all), allTimeScrobbles: all, snapshots: QuerySnapshots()))
            let realRows = QueryDisplayRow.make(from: realResult, imageLookup: [:])
            let realCard = ShareCards.queryResult(
                title: "albums, last 365 days", target: .album, measure: "", rows: realRows, columns: realResult.columns,
                sortedColumn: ShareCards.sortedColumnIndex(columns: realResult.columns, sorts: realSpec.sorts, target: .album, registry: .standard)
            )
            check("the query card has ten rows and shows the plays by default", realCard.rows.count == 10 && realCard.valueName(for: ShareOptions()) == realResult.columns[1].title)
            let windowPlays = all.filter { $0.playedAt >= range.from && $0.playedAt <= range.to }
            for row in realCard.rows.prefix(5) {
                let artist = realRows[row.rank - 1].entity.artist
                let own = windowPlays.filter { $0.albumName == row.title && TextNormalization.artistIdentityKey($0.artistName) == TextNormalization.artistIdentityKey(artist) }
                let last = own.map(\.playedAt).max()
                check("query card #\(row.rank): plays equal an independent count (\(own.count)) and last played is the latest play", row.value == own.count.formatted() && row.values[0] == last.map { QueryCellText.date($0, fieldID: "lastPlayed") }, "\(row.value) / \(row.values[0])")
            }
            let realPlaysKey = realResult.columns.count > 1 ? realResult.columns[1].cacheKey : ""
            let realPlays: [Double] = realResult.rows.map { row in
                if case .value(.number(let n))? = row.cells[realPlaysKey] { return n }
                return 0
            }
            check("the rows are in falling order of plays", zip(realPlays, realPlays.dropFirst()).allSatisfy { $0 >= $1 })
            let urls = realCard.pictureURLs(for: ShareOptions())
            let images = await ShareArtwork.load(urls)
            for size in ShareSize.allCases {
                var options = ShareOptions(); options.size = size
                let start = Date()
                let png = ShareRenderer.png(card: realCard, options: options, identity: .anonymous, images: images)
                let seconds = Date().timeIntervalSince(start)
                if let png { try? png.write(to: URL(fileURLWithPath: folder).appending(path: "real-query-\(size.rawValue).png")) }
                check("the query card, \(size.label): rendered in \(String(format: "%.2f", seconds)) s", png != nil && seconds < 3)
            }
        } else {
            check("the real-library query validates", false)
        }
        // A Rabbit Hole path: the library's most played tracks as the steps, against plain counts of the history.
        do {
            let all = (try? await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)) ?? []
            let byTrack = Dictionary(grouping: all, by: { TextNormalization.lovedKey(artist: $0.artistName, track: $0.trackName) })
            let top = byTrack.values.sorted { $0.count > $1.count }.prefix(6)
            var nodes: [RabbitHoleNode] = []
            for (index, plays) in top.enumerated() {
                let first = plays[0]
                let track = RabbitHoleTrack(artist: first.artistName, track: first.trackName, album: first.albumName, imageURL: plays.compactMap(\.imageURL).first, playCount: plays.count, lastPlayed: plays.map(\.playedAt).max(), matchScore: 0, source: "check", reasons: index == 0 ? nil : [RabbitHoleReason(kind: .similar, text: "Last.fm: similar to the step before")])
                nodes.append(RabbitHoleNode(id: UUID(), track: track, parentID: index == 0 ? nil : nodes[index - 1].id, candidates: nil, childIDs: []))
            }
            let card = ShareCards.rabbitHole(path: nodes)
            check("the path card has six steps", card.rows.count == 6)
            for (row, plays) in zip(card.rows, top) {
                let last = plays.map(\.playedAt).max()
                check("path step \(row.rank): plays equal an independent count (\(plays.count)) and last play the latest", row.value == plays.count.formatted() && row.values[1] == last.map { $0.formatted(date: .abbreviated, time: .omitted) }, "\(row.value) / \(row.values)")
            }
            let images = await ShareArtwork.load(card.pictureURLs(for: ShareOptions()))
            for size in ShareSize.allCases {
                var options = ShareOptions(); options.size = size
                let start = Date()
                let png = ShareRenderer.png(card: card, options: options, identity: .anonymous, images: images)
                let seconds = Date().timeIntervalSince(start)
                if let png { try? png.write(to: URL(fileURLWithPath: folder).appending(path: "real-path-\(size.rawValue).png")) }
                check("the path card, \(size.label): rendered in \(String(format: "%.2f", seconds)) s", png != nil && seconds < 3)
            }
        }
        // The Overview recap, from the page's own totals engine against plain counts over the history.
        do {
            let all = (try? await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)) ?? []
            let compareRange = OverviewTotalsEngine.endingDaysAgo(range, days: 30)
            let totals = OverviewTotalsEngine.fetch(scrobbles: all, range: range, compareRange: compareRange)
            let card = ShareCards.overviewRecap(ShareCards.OverviewRecapInput(totals: totals, metric: .scrobbles, timeListenedSeconds: nil, periodLabel: "Last 365 days", isAllTime: false, compareLabel: "30 days ago", firstScrobble: all.first?.playedAt, currentStreak: nil))
            let windowPlays = all.filter { $0.playedAt >= range.from && $0.playedAt <= range.to }
            let before = all.filter { play in compareRange.map { play.playedAt >= $0.from && play.playedAt <= $0.to } ?? false }
            let stats = Dictionary(uniqueKeysWithValues: (card?.profile?.stats ?? []).map { ($0.label, $0.value) })
            check("recap: scrobbles equal an independent count (\(windowPlays.count))", stats["Scrobbles"] == windowPlays.count.formatted(), "\(stats["Scrobbles"] ?? "none")")
            check("recap: artists, albums and tracks are the distinct counts", stats["Artists"] == Set(windowPlays.map(\.artistName)).count.formatted() && stats["Albums"] == Set(windowPlays.filter { !$0.albumName.isEmpty }.map { $0.artistName + "\u{0}" + $0.albumName }).count.formatted() && stats["Tracks"] == Set(windowPlays.map { $0.artistName + "\u{0}" + $0.trackName }).count.formatted(), "\(stats)")
            if !before.isEmpty {
                let pct = Int((Double(windowPlays.count - before.count) / Double(before.count) * 100).rounded())
                check("recap: the comparison equals an independent percentage (\(pct)%)", stats["Vs 30 days ago"] == (pct > 0 ? "+" : "") + "\(pct)%", "\(stats["Vs 30 days ago"] ?? "none")")
            }
            if let top = card?.profile?.highlights.first {
                let counts = Dictionary(grouping: windowPlays, by: \.artistName).mapValues(\.count)
                check("recap: the top artist is the most played, with its plays (\(counts.values.max() ?? 0))", top.value == "\((counts.values.max() ?? 0).formatted()) plays" && counts[top.title] == counts.values.max(), "\(top.title) \(top.value)")
            }
            let allTotals = OverviewTotalsEngine.fetch(scrobbles: all, range: DateRange(from: all.first?.playedAt ?? range.from, to: Date()), compareRange: nil)
            let allCard = ShareCards.overviewRecap(ShareCards.OverviewRecapInput(totals: allTotals, metric: .scrobbles, timeListenedSeconds: nil, periodLabel: "All time", isAllTime: true, compareLabel: nil, firstScrobble: all.first?.playedAt, currentStreak: nil))
            check("recap, all time: every scrobble, and since the first one", allCard?.profile?.stats.first?.value == all.count.formatted() && allCard?.profile?.stats.contains { $0.label == "Scrobbling since" } == true)
            let images = await ShareArtwork.load(card?.pictureURLs(for: ShareOptions()) ?? [])
            for size in ShareSize.allCases {
                var options = ShareOptions(); options.size = size
                let start = Date()
                let png = card.flatMap { ShareRenderer.png(card: $0, options: options, identity: .anonymous, images: images) }
                let seconds = Date().timeIntervalSince(start)
                if let png { try? png.write(to: URL(fileURLWithPath: folder).appending(path: "real-recap-\(size.rawValue).png")) }
                check("recap, \(size.label): rendered in \(String(format: "%.2f", seconds)) s", png != nil && seconds < 3)
            }
        }
        // A per-release-year query on the real library: the most played album of each release year, shown oldest first, against an independent walk.
        do {
            var spec = QuerySpec(target: .album)
            spec.sorts = [QuerySort(key: .field(QueryFieldRef("plays")), direction: .descending)]
            spec.groupLimit = QueryGroupLimit(perReleaseYear: 1)
            spec.columns = [QueryFieldRef("plays"), QueryFieldRef("releaseYear")]
            if let validated = try? spec.validate(against: .standard) {
                let all = (try? await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)) ?? []
                let loaded = await QuerySnapshotReader.loadAll(container: container)
                let snapshots = QuerySnapshots(durations: loaded.durations, releaseDates: loaded.releaseDates, turnover: loaded.turnover, lovedKeys: loaded.lovedKeys, entityTags: loaded.entityTags, images: loaded.images)
                let result = QueryEngine.evaluate(validated, run: QueryRun(target: .album, asOf: Date(), scrobbles: all, allTimeScrobbles: all, snapshots: snapshots))
                let yearIndex = result.columns.firstIndex { $0.field.id == "releaseYear" } ?? 0
                let years: [Int?] = result.rows.map { row in
                    if case .value(.number(let n))? = row.cells[result.columns[yearIndex].cacheKey] { Int(n) } else { nil }
                }
                let dated = years.compactMap { $0 }
                check("per-year query on the library: \(result.rows.count) albums, the dated ones in non-decreasing year order", dated == dated.sorted(), "\(dated.prefix(12))")
                check("…each dated year appears once", Set(dated).count == dated.count)
                // Independent: the most played album of each year, from the same rank-order run (showing it in rank order instead).
                var rankSpec = spec; rankSpec.showInRankOrder = true
                if let rankValidated = try? rankSpec.validate(against: .standard) {
                    let ranked = QueryEngine.evaluate(rankValidated, run: QueryRun(target: .album, asOf: Date(), scrobbles: all, allTimeScrobbles: all, snapshots: snapshots))
                    check("…and the same albums as when shown in rank order", Set(ranked.rows.map(\.id)) == Set(result.rows.map(\.id)) && ranked.rows.count == result.rows.count)
                    let playsKey = result.columns.first { $0.field.id == "plays" }?.cacheKey ?? ""
                    func plays(_ row: QueryRow) -> Double { if case .value(.number(let n))? = row.cells[playsKey] { n } else { 0 } }
                    let rankPlays = ranked.rows.map(plays)
                    check("…and in rank order they fall in plays (so the year order is a reordering, not a different pick)", rankPlays == rankPlays.sorted(by: >))
                }
            } else {
                check("the per-year query validates", false)
            }
        }
        // The top artists, albums and tracks of each calendar year of the real library, against independent counts, and how long it takes.
        do {
            let all = (try? await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)) ?? []
            let calendar = AppCalendars.listening
            for target in [QueryTarget.artist, .album, .track] {
                var spec = QuerySpec(target: target)
                spec.sorts = [QuerySort(key: .field(QueryFieldRef("plays")), direction: .descending)]
                spec.columns = [QueryFieldRef("plays")]
                spec.limit = 3
                spec.breakdown = QueryBreakdown()
                guard let validated = try? spec.validate(against: .standard) else { check("the \(target.rawValue) breakdown validates", false); continue }
                let start = Date()
                let result = QueryEngine.evaluate(validated, run: QueryRun(target: target, asOf: Date(), scrobbles: all, allTimeScrobbles: all, snapshots: QuerySnapshots()))
                let seconds = Date().timeIntervalSince(start)
                // Independent: count each year's plays by entity with plain dictionaries and take the top three.
                var counts: [Int: [String: Int]] = [:]
                for play in all {
                    let year = calendar.component(.year, from: play.playedAt)
                    let key: String
                    switch target {
                    case .artist: key = play.artistName
                    case .album: if play.albumName.isEmpty { continue }; key = play.artistName + "\u{0}" + play.albumName
                    case .track: key = play.artistName + "\u{0}" + play.trackName
                    }
                    counts[year, default: [:]][key, default: 0] += 1
                }
                var mismatches: [String] = []
                var checkedYears = 0
                let playsKey = result.columns.first?.cacheKey ?? ""
                for (year, byEntity) in counts {
                    let rows = result.rows.filter { $0.period == year }
                    let got: [Int] = rows.map { row in if case .value(.number(let n))? = row.cells[playsKey] { Int(n) } else { -1 } }
                    let want = Array(byEntity.values.sorted(by: >).prefix(3))
                    checkedYears += 1
                    if got != want { mismatches.append("\(year): \(got) vs \(want)") }
                }
                let periods = result.rows.compactMap(\.period)
                check("\(target.rawValue)s by year: \(checkedYears) years, the top three's plays equal an independent count each year, in \(String(format: "%.2f", seconds)) s", mismatches.isEmpty && periods == periods.sorted() && seconds < 20, "\(mismatches.prefix(3))")
            }
        }
        // Milestones and Timeline, from the same engines the pages use, against plain counts over the history.
        let canonical = (try? await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)) ?? []
        let milestoneResult = MilestonesEngine.fetch(scrobbles: canonical)
        let listCard = ShareCards.milestones(category: "Albums", tierLabel: "All milestones", rows: milestoneResult.albums.achieved.map {
            ShareCards.MilestoneRow(name: $0.name, artist: $0.artist, imageURL: $0.imageURL, milestone: $0.milestone, achievedAt: $0.achievedAt)
        })
        check("the albums milestone list has rows", !listCard.rows.isEmpty, "\(listCard.rows.count)")
        for item in milestoneResult.albums.achieved.prefix(5) {
            let artistKey = item.artist.map(TextNormalization.artistIdentityKey)
            let dates = canonical.filter { $0.albumName == item.name && TextNormalization.artistIdentityKey($0.artistName) == artistKey }.map(\.playedAt).sorted()
            let nth = dates.count >= item.milestone ? dates[item.milestone - 1] : nil
            let card = ShareCards.milestone(kind: "Album", name: item.name, artist: item.artist, imageURL: item.imageURL, milestone: item.milestone, achievedAt: item.achievedAt, firstAt: item.firstAt)
            check("milestone card \(item.milestone.formatted()) plays: reached on the date of the \(item.milestone.formatted())th play, first play matches", nth == item.achievedAt && dates.first == item.firstAt && card.profile?.stats.first?.value == item.achievedAt.formatted(date: .abbreviated, time: .omitted), "\(String(describing: nth)) vs \(item.achievedAt)")
        }
        let timeline = TimelineEngine.fetch(scrobbles: (try? await ScrobbleHistoryCache.shared.snapshots(container: container)) ?? [], metric: .scrobbles)
        if let month = timeline.months.first {
            let calendar = AppCalendars.listening
            let end = calendar.date(byAdding: .month, value: 1, to: month.monthStart)!
            let inMonth = canonical.filter { $0.playedAt >= month.monthStart && $0.playedAt < end }
            let card = ShareCards.timelineMonth(month, metric: .scrobbles)
            check("the latest month card: plays equal an independent count (\(inMonth.count))", card.profile?.stats.first?.value == inMonth.count.formatted(), "\(card.profile?.stats.first?.value ?? "none")")
            check("…and its artists, albums and tracks are the distinct counts", card.profile?.stats.dropFirst().map(\.value) == [Set(inMonth.map { TextNormalization.artistIdentityKey($0.artistName) }).count.formatted(), Set(inMonth.map { TextNormalization.artistIdentityKey($0.artistName) + "|" + $0.albumName }).count.formatted(), Set(inMonth.map { TextNormalization.artistIdentityKey($0.artistName) + "|" + $0.trackName }).count.formatted()].map { $0 }, "\(card.profile?.stats.map(\.value) ?? [])")
            if let top = month.top.artist {
                let plays = inMonth.filter { TextNormalization.artistIdentityKey($0.artistName) == TextNormalization.artistIdentityKey(top.name) }.count
                check("…and the top artist's plays equal an independent count (\(plays))", card.profile?.highlights.first?.value == "\(plays.formatted()) \(plays == 1 ? "play" : "plays")", "\(card.profile?.highlights.first?.value ?? "none")")
            }
            let urls = card.pictureURLs(for: ShareOptions())
            let images = await ShareArtwork.load(urls)
            for size in ShareSize.allCases {
                var options = ShareOptions(); options.size = size
                let start = Date()
                let png = ShareRenderer.png(card: card, options: options, identity: .anonymous, images: images)
                let seconds = Date().timeIntervalSince(start)
                if let png { try? png.write(to: URL(fileURLWithPath: folder).appending(path: "real-month-\(size.rawValue).png")) }
                check("the latest month card, \(size.label): rendered in \(String(format: "%.2f", seconds)) s", png != nil && seconds < 3)
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


    // MARK: Stress

    /// Resident memory of this process, in MB.
    private static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    /// The process's footprint (what Activity Monitor calls Memory), in MB.
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// `SCROBLYTICS_SHARE_STRESS=1`: renders hundreds of cards of every kind, size and layout with large pictures, one after another, the way
    /// a person trying options in the preview would, and reports the time of each and whether memory keeps growing. Exits 0 when the
    /// slowest render is under a few seconds and memory settles.
    @MainActor
    private static func stress() {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty ? "" : "  [\(detail)]"))
            if !ok { failures += 1 }
        }
        // 600 × 600 pictures, like real cover art, one per card slot.
        // Real artwork is a decoded picture from a file, not a drawing that is redrawn on use: encode each one and read it back.
        let pictures: [String: NSImage] = autoreleasepool { Dictionary(uniqueKeysWithValues: (0..<40).compactMap { index -> (String, NSImage)? in
            let drawn = NSImage(size: NSSize(width: 600, height: 600), flipped: false) { rect in
                NSColor(hue: CGFloat(index) / 40, saturation: 0.6, brightness: 0.8, alpha: 1).setFill(); rect.fill()
                NSColor.white.withAlphaComponent(0.3).setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 100, dy: 100)).fill(); return true
            }
            guard let tiff = drawn.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]),
                  let loaded = NSImage(data: data) else { return nil }
            return ("file:///art/\(index).jpg", loaded)
        }) }
        let url: @Sendable (Int) -> String = { "file:///art/\($0 % 40).jpg" }
        let entries = sampleEntries()
        let topCard = ShareCards.topChart(entries: entries, entity: .album, metric: .scrobbles, periodLabel: "Year to date")
        let longRows = (1...20).map { i in ShareRow(rank: i, title: "A rather long title number \(i) 日本語 🎵", subtitle: "Artist \(i) & Friends", value: "\(1000 - i)", change: .up(i), imageURL: url(i), values: ["\(1000 - i)", "Oct \(i)", "\(i)%"], note: "you often play it after the one before it (\(i) times)") }
        var listCard = ShareCard(title: "Down the rabbit hole", period: "", measure: "", rows: longRows, valueLabel: "Plays", hasMovement: false, kindID: "stress.list", valueColumns: ["Plays", "Last played", "Match score"], defaultValueColumn: 0, compactTitles: true)
        listCard.tree = ShareTree(steps: longRows.map { ShareTree.Step(chosen: ShareTree.Pick(title: $0.title, artist: $0.subtitle ?? "", imageURL: $0.imageURL), others: [ShareTree.Pick(title: "Offer A \($0.rank)", artist: "X", imageURL: url($0.rank + 1)), ShareTree.Pick(title: "Offer B \($0.rank)", artist: "Y", imageURL: url($0.rank + 2))]) })
        let profile = sampleProfileCard(imageURL: url(1))
        let month: ShareCard = {
            func item(_ entity: TopChartsEntity, _ name: String, _ artist: String?) -> TimelineTopItem { TimelineTopItem(entity: entity, name: name, artist: artist, album: nil, playcount: 99, timeListenedSeconds: nil, imageURL: url(name.count), loved: false) }
            let start = Date(timeIntervalSince1970: 1_759_000_000)
            return ShareCards.timelineMonth(TimelineMonth(monthStart: start, top: TimelinePeriodTop(artist: item(.artist, "Artist", nil), album: item(.album, "Album", "Artist"), track: item(.track, "Track", "Artist")), weeks: [], totals: TimelineMonthTotals(plays: 4000, artists: 300, albums: 500, tracks: 1200), milestones: (1...12).map { TimelineMilestone(kind: .album, name: "Album number \($0)", artist: "A", milestone: [100, 250, 500, 1000, 2500, 5000, 10000, 25000][$0 % 8], achievedAt: start) }), metric: .scrobbles)
        }()
        let identity = ShareIdentity(name: "someone_with_a_long_name", showsFooter: true)
        var cards: [(String, ShareCard, ShareOptions)] = []
        for size in ShareSize.allCases {
            for layout in ShareLayout.allCases {
                var o = ShareOptions(); o.size = size; o.layout = layout; o.rowCount = 20
                cards.append(("top", topCard, o)); cards.append(("path", listCard, o))
            }
            var o = ShareOptions(); o.size = size
            cards.append(("page", profile, o)); cards.append(("month", month, o))
        }
        let rounds = Int(ProcessInfo.processInfo.environment["SCROBLYTICS_SHARE_STRESS_ROUNDS"] ?? "") ?? 20
        let before = residentMB()
        var seconds: [Double] = []
        var samples: [Double] = []
        for round in 0..<rounds {
            for (name, card, options) in cards {
                // One render per person action in the app, so the autorelease pool drains between them; do the same here.
                autoreleasepool {
                    let start = Date()
                    let png = ShareRenderer.png(card: card, options: options, identity: identity, images: pictures)
                    seconds.append(Date().timeIntervalSince(start))
                    if png == nil { check("a render returned nothing", false) }
                }
                if round == 0 { print("  first round: \(name) \(options.size.rawValue) \(options.layout.rawValue) -> resident \(Int(residentMB())) MB") }
            }
            if round % 4 == 3 { samples.append(residentMB()) }
        }
        let footprintBefore = footprintMB()
        malloc_zone_pressure_relief(nil, 0)
        print("footprint MB after the renders: \(Int(footprintBefore)), after asking the allocator to give back free pages: \(Int(footprintMB())) (resident \(Int(residentMB())))")
        let sorted = seconds.sorted()
        let p95 = sorted[Int(Double(sorted.count) * 0.95)]
        print("renders: \(seconds.count), median \(String(format: "%.2f", sorted[sorted.count / 2])) s, p95 \(String(format: "%.2f", p95)) s, slowest \(String(format: "%.2f", sorted.last ?? 0)) s")
        print("resident MB: before \(Int(before)), after rounds 4/8/12/16/20: \(samples.map { Int($0) })")
        check("\(seconds.count) renders with 600 px pictures all produced images", failures == 0)
        check("the slowest render is under 3 s", (sorted.last ?? 0) < 3)
        // After the first rounds the footprint should be flat: the last sample is not far above the middle one.
        let growth = (samples.last ?? 0) - (samples.dropLast().last ?? 0)
        check("memory is flat over the last rounds (grew \(Int(growth)) MB)", growth < 60)
        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }


    // MARK: Trends charts

    /// `SCROBLYTICS_SHARE_SNAPSHOT_TRENDS=<folder>`: hosts the real Trends charts in an off-screen window on made-up listening, takes the
    /// picture a chart's Share button takes, and writes the cards made from them (and the raw pictures), so they can be looked at.
    @MainActor
    private static func writeTrendsSnapshots(into folder: String) async {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        // Eighteen months of made-up listening: a few artists, evening-heavy, with sessions of several tracks in a row.
        let calendar = AppCalendars.listening
        let end = Date()
        let start = calendar.date(byAdding: .month, value: -18, to: end)!
        var plays: [ScrobbleSnapshot] = []
        var day = start
        var seed = 7
        func next(_ n: Int) -> Int { seed = (seed &* 1103515245 &+ 12345) & 0x7fffffff; return seed % n }
        while day < end {
            for _ in 0..<(next(9) + 2) {
                let artist = next(12)
                let hour = 17 + next(7)
                var at = calendar.date(bySettingHour: min(hour, 23), minute: next(50), second: 0, of: day) ?? day
                for track in 0..<(next(4) + 1) {
                    plays.append(ScrobbleSnapshot(artistName: "Artist \(artist)", albumName: "Album \(artist)-\(next(3))", trackName: "Track \(artist)-\(next(12))-\(track)", imageURL: nil, playedAt: at))
                    at = at.addingTimeInterval(Double(180 + next(120)))
                }
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        plays.sort { $0.playedAt < $1.playedAt }
        // The flow chart needs many artists to fill its grid (a real library has dozens), in sittings of several tracks.
        var flowPlays: [ScrobbleSnapshot] = []
        day = start
        while day < end {
            for _ in 0..<(next(6) + 2) {
                var at = calendar.date(bySettingHour: 17 + next(6), minute: next(50), second: 0, of: day) ?? day
                for track in 0..<(next(5) + 3) {
                    let artist = next(40)
                    flowPlays.append(ScrobbleSnapshot(artistName: "Artist number \(artist)", albumName: "Album \(artist)", trackName: "Track \(artist)-\(track)", imageURL: nil, playedAt: at))
                    at = at.addingTimeInterval(Double(180 + next(120)))
                }
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        flowPlays.sort { $0.playedAt < $1.playedAt }
        let range = DateRange(from: calendar.date(byAdding: .month, value: -6, to: end)!, to: end)
        let compare = DateRange(from: calendar.date(byAdding: .month, value: -12, to: end)!, to: calendar.date(byAdding: .month, value: -6, to: end)!.addingTimeInterval(-1))
        let openQuery: (QuerySpec, String) -> Void = { _, _ in }
        let sample: [(String, String, AnyView)] = [
            ("Volume over time", "volume", AnyView(TrendsVolumeChart(inputs: .init(scrobbles: plays, durations: .empty, range: range, compareRange: compare, version: 1), openQuery: openQuery))),
            ("When you listen", "heatmap", AnyView(TrendsHeatmapChart(inputs: .init(scrobbles: plays, durations: .empty, range: range, compareRange: nil, version: 1), openQuery: openQuery))),
            ("Discovery", "discovery", AnyView(TrendsDiscoveryChart(inputs: .init(scrobbles: plays, durations: .empty, range: range, compareRange: compare, version: 1), openQuery: openQuery))),
            ("Rankings", "rankbump", AnyView(TrendsRankBumpChart(inputs: .init(scrobbles: plays, durations: .empty, range: range, version: 1), openQuery: openQuery))),
            ("Long tail", "longtail", AnyView(TrendsLongTailChart(inputs: .init(scrobbles: plays, snapshots: QuerySnapshots(), range: range, version: 1), openQuery: openQuery))),
            ("Loyalty", "loyalty", AnyView(TrendsLoyaltyChart(inputs: .init(scrobbles: plays, durations: .empty, range: range, compareRange: compare, version: 1), openQuery: openQuery, openEntity: { _ in }))),
            ("Listening flow", "flow", AnyView(TrendsFlowChart(inputs: .init(scrobbles: flowPlays, snapshots: QuerySnapshots(), range: range, compareRange: compare, version: 1), openArtist: { _ in }, openQuery: openQuery))),
        ]
        for (title, slug, chart) in sample {
            let capture = ShareChartCapture()
            let view = ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(title).font(AppTypography.sectionTitle)
                    chart.environment(\.shareChartCapture, capture)
                }
                .padding(20)
            }
            .frame(width: 1000, height: 900)
            .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            for _ in 0..<30 { try? await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded() }
            if let whole = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: whole)
                try? whole.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appending(path: "window-\(slug).png"))
            }
            guard let image = capture.image() else { print("no picture for \(title)"); continue }
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: folder).appending(path: "raw-\(slug).png"))
            }
            let card = ShareCard(title: title, period: "Last 6 months", measure: capture.summary?.change == nil ? "Compared with the 6 months before" : "", rows: [], valueLabel: "", hasMovement: false, kindID: "trends.\(slug)", snapshot: ShareSnapshot(image: image), chartSummary: capture.summary)
            for size in ShareSize.allCases {
                var o = ShareOptions(); o.size = size
                if let png = ShareRenderer.png(card: card, options: o, identity: ShareIdentity(name: "someone", showsFooter: true), images: [:], scale: 1) {
                    try? png.write(to: URL(fileURLWithPath: folder).appending(path: "trends-\(slug)-\(size.rawValue).png"))
                }
            }
            if let png = ShareRenderer.png(card: card, options: card.defaultOptions, identity: ShareIdentity(name: "someone", showsFooter: true), images: [:], scale: 1) {
                try? png.write(to: URL(fileURLWithPath: folder).appending(path: "trends-\(slug)-fit.png"))
            }
            print("\(title): picture \(Int(image.size.width)) × \(Int(image.size.height))")
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

    /// A made-up profile picture (a diagonal gradient with a light figure) for the snapshots.
    @MainActor
    static func sampleAvatar() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 300, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(starting: .systemTeal, ending: .systemIndigo)?.draw(in: NSRect(x: 0, y: 0, width: 300, height: 300), angle: 45)
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: 105, y: 150, width: 90, height: 90)).fill()
        NSBezierPath(ovalIn: NSRect(x: 60, y: 30, width: 180, height: 140)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

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
        for (name, c, count, images, identity) in [("album4", card, 4, swatches, ShareIdentity(name: "someone", showsFooter: false)), ("long20", long, 20, [:], ShareIdentity(name: "someone", showsFooter: true, avatar: sampleAvatar())), ("long5", long, 5, [:], ShareIdentity.anonymous), ("one", card, 1, swatches, ShareIdentity.anonymous)] {
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
        for (name, c, images, identity) in [("page-album", sampleProfileCard(), ["file:///art/a.jpg": hero], ShareIdentity(name: "someone", showsFooter: true, avatar: sampleAvatar())), ("page-longtrack", longTrack, ["file:///art/a.jpg": hero], ShareIdentity.anonymous), ("page-artist", noPicture, [:], ShareIdentity.anonymous)] {
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
        // Milestones and a Timeline month.
        let snapReached = Date(timeIntervalSince1970: 1_700_000_000)
        let snapMilestones = ShareCards.milestones(category: "Albums", tierLabel: "", rows: (1...8).map { i in
            ShareCards.MilestoneRow(name: "Album \(i)", artist: "Artist \(i)", imageURL: nil, milestone: [1000, 500, 250, 100][i % 4], achievedAt: snapReached.addingTimeInterval(Double(-i) * 40 * 86400))
        })
        let snapSingle = ShareCards.milestone(kind: "Album", name: "Album A", artist: "Artist A", imageURL: nil, milestone: 1000, achievedAt: snapReached, firstAt: snapReached.addingTimeInterval(-86400 * 190))
        let snapMonthStart = Date(timeIntervalSince1970: 1_759_000_000)
        func snapItem(_ entity: TopChartsEntity, _ name: String, _ artist: String?, _ plays: Int) -> TimelineTopItem {
            TimelineTopItem(entity: entity, name: name, artist: artist, album: nil, playcount: plays, timeListenedSeconds: nil, imageURL: "file:///art/\(name).jpg", loved: false)
        }
        let snapMonth = ShareCards.timelineMonth(TimelineMonth(
            monthStart: snapMonthStart,
            top: TimelinePeriodTop(artist: snapItem(.artist, "Artist A", nil, 41), album: snapItem(.album, "Album A", "Artist A", 30), track: snapItem(.track, "Song With A Rather Long Title", "Artist A & Friends", 12)),
            weeks: [], totals: TimelineMonthTotals(plays: 412, artists: 61, albums: 88, tracks: 230),
            milestones: [TimelineMilestone(kind: .total, name: "", artist: nil, milestone: 25_000, achievedAt: snapMonthStart), TimelineMilestone(kind: .artist, name: "Artist A", artist: nil, milestone: 1000, achievedAt: snapMonthStart), TimelineMilestone(kind: .album, name: "Album A", artist: "Artist A", milestone: 500, achievedAt: snapMonthStart)]
        ), metric: .scrobbles)
        let recapArt: [String: NSImage] = Dictionary(uniqueKeysWithValues: ["Artist A", "Album A", "Song With A Rather Long Title"].enumerated().map { index, name in
            ("file:///art/\(name).jpg", NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in NSColor(hue: 0.1 + CGFloat(index) * 0.25, saturation: 0.55, brightness: 0.8, alpha: 1).setFill(); rect.fill(); return true })
        })
        let snapTotals = ShareCards.milestones(category: "Total", tierLabel: "", rows: [100, 250, 500, 1000, 2500, 5000, 10000, 25000].enumerated().map { index, tier in
            ShareCards.MilestoneRow(name: "\(tier.formatted()) scrobbles", artist: nil, imageURL: nil, milestone: tier, achievedAt: snapReached.addingTimeInterval(Double(-index) * 120 * 86400))
        })
        for icon in ShareIcon.allCases {
            var o = ShareOptions(); o.size = .square; o.icon = icon
            if let png = ShareRenderer.png(card: snapTotals, options: o, identity: .anonymous, images: [:], scale: 1) {
                try? png.write(to: URL(fileURLWithPath: folder).appending(path: "milestones-totals-\(icon.rawValue).png"))
            }
        }
        let snapLong = ShareCards.milestone(kind: "Track", name: "An Extremely Long Track Title That Goes On And On Across Several Lines 日本語のタイトル", artist: "An Artist With A Very Long Name & Friends Featuring Several Other People", imageURL: "file:///art/Album A.jpg", milestone: 25_000, achievedAt: snapReached, firstAt: snapReached.addingTimeInterval(-86400 * 4000))
        let snapTotal = ShareCards.milestone(kind: "Total", name: "10,000 scrobbles", artist: nil, imageURL: nil, milestone: 10_000, achievedAt: snapReached, firstAt: snapReached.addingTimeInterval(-86400 * 900))
        for (name, c, images) in [("milestones-list", snapMilestones, [String: NSImage]()), ("milestone-single", snapSingle, [:]), ("milestone-long", snapLong, recapArt), ("milestone-total", snapTotal, [:]), ("month", snapMonth, recapArt)] {
            for size in ShareSize.allCases {
                var o = ShareOptions(); o.size = size
                if let png = ShareRenderer.png(card: c, options: o, identity: ShareIdentity(name: "someone", showsFooter: true), images: images, scale: 1) {
                    try? png.write(to: URL(fileURLWithPath: folder).appending(path: "\(name)-\(size.rawValue).png"))
                }
            }
        }
        // Query results: a sentence for a title, a saved-set style title, columns of different kinds.
        func queryRow(_ name: String, _ artist: String?, _ plays: Int, _ date: String) -> ShareRow {
            ShareRow(rank: 0, title: name, subtitle: artist, value: "\(plays)", change: .none, imageURL: nil, values: ["\(plays)", date, "\(plays * 3 % 100)%"])
        }
        let queryAsk = ShareCard(
            title: "my most played album from each release year", period: "Albums", measure: "",
            rows: (1...10).map { i in var r = queryRow("Album \(i)", "Artist \(i)", 400 - i * 23, "Oct \(i), 2025"); r.rank = i; return r },
            valueLabel: "Plays", hasMovement: false, kindID: "query.album", valueColumns: ["Plays", "Last played", "Skip rate"], defaultValueColumn: 0
        )
        var queryDate = ShareOptions(); queryDate.valueColumn = 1
        for (name, options) in [("query-plays", ShareOptions()), ("query-lastplayed", queryDate)] {
            for size in ShareSize.allCases {
                var o = options; o.size = size
                if let png = ShareRenderer.png(card: queryAsk, options: o, identity: ShareIdentity(name: "someone", showsFooter: false), images: [:], scale: 1) {
                    try? png.write(to: URL(fileURLWithPath: folder).appending(path: "\(name)-\(size.rawValue).png"))
                }
            }
        }
        // A Rabbit Hole path.
        func snapRH(_ artist: String, _ name: String, _ plays: Int, _ why: String?) -> RabbitHoleNode {
            RabbitHoleNode(id: UUID(), track: RabbitHoleTrack(artist: artist, track: name, album: nil, imageURL: nil, playCount: plays, lastPlayed: Date(timeIntervalSince1970: 1_700_000_000), matchScore: 80, source: "check", reasons: why.map { [RabbitHoleReason(kind: .similar, text: $0)] }), parentID: nil, candidates: nil, childIDs: [])
        }
        let snapPath = ShareCards.rabbitHole(path: [
            snapRH("Artist A", "The Starting Song", 120, nil), snapRH("Artist B", "Next Step Along", 47, "Last.fm: similar to The Starting Song"),
            snapRH("Artist C", "A Third Track With A Rather Long Title", 9, "you often play it after Next Step Along (6 times)"), snapRH("Artist D", "Fourth", 63, "shares tags: dream pop, slowcore"),
            snapRH("Artist E", "Fifth", 12, "tempo 118 vs 121"), snapRH("Artist F", "Sixth", 30, "Last.fm: similar to Fifth"),
        ])
        for size in ShareSize.allCases {
            var o = ShareOptions(); o.size = size
            if let png = ShareRenderer.png(card: snapPath, options: o, identity: ShareIdentity(name: "someone", showsFooter: false), images: [:], scale: 1) {
                try? png.write(to: URL(fileURLWithPath: folder).appending(path: "path-\(size.rawValue).png"))
            }
        }
        let snapTreeNodes: [RabbitHoleNode] = {
            var nodes = [snapRH("Artist A", "The Starting Song", 120, nil), snapRH("Artist B", "Next Step Along", 47, "Last.fm: similar to The Starting Song"), snapRH("Artist C", "A Third Track With A Rather Long Title", 9, "x"), snapRH("Artist D", "Fourth", 63, "x"), snapRH("Artist E", "Fifth", 12, "x"), snapRH("Artist F", "Sixth", 30, "x")]
            nodes[0].candidates = [nodes[1].track, snapRH("Artist G", "Offered Not Taken", 5, nil).track, snapRH("Artist H", "Another Offer", 8, nil).track]
            nodes[1].candidates = [snapRH("Artist I", "A Different Way", 4, nil).track, nodes[2].track, snapRH("Artist J", "Sideways", 2, nil).track]
            nodes[2].candidates = [snapRH("Artist K", "Not This One", 2, nil).track, nodes[3].track]
            nodes[4].candidates = [snapRH("Artist L", "Other Fifth", 6, nil).track, nodes[5].track]
            return nodes.enumerated().map { index, node in
                var n = node
                n = RabbitHoleNode(id: node.id, track: node.track, parentID: index == 0 ? nil : nodes[index - 1].id, candidates: node.candidates, childIDs: [])
                return n
            }
        }()
        let snapTree = ShareCards.rabbitHole(path: snapTreeNodes)
        for size in ShareSize.allCases {
            var o = ShareOptions(); o.size = size; o.layout = .tree
            if let png = ShareRenderer.png(card: snapTree, options: o, identity: ShareIdentity(name: "someone", showsFooter: false), images: [:], scale: 1) {
                try? png.write(to: URL(fileURLWithPath: folder).appending(path: "path-tree-\(size.rawValue).png"))
            }
        }
        // A mock of an Overview "Listening recap" (made-up numbers), drawn with the existing recap layout.
        let mockRecap = ShareCard(
            title: "Year to date", period: "", measure: "", rows: [], valueLabel: "Plays", hasMovement: false, kindID: "overview.recap",
            profile: ShareProfile(
                kind: "Listening recap", subtitle: "", heroImageURL: nil,
                stats: [ShareStat(label: "Scrobbles", value: "12,345"), ShareStat(label: "Artists", value: "612"), ShareStat(label: "Albums", value: "1,043"), ShareStat(label: "Tracks", value: "3,870"),
                        ShareStat(label: "vs Jan 1, 2025 – Oct 17, 2025", value: "+8.4%"), ShareStat(label: "New artists", value: "87"), ShareStat(label: "Per day", value: "42.1"), ShareStat(label: "Current streak", value: "23 days")],
                chips: [],
                highlights: [
                    ShareHighlight(role: "Top Artist", title: "Artist A", subtitle: nil, value: "931 plays", imageURL: "file:///art/Artist A.jpg"),
                    ShareHighlight(role: "Top Album", title: "Album A", subtitle: "Artist A", value: "236 plays", imageURL: "file:///art/Album A.jpg"),
                    ShareHighlight(role: "Top Track", title: "A Song With A Rather Long Title", subtitle: "Artist B", value: "47 plays", imageURL: "file:///art/Song With A Rather Long Title.jpg"),
                ],
                trend: []
            )
        )
        for size in ShareSize.allCases {
            var o = ShareOptions(); o.size = size
            if let png = ShareRenderer.png(card: mockRecap, options: o, identity: ShareIdentity(name: "someone", showsFooter: true), images: recapArt, scale: 1) {
                try? png.write(to: URL(fileURLWithPath: folder).appending(path: "mock-overview-recap-\(size.rawValue).png"))
            }
        }
        // The collage with its caption: what and when, the name and the tag.
        let collageItems = (1...9).map { CollageItem(id: "c\($0)", name: "Album \($0)", artist: "Artist \($0)", album: nil, metricValue: 100 - $0, imageURL: nil, periodLabel: nil) }
        let collageFooter = CollageFooter(
            details: CollageCaption.make(source: .top, entity: .album, metric: .scrobbles, period: .year, rangeLabel: "Last 365 days").text(date: Date()),
            identity: ShareIdentity(name: "someone", showsFooter: true, avatar: sampleAvatar())
        )
        for (name, grid) in [("collage-3x3", CollageGrid.three), ("collage-wide", CollageGrid.widescreen)] {
            if let png = CollageGeneratorView.renderPNG(items: collageItems, images: [:], grid: grid, metric: .scrobbles, showTitles: true, showStats: true, showPeriod: false, footer: collageFooter) {
                try? png.write(to: URL(fileURLWithPath: folder).appending(path: "\(name).png"))
            }
        }
    }
}
#endif
