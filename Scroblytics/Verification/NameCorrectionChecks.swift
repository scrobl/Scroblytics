import Foundation
import SwiftData

#if DEBUG
/// `SCROBLYTICS_NAMECORRECTION_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): the person's capitalization and spacing
/// corrections to artist, album and track names, on made-up plays. Keys and validation, the book's lookups, the pass every screen's plays go
/// through (`QueryIdentity.canonicalizingArtists`), Top Charts' ranking, the history cache dropping its copy when the corrections change,
/// the store, and the backup record. Exits 0 on success.
enum NameCorrectionChecks {
    /// `SCROBLYTICS_NAMECORRECTION_REAL="Artist|Album|Corrected album"` (with `SCROBLYTICS_STORE_PATH` on a COPY of a real library and
    /// `SCROBLYTICS_OFFLINE=1`): the oracle comparison. Top Charts (albums, tracks, artists) and the query plays are computed with no
    /// corrections and with that one album correction; everything must be the same except the corrected name: the same number of rows,
    /// the same plays, the same ranks, the same total, and the corrected album shown under the new spelling. Reads only.
    @MainActor
    static func runRealIfRequested(container: ModelContainer) {
        guard let spec = ProcessInfo.processInfo.environment["SCROBLYTICS_NAMECORRECTION_REAL"] else { return }
        HeadlessTask.run("namecorrection-real") {
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            let parts = spec.components(separatedBy: "|")
            guard parts.count == 3 else { print("FAIL  expected Artist|Album|Corrected album"); HeadlessTask.finish(1) }
            let (artist, album, display) = (parts[0], parts[1], parts[2])
            let raw = try await ScrobbleHistoryLoader(modelContainer: container).load().snapshots
            let range = DateRange(from: .distantPast, to: Date())
            func rankings(_ entity: TopChartsEntity) -> [TopChartEntry] {
                TopChartsEngine.fetchRankings(scrobbles: raw, entity: entity, range: range, limit: Int.max, includePeak: false)
            }
            NameCorrections.install([])
            let before: [TopChartsEntity: [TopChartEntry]] = [.album: rankings(.album), .track: rankings(.track), .artist: rankings(.artist)]
            let queryBefore = QueryIdentity.canonicalizingArtists(raw)
            let matching = raw.filter { NameKeys.same($0.artistName, artist) && NameKeys.same($0.albumName, album) }
            print("      (\(raw.count) plays; \(matching.count) under that album; spellings: \(Set(matching.map(\.albumName)).sorted()))")
            check("the album exists in this library", !matching.isEmpty)
            NameCorrections.install([NameCorrectionSnapshot(
                key: NameKeys.album(artist: artist, album: album), kind: .album, artistKey: NameKeys.fold(artist), nameKey: NameKeys.fold(album),
                artist: artist, original: album, display: display, status: .corrected
            )])
            let after: [TopChartsEntity: [TopChartEntry]] = [.album: rankings(.album), .track: rankings(.track), .artist: rankings(.artist)]
            for entity in [TopChartsEntity.album, .track, .artist] {
                let b = before[entity] ?? [], a = after[entity] ?? []
                check("\(entity): same number of rows", a.count == b.count, "\(a.count) vs \(b.count)")
                check("\(entity): same total plays", a.map(\.playcount).reduce(0, +) == b.map(\.playcount).reduce(0, +))
                let sameShape = zip(a, b).allSatisfy { $0.playcount == $1.playcount && $0.rank == $1.rank }
                check("\(entity): the same plays and ranks, row by row", sameShape)
                let renamed = zip(a, b).filter { $0.name != $1.name }.count
                check("\(entity): rows renamed = \(entity == .album ? "the corrected album only" : "none")", renamed == (entity == .album ? 1 : 0), "\(renamed)")
            }
            let corrected = (after[.album] ?? []).filter { NameKeys.same($0.name, display) && NameKeys.same($0.artist ?? "", artist) }
            check("the album is listed once, under the corrected spelling", corrected.count == 1 && corrected.first?.name == display, "\(corrected.map(\.name))")
            check("…with the plays Top Charts had for it", corrected.first?.playcount == (before[.album] ?? []).first { NameKeys.same($0.name, album) && NameKeys.same($0.artist ?? "", artist) }?.playcount)
            let queryAfter = QueryIdentity.canonicalizingArtists(raw)
            check("the query plays: same count, same times", queryAfter.count == queryBefore.count && zip(queryAfter, queryBefore).allSatisfy { $0.playedAt == $1.playedAt })
            let changed = zip(queryAfter, queryBefore).filter { $0.albumName != $1.albumName || $0.trackName != $1.trackName || $0.artistName != $1.artistName }
            check("the query plays: only that album's plays changed, and only their album name", changed.allSatisfy { NameKeys.same($1.albumName, album) && $0.albumName == display && $0.trackName == $1.trackName && $0.artistName == $1.artistName }, "\(changed.count) changed")
            check("every play under the album was changed (or already had the spelling)", changed.count + matching.filter { $0.albumName == display }.count == matching.count, "\(changed.count)")
            // The detail page statistics, against the real rows.
            let context = container.mainContext
            let range2 = DateRange(from: .distantPast, to: Date())
            let stats = try EntityStatsEngine.fetchAlbumStats(context: context, artist: artist, album: display, range: range2)
            check("the album page opened by the corrected name counts every play of the album", stats.plays == matching.count, "\(stats.plays) vs \(matching.count)")
            NameCorrections.install([])
            HeadlessTask.finish(failures)
        }
    }

    /// `SCROBLYTICS_NAMECORRECTION_FINDER=<N>` (with `SCROBLYTICS_STORE_PATH` on a COPY of a real library and `SCROBLYTICS_OFFLINE=1`): runs the
    /// finder over that library and prints how many names it found by kind and reason, how long it took, and the first N findings.
    @MainActor
    static func runFinderIfRequested(container: ModelContainer) {
        guard let raw = ProcessInfo.processInfo.environment["SCROBLYTICS_NAMECORRECTION_FINDER"], let count = Int(raw) else { return }
        HeadlessTask.run("namecorrection-finder") {
            let plays = try await ScrobbleHistoryLoader(modelContainer: container).load().snapshots
            let started = Date()
            let findings = NameCorrectionFinder.find(plays: plays, handled: [])
            print("FINDER \(plays.count) plays, \(findings.count) findings in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
            for kind in NameCorrectionKind.allCases {
                let row = NameCorrectionFinder.Reason.allCases.map { reason in "\(reason.label) \(findings.filter { $0.kind == kind && $0.reason == reason }.count)" }
                print("  \(kind.rawValue): \(row.joined(separator: ", "))")
            }
            for finding in findings.prefix(count) {
                print("  [\(finding.kind.rawValue)/\(finding.reason.rawValue)] \(finding.spellings.map { "\($0.name) (\($0.plays))" }.joined(separator: " | ")) -> \(finding.suggestion)\(finding.kind == .artist ? "" : "  by \(finding.artist)")")
            }
            HeadlessTask.finish(0)
        }
    }

    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_NAMECORRECTION_CHECK"] != nil else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            let savedBook = NameCorrections.current
            defer { NameCorrections.install([]); _ = savedBook }

            // MARK: Keys and validation
            check("fold ignores case and collapses spacing", NameKeys.fold("  Album   ONE ") == "album one")
            check("fold keeps punctuation and accents", NameKeys.fold("Café, Noir!") == "café, noir!")
            check("tidy trims and collapses spacing but keeps capitals", NameKeys.tidy("  Album   One ") == "Album One")
            check("an album key keeps its edition words", NameKeys.album(artist: "Artist A", album: "Album One") != NameKeys.album(artist: "Artist A", album: "Album One (Deluxe Edition)"))
            check("album keys ignore case and spacing", NameKeys.album(artist: "ARTIST a", album: "album  one") == NameKeys.album(artist: "Artist A", album: "Album One"))
            check("kinds never share a key", Set([NameKeys.artist("x"), NameKeys.album(artist: "x", album: "x"), NameKeys.track(artist: "x", title: "x")]).count == 3)
            check("a case change is accepted", NameCorrectionRules.validate(original: "AlbumOne", proposed: "Albumone") == .ok("Albumone"))
            check("spacing is tidied", NameCorrectionRules.validate(original: "Album One", proposed: "  Album   One ") == .unchanged)
            check("tidying a name's spacing IS a change when the original has extra spaces", NameCorrectionRules.validate(original: "Padded  Title ", proposed: "Padded Title") == .ok("Padded Title"))
            check("a doubled space is a change to save", NameCorrectionRules.validate(original: "Album  One", proposed: "Album One") == .ok("Album One"))
            check("typing the same name is no change", NameCorrectionRules.validate(original: "Album One", proposed: "Album One") == .unchanged)
            check("a spelling change is refused", { if case .rejected = NameCorrectionRules.validate(original: "Midnight", proposed: "Mid Night") { return true } else { return false } }())
            check("a different word is refused", { if case .rejected = NameCorrectionRules.validate(original: "Album One", proposed: "Album Two") { return true } else { return false } }())
            check("an empty name is refused", { if case .rejected = NameCorrectionRules.validate(original: "Album One", proposed: "   ") { return true } else { return false } }())

            // MARK: The book
            func row(_ kind: NameCorrectionKind, artist: String, original: String, display: String?, status: NameCorrectionStatus = .corrected) -> NameCorrectionSnapshot {
                let artistKey = NameKeys.fold(artist)
                let nameKey = kind == .artist ? artistKey : NameKeys.fold(original)
                let key: String
                switch kind {
                case .artist: key = NameKeys.artist(artist)
                case .album: key = NameKeys.album(artist: artist, album: original)
                case .track: key = NameKeys.track(artist: artist, title: original)
                }
                return NameCorrectionSnapshot(key: key, kind: kind, artistKey: artistKey, nameKey: nameKey, artist: artist, original: original, display: display, status: status)
            }
            let empty = NameCorrectionBook()
            check("an empty book corrects nothing", empty.isEmpty && empty.artist("Artist A") == nil && empty.album(artist: "Artist A", album: "AlbumOne") == nil && empty.track(artist: "Artist A", title: "x") == nil)
            let book = NameCorrectionBook(rows: [
                row(.album, artist: "Artist A", original: "AlbumOne", display: "Albumone"),
                row(.track, artist: "Artist A", original: "Song TWO", display: "Song Two"),
                row(.artist, artist: "ARTIST B", original: "ARTIST B", display: "Artist B"),
                row(.album, artist: "", original: "SHARED", display: "Shared"),
                row(.track, artist: "Artist A", original: "Reviewed", display: nil, status: .looksRight),
            ], version: 1)
            check("an album correction applies to every spelling of that name by that artist", book.album(artist: "Artist A", album: "AlbumOne") == "Albumone" && book.album(artist: "artist a", album: "albumone") == "Albumone")
            check("an album correction does not reach another artist's album of that name", book.album(artist: "Artist Z", album: "AlbumOne") == nil)
            check("an edition name is a different album", book.album(artist: "Artist A", album: "AlbumOne (Deluxe Edition)") == nil)
            check("a collab credit naming the artist matches the album correction", book.album(artist: "Artist A feat. Artist C", album: "AlbumOne") == "Albumone")
            check("a correction with no artist applies to every artist", book.album(artist: "Anyone", album: "shared") == "Shared")
            check("a track correction is found by artist and title", book.track(artist: "artist a", title: "SONG two") == "Song Two" && book.track(artist: "Artist Z", title: "Song TWO") == nil)
            check("a 'looks right' mark corrects nothing", book.track(artist: "Artist A", title: "Reviewed") == nil)
            check("an artist correction is found by any spelling", book.artist("artist b") == "Artist B")

            // MARK: The pass every screen's plays go through
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            var clock = 0
            func play(_ artist: String, _ album: String, _ track: String) -> ScrobbleSnapshot {
                clock += 1
                return ScrobbleSnapshot(artistName: artist, albumName: album, trackName: track, imageURL: nil, playedAt: t0.addingTimeInterval(Double(clock) * 60))
            }
            var plays: [ScrobbleSnapshot] = []
            for _ in 0..<3 { plays.append(play("Artist A", "AlbumOne", "Song one")) }
            for _ in 0..<2 { plays.append(play("Artist A", "Albumone", "Song TWO")) }
            plays.append(play("Artist A feat. Artist C", "AlbumOne", "Song Three"))
            plays.append(play("Artist A", "AlbumOne (Deluxe Edition)", "Bonus"))
            for _ in 0..<3 { plays.append(play("ARTIST B", "Other", "Tune")) }
            for _ in 0..<2 { plays.append(play("Artist b", "Other", "Tune")) }
            plays.append(play("Artist D", "SHARED", "Tune"))

            let plain = QueryIdentity.canonicalizingArtists(plays, book: empty)
            check("with no corrections the plays are exactly what the artist rule alone gives", plain.map(\.albumName) == plays.map(\.albumName) && plain.map(\.trackName) == plays.map(\.trackName))
            let fixed = QueryIdentity.canonicalizingArtists(plays, book: book)
            check("the two album spellings become one", Set(fixed.filter { $0.artistName == "Artist A" && $0.albumName.lowercased() == "albumone" }.map(\.albumName)) == ["Albumone"])
            check("the collab-credited play is corrected too", fixed[5].albumName == "Albumone")
            check("the edition keeps its own name", fixed[6].albumName == "AlbumOne (Deluxe Edition)")
            check("the track correction applies to every play of that title", fixed.filter { $0.trackName.lowercased() == "song two" }.allSatisfy { $0.trackName == "Song Two" })
            check("an untouched track keeps its spelling", fixed[0].trackName == "Song one")
            check("the artist correction beats the most-played spelling (ARTIST B has 3 plays, Artist b 2)", fixed.filter { $0.albumName == "Other" }.allSatisfy { $0.artistName == "Artist B" })
            check("a no-artist album correction applies to Artist D's album", fixed.last?.albumName == "Shared")
            check("only names changed: same plays, same times", fixed.map(\.playedAt) == plays.map(\.playedAt) && fixed.count == plays.count)

            // MARK: Top Charts
            NameCorrections.install([row(.album, artist: "Artist A", original: "AlbumOne", display: "Albumone")])
            let range = DateRange(from: t0, to: t0.addingTimeInterval(86_400))
            let albums = TopChartsEngine.fetchRankings(scrobbles: plays, entity: .album, range: range, limit: 50, includePeak: false)
            let albumLike = albums.filter { $0.name.lowercased() == "albumone" }
            check("Top Charts shows the two spellings as one album", albumLike.count == 1 && albumLike[0].name == "Albumone", "\(albums.map(\.name))")
            // Top Charts already counts an edition's plays under its plain album (3 + 2 + 1 collab-credited + 1 "(Deluxe Edition)" bonus play).
            check("…with the plays of both spellings added together", albumLike.first?.playcount == 7, "\(albumLike.map(\.playcount))")
            NameCorrections.install([])
            let before = TopChartsEngine.fetchRankings(scrobbles: plays, entity: .album, range: range, limit: 50, includePeak: false)
            // Top Charts already merges spellings of an album that differ only by case, showing the first one it meets; the correction decides which.
            check("resetting the correction shows Last.fm's first-seen spelling again", before.filter { $0.name.lowercased() == "albumone" }.map(\.name) == ["AlbumOne"], "\(before.map(\.name))")

            // MARK: The history cache follows the corrections
            let cachedPlays = plays
            let cache = ScrobbleHistoryCache(
                loader: { _ in (cachedPlays, ScrobbleHistoryCache.Stamp(count: cachedPlays.count, newest: cachedPlays.last?.playedAt)) },
                stampReader: { _ in ScrobbleHistoryCache.Stamp(count: cachedPlays.count, newest: cachedPlays.last?.playedAt) }
            )
            let first = try? await cache.canonicalSnapshots(container: container)
            check("the cache starts with the spellings as Last.fm has them", first?.filter { $0.albumName.lowercased() == "albumone" }.count == 6 && Set((first ?? []).filter { $0.albumName.lowercased() == "albumone" }.map(\.albumName)).count == 2)
            NameCorrections.install([row(.album, artist: "Artist A", original: "AlbumOne", display: "Albumone")])
            let second = try? await cache.canonicalSnapshots(container: container)
            check("saving a correction makes the cache rebuild its copy", Set((second ?? []).filter { $0.albumName.lowercased() == "albumone" }.map(\.albumName)) == ["Albumone"])
            NameCorrections.install([])
            let third = try? await cache.canonicalSnapshots(container: container)
            check("resetting it brings the original spellings back", Set((third ?? []).filter { $0.albumName.lowercased() == "albumone" }.map(\.albumName)).count == 2)

            // MARK: Detail pages find the plays under every spelling (real rows in the scratch database)
            do {
                let context = container.mainContext
                let probe = [
                    Scrobble(artistName: "Artist A", albumName: "AlbumOne", trackName: "Song one", imageURL: nil, playedAt: t0.addingTimeInterval(-90_000), lastConfirmedAt: t0),
                    Scrobble(artistName: "Artist A", albumName: "AlbumOne", trackName: "Song one", imageURL: nil, playedAt: t0.addingTimeInterval(-80_000), lastConfirmedAt: t0),
                    Scrobble(artistName: "Artist A", albumName: "Albumone", trackName: "SONG ONE", imageURL: nil, playedAt: t0.addingTimeInterval(-70_000), lastConfirmedAt: t0),
                ]
                for item in probe { context.insert(item) }
                try context.save()
                let all = DateRange(from: t0.addingTimeInterval(-1_000_000), to: t0)
                let byRaw = try EntityStatsEngine.fetchAlbumStats(context: context, artist: "Artist A", album: "AlbumOne", range: all)
                let byCorrected = try EntityStatsEngine.fetchAlbumStats(context: context, artist: "Artist A", album: "albumone", range: all)
                check("an album page opened by either spelling counts the plays under both (3)", byRaw.plays == 3 && byCorrected.plays == 3, "\(byRaw.plays) / \(byCorrected.plays)")
                let trackStats = try EntityStatsEngine.fetchTrackStats(context: context, artist: "artist a", track: "Song One", range: all)
                check("a track page opened by a corrected title counts every spelling's plays (3)", trackStats.plays == 3, "\(trackStats.plays)")
                let history = try EntityStatsEngine.fetchTrackScrobbleHistory(context: context, artist: "Artist A", track: "song one", range: all)
                check("…and lists them all", history.count == 3, "\(history.count)")
                let scoped = try await TopChartsEngine.fetchScopedRankings(
                    container: container, durationContext: context, entity: .track, artist: "Artist A", album: "Albumone", range: all, compareRange: nil, metric: .scrobbles
                )
                check("an album's track list finds the plays under either album spelling", scoped.map(\.playcount).reduce(0, +) == 3, "\(scoped.map { "\($0.name) \($0.playcount)" })")
                // The Apple Music playlist export finds an album's tracks by the name the chart shows, and sends Last.fm's spelling to Music.
                await ScrobbleHistoryCache.shared.invalidate()
                NameCorrections.install([row(.album, artist: "Artist A", original: "AlbumOne", display: "Albumone")])
                let chart2 = try await TopChartsEngine.fetchRankings(container: container, entity: .album, range: all, limit: 20, includePeak: false)
                let entry = chart2.first { $0.name == "Albumone" }
                check("the chart lists the probe album under the corrected name", entry != nil, "\(chart2.map(\.name))")
                if let entry {
                    let exported = try await AppleMusicPlaylistBuilder.tracks(
                        for: [entry], entity: .album, range: all, metric: .scrobbles, container: container, context: context
                    )
                    check("exporting a corrected album still finds its tracks", exported.count == 1, "\(exported.map(\.track))")
                    check("…and sends Music the spelling Last.fm has", exported.first.map { $0.album == "AlbumOne" || $0.album == "Albumone" } == true && exported.first?.artist == "Artist A")
                }
                NameCorrections.install([])
                await ScrobbleHistoryCache.shared.invalidate()
                for item in probe { context.delete(item) }
                try context.save()
            } catch {
                check("the detail lookups work", false, "\(error)")
            }
            do {
                NameCorrections.install([row(.album, artist: "Artist A", original: "AlbumOne", display: "Albumone"), row(.artist, artist: "ARTIST B", original: "ARTIST B", display: "Artist B")])
                let current = NameCorrections.current
                let album = current.corrected(AlbumIdentity(artist: "Artist A", name: "AlbumOne"))
                check("an album identity made from Last.fm's spelling comes out corrected", album.name == "Albumone" && album.artist == "Artist A")
                check("one made from the corrected spelling stays as it is", current.corrected(AlbumIdentity(artist: "Artist A", name: "Albumone")).name == "Albumone")
                check("an artist identity is corrected", current.corrected(ArtistIdentity(name: "artist b")).name == "Artist B")
                let track = current.corrected(TrackIdentity(artist: "Artist A", name: "x", album: "AlbumOne", scopedAlbum: "AlbumOne"))
                check("a track identity's album labels are corrected", track.album == "Albumone" && track.scopedAlbum == "Albumone")
                NameCorrections.install([])
            }

            // MARK: The finder (made-up names)
            do {
                var found: [ScrobbleSnapshot] = []
                func add(_ artist: String, _ album: String, _ track: String, _ count: Int) { for _ in 0..<count { found.append(play(artist, album, track)) } }
                add("Artist A", "MidNight Garden", "Plain One", 10)
                add("Artist A", "Fine Album", "Plain Two", 5)
                add("Artist A", "Fine Album", "Song TWO", 3)
                add("Artist A", "Fine Album", "Song two", 4)
                add("Artist A", "Fine Album", "Padded  Title ", 2)
                add("Artist A", "LOUD ALBUM NAME", "Plain Three", 3)
                add("Band X", "Fine Album", "Plain Four", 3)
                add("BAND X", "Fine Album", "Plain Four", 2)
                add("ALLCAPS BAND", "Fine Album", "Plain Five", 2)
                add("deadmau5", "Fine Album", "Plain Six", 2)
                add("Artist A", "McDonald Songs", "O'Brien Hits", 2)
                add("Artist A", "iPhone Tunes", "The MacArthur Tapes", 2)
                let findings = NameCorrectionFinder.find(plays: found, handled: [])
                func finding(_ kind: NameCorrectionKind, _ name: String) -> NameCorrectionFinder.Finding? { findings.first { $0.kind == kind && $0.spellings.contains { $0.name == name } } }
                check("an album with a capital inside a word is found, with the suggestion", finding(.album, "MidNight Garden")?.reason == .oddCapitals && finding(.album, "MidNight Garden")?.suggestion == "Midnight Garden", "\(findings.map { "\($0.kind) \($0.original) -> \($0.suggestion) (\($0.reason))" })")
                let variants = finding(.track, "Song TWO")
                check("two spellings of a track are one finding, suggesting the most played", variants?.reason == .variants && variants?.suggestion == "Song two" && variants?.spellings.count == 2 && variants?.plays == 7)
                check("…and it merges spellings, so it must be saved even when it equals the most-used one", variants?.mergesSpellings == true)
                check("a doubled and trailing space is found", finding(.track, "Padded  Title ")?.reason == .spacing && finding(.track, "Padded  Title ")?.suggestion == "Padded Title")
                check("an all-capitals album is found and title-cased", finding(.album, "LOUD ALBUM NAME")?.reason == .allCaps && finding(.album, "LOUD ALBUM NAME")?.suggestion == "Loud Album Name")
                check("two spellings of an artist are found", finding(.artist, "Band X")?.reason == .variants && finding(.artist, "Band X")?.spellings.count == 2)
                check("an artist written in capitals or styled is not flagged (their styling is usually meant)", finding(.artist, "ALLCAPS BAND") == nil && finding(.artist, "deadmau5") == nil)
                check("Mc, O' and brand shapes are not flagged", finding(.album, "McDonald Songs") == nil && finding(.track, "O'Brien Hits") == nil && finding(.album, "iPhone Tunes") == nil && finding(.track, "The MacArthur Tapes") == nil)
                check("clean names are not flagged", finding(.album, "Fine Album") == nil && finding(.track, "Plain Two") == nil)
                check("every suggestion is the same name apart from capitalization and spacing", findings.allSatisfy { f in NameKeys.fold(f.suggestion) == NameKeys.fold(f.original) })
                check("findings come in order: spellings first, then spacing, odd capitals, ALL CAPS", findings.map(\.reason.rank) == findings.map(\.reason.rank).sorted())
                let handled = Set([finding(.album, "MidNight Garden")?.key ?? ""])
                check("a name already corrected or marked right is not listed again", NameCorrectionFinder.find(plays: found, handled: handled).allSatisfy { $0.key != finding(.album, "MidNight Garden")?.key })
                check("Title Case keeps small words down and Roman numerals up", NameCorrectionFinder.titleCased("THE LORD OF THE RINGS PART II") == "The Lord of the Rings Part II", NameCorrectionFinder.titleCased("THE LORD OF THE RINGS PART II"))
                check("odd capitals are lower-cased after the first letter only", NameCorrectionFinder.fixOddCapitals("MidNight And MoonLight") == "Midnight And Moonlight")
                check("dotted acronyms are kept as written when title-casing", NameCorrectionFinder.titleCased("A.M. RADIO") == "A.M. Radio" && NameCorrectionFinder.titleCased("U.F.O.F.") == "U.F.O.F.", NameCorrectionFinder.titleCased("A.M. RADIO"))
                check("an ALL CAPS name whose title case is the same name is not listed", NameCorrectionFinder.find(plays: [play("Artist A", "U.F.O.F.", "Plain")] + [play("Artist A", "U.F.O.F.", "Plain")], handled: []).allSatisfy { $0.original != "U.F.O.F." })
                check("ALL CAPS needs four letters", !NameCorrectionFinder.isAllCaps("R.E.M.") && NameCorrectionFinder.isAllCaps("LOUD"))
            }

            // MARK: The store and the backup record
            let store = NameCorrectionStore(modelContainer: container)
            do {
                for old in try await store.all() { try await store.reset(kind: old.kind, artist: old.artist, original: old.original) }
                try await store.set(kind: .album, artist: "Artist A", original: "AlbumOne", display: "  Albumone ")
                try await store.set(kind: .artist, artist: "ARTIST B", original: "ARTIST B", display: "Artist B")
                try await store.set(kind: .track, artist: "Artist A", original: "Song TWO", display: "Song Two")
                var saved = try await store.all()
                check("three corrections are saved, with tidied spacing", saved.count == 3 && saved.contains { $0.display == "Albumone" })
                try await store.set(kind: .album, artist: "Artist A", original: "AlbumOne", display: "ALBUMONE")
                saved = try await store.all()
                check("saving again for the same name replaces it", saved.count == 3 && saved.contains { $0.display == "ALBUMONE" } && !saved.contains { $0.display == "Albumone" })
                var refused = false
                do { try await store.set(kind: .album, artist: "Artist A", original: "AlbumOne", display: "Album One") } catch { refused = true }
                let afterRefusal = try await store.all()
                check("a spelling change is refused by the store and nothing changes", refused && afterRefusal.count == 3)
                // A spacing-only correction (what the finder's "Extra spaces" rows apply) is saved, not dropped as "no change".
                try await store.set(kind: .track, artist: "Artist A", original: "Padded  Title ", display: "Padded Title")
                let afterSpacing = try await store.all()
                check("an extra-spaces correction is saved", afterSpacing.contains { $0.kind == .track && $0.display == "Padded Title" }, "\(afterSpacing.map { "\($0.original)=>\($0.display ?? "-")" })")
                let spaced = QueryIdentity.canonicalizingArtists([play("Artist A", "Fine", "Padded  Title ")], book: NameCorrectionBook(rows: afterSpacing))
                check("…and the plays then show the tidied name", spaced.first?.trackName == "Padded Title", "\(spaced.first?.trackName ?? "")")
                try await store.reset(kind: .track, artist: "Artist A", original: "Padded  Title ")
                try await store.set(kind: .album, artist: "Artist A", original: "AlbumOne", display: "AlbumOne")
                let afterOwnSpelling = try await store.all()
                check("typing Last.fm's own spelling back removes the correction", afterOwnSpelling.count == 2)
                try await store.set(kind: .album, artist: "Artist A", original: "AlbumOne", display: "AlbumOne", keepIfSame: true)
                let kept = try await store.all()
                check("…unless other spellings exist, where it is kept to count them together", kept.count == 3 && kept.contains { $0.kind == .album && $0.display == "AlbumOne" })
                try await store.reset(kind: .album, artist: "Artist A", original: "AlbumOne")
                try await store.markLooksRight(kind: .track, artist: "Artist A", original: "ANOTHER SONG")
                let marked = try await store.all()
                check("'Looks right' is saved as a mark with no spelling", marked.contains { $0.kind == .track && $0.status == .looksRight && $0.display == nil })
                check("a mark corrects nothing", NameCorrectionBook(rows: marked).track(artist: "Artist A", title: "ANOTHER SONG") == nil)
                try await store.markLooksRight(kind: .track, artist: "Artist A", original: "Song TWO")
                let stillCorrected = try await store.all()
                check("marking a corrected name leaves its correction alone", stillCorrected.contains { $0.kind == .track && $0.original == "Song TWO" && $0.status == .corrected })
                try await store.reset(kind: .track, artist: "Artist A", original: "ANOTHER SONG")
                let unmarked = try await store.all()
                check("putting a name back removes the mark", unmarked.count == 2, "\(unmarked.count)")
                try await store.reset(kind: .track, artist: "Artist A", original: "Song TWO")
                let afterReset = try await store.all()
                check("reset removes a correction", afterReset.map(\.kind) == [.artist])

                // Backup: a record per correction, restored in place; an archive without the list leaves the current ones alone.
                try await store.set(kind: .album, artist: "Artist A", original: "AlbumOne", display: "Albumone")
                let context = container.mainContext
                let document = try NativeBackupEngine.makeDocument(context: context)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let archive = try decoder.decode(NativeBackupFormat.Archive.self, from: document.data)
                check("a backup carries the corrections", archive.nameCorrections?.count == 2, "\(archive.nameCorrections?.count ?? -1)")
                for item in try context.fetch(FetchDescriptor<NameCorrection>()) { context.delete(item) }
                try context.save()
                try NativeBackupEngine.restoreNameCorrections(nil, context: context)
                check("an older archive without the list leaves the current corrections alone", (try context.fetch(FetchDescriptor<NameCorrection>())).isEmpty)
                try NativeBackupEngine.restoreNameCorrections(archive.nameCorrections, context: context)
                let restored = try context.fetch(FetchDescriptor<NameCorrection>()).compactMap(NameCorrectionSnapshot.init(row:))
                check("restoring puts the corrections back", restored.count == 2 && restored.contains { $0.kind == .album && $0.display == "Albumone" && $0.original == "AlbumOne" })
                check("restored corrections work as lookups", NameCorrectionBook(rows: restored).album(artist: "artist a", album: "ALBUMONE") == "Albumone")
                for item in try context.fetch(FetchDescriptor<NameCorrection>()) { context.delete(item) }
                try context.save()
            } catch {
                check("the store works", false, "\(error)")
            }
            NameCorrections.install([])
            HeadlessTask.finish(failures)
        }
    }
}
#endif
