#if DEBUG
import Foundation
import SwiftData

/// Checks for the Apple Music details (date added, genre, tempo) on made-up data, and a read-only run on the real library.
/// `SCROBLYTICS_MUSICDETAILS_CHECK=1` runs the checks. `SCROBLYTICS_MUSICDETAILS_DUMP=<file>` (a store copy on `SCROBLYTICS_STORE_PATH`
/// and the running Music) reads the library, reports how long it took and how the real history matched, and writes every row so
/// they can be compared with an independent read of Music.
enum AppleMusicDetailsChecks {
    typealias Index = AppleMusicDetailsIndex

    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["SCROBLYTICS_MUSICDETAILS_DUMP"] {
            HeadlessTask.run("musicdetails-dump") { try await dump(container: container, path: path) }
            return
        }
        if let path = environment["SCROBLYTICS_MUSICDETAILS_POLICYDUMP"] {
            HeadlessTask.run("musicdetails-policydump") { try await policyDump(container: container, path: path) }
            return
        }
        if let path = environment["SCROBLYTICS_MUSICDETAILS_QUERYDUMP"] {
            HeadlessTask.run("musicdetails-querydump") { try await queryDump(container: container, path: path) }
            return
        }
        guard environment["SCROBLYTICS_MUSICDETAILS_CHECK"] != nil else { return }
        HeadlessTask.run("musicdetails-check") {
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            matchChecks(check)
            valueChecks(check)
            tempoChecks(check)
            storageChecks(check)
            crossCheck(check)
            HeadlessTask.finish(failures)
        }
    }

    // MARK: Made-up data

    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private static func day(_ n: Int) -> Date { t0.addingTimeInterval(Double(n) * 86_400) }

    private static func row(
        _ artist: String, _ title: String, album: String = "Album", albumArtist: String = "", genre: String = "", bpm: Int = 0, added: Int? = nil
    ) -> AppleMusicDetailRow {
        AppleMusicDetailRow(artist: artist, title: title, album: album, albumArtist: albumArtist, genre: genre, bpm: bpm, dateAdded: added.map(day))
    }

    private static func play(_ artist: String, _ track: String, _ n: Int = 1) -> [ScrobbleSnapshot] {
        (0..<n).map { ScrobbleSnapshot(artistName: artist, albumName: "Album", trackName: track, imageURL: nil, playedAt: t0.addingTimeInterval(Double($0))) }
    }

    private static func fuzzyEqual(_ a: (String, String), _ b: (String, String)) -> Bool {
        LibraryGapsEngine.key(artist: a.0, track: a.1) == LibraryGapsEngine.key(artist: b.0, track: b.1)
    }

    // MARK: Matching

    private static func matchChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }

        let exact = Index(rows: [row("Artist A", "Song One", genre: "Rock", added: 5)], scrobbles: play("artist a", "  song   one "))
        check("the same artist and title, ignoring capitals and spacing, is a match", exact.match(artist: "artist a", track: "  song   one ") == .matched(rows: [0], viaSpelling: false))
        check("a different artist with the same title is not", exact.match(artist: "Artist B", track: "Song One") == .none)
        check("an unknown song is not matched", exact.match(artist: "Artist A", track: "Another") == .none)

        // Spellings: the prerequisite is that the rule treats these titles as the same song at all.
        check("(prerequisite) a '(feat. …)' credit is the same song to the app's matching", fuzzyEqual(("A", "Song"), ("A", "Song (feat. Guest)")))
        let variant = Index(rows: [row("A", "Song", added: 3)], scrobbles: play("A", "Song (feat. Guest)"))
        check("a library title and a differently written Last.fm title pair up when nothing else could be the partner",
              variant.match(artist: "A", track: "Song (feat. Guest)") == .matched(rows: [0], viaSpelling: true))

        // Both Last.fm spellings left over: the library song can't be given to both, so it is given to neither.
        let twoLastfm = Index(rows: [row("A", "Song")], scrobbles: play("A", "Song (feat. X)") + play("A", "Song (feat. Y)"))
        if case .ambiguous(let candidates) = twoLastfm.match(artist: "A", track: "Song (feat. X)") {
            check("with two Last.fm spellings left over for one library title, neither gets it and the library title is named", candidates == ["A — Song"], "\(candidates)")
        } else {
            check("with two Last.fm spellings left over for one library title, neither gets it and the library title is named", false)
        }

        // Several library titles could be the partner.
        let twoLibrary = Index(rows: [row("A", "Song (feat. X)"), row("A", "Song (feat. Y)")], scrobbles: play("A", "Song (feat. Z)"))
        if case .ambiguous(let candidates) = twoLibrary.match(artist: "A", track: "Song (feat. Z)") {
            check("several library titles that could be the partner make it ambiguous, and all are named", Set(candidates) == ["A — Song (feat. X)", "A — Song (feat. Y)"], "\(candidates)")
        } else {
            check("several library titles that could be the partner make it ambiguous, and all are named", false)
        }

        // A library title already taken by an identical Last.fm title is never lent to another spelling.
        let taken = Index(rows: [row("A", "Song", genre: "Rock")], scrobbles: play("A", "Song") + play("A", "Song (feat. X)"))
        check("a library title belonging to an identical Last.fm title is not lent to a different spelling", taken.match(artist: "A", track: "Song (feat. X)") == .none)
        check("…and the identical one still has it", taken.match(artist: "A", track: "Song") == .matched(rows: [0], viaSpelling: false))
        check("…and that is not reported as ambiguous", taken.unmatched().isEmpty)

        // The list of what was skipped
        let both = Index(
            rows: [row("A", "Song (feat. X)"), row("A", "Song (feat. Y)"), row("B", "Other (feat. P)"), row("B", "Other (feat. Q)")],
            scrobbles: play("A", "Song (feat. Z)", 5) + play("B", "Other (feat. R)", 9) + play("C", "Fine")
        )
        let skipped = both.unmatched()
        check("the skipped list names each ambiguous Last.fm song with its plays and candidates, most played first",
              skipped.map(\.track) == ["Other (feat. R)", "Song (feat. Z)"] && skipped.map(\.plays) == [9, 5] && skipped[0].candidates.count == 2, "\(skipped)")
        check("a song that simply isn't in the library is not on the list", !skipped.contains { $0.artist == "C" })

        // Albums and artists
        let albums = Index(rows: [
            row("Artist A", "T1", album: "First Album (Deluxe Edition)", albumArtist: "Artist A", added: 1),
            row("Artist A feat. B", "T2", album: "First Album", albumArtist: "Artist A", added: 2),
            row("Artist C", "T3", album: "Compilation", albumArtist: "Various Artists", added: 3),
        ], scrobbles: [])
        check("an album matches by album artist and name, ignoring an edition suffix, across tracks with other credits", albums.rows(artist: "Artist A", album: "First Album").count == 2)
        check("an album matches under its track artist too, and under the album artist", albums.rows(artist: "Artist C", album: "Compilation").count == 1 && albums.rows(artist: "Various Artists", album: "Compilation").count == 1)
        check("a different album by the artist is not matched", albums.rows(artist: "Artist A", album: "Other").isEmpty)
        let scripts = Index(rows: [
            row("Artist J", "T1", album: "テスト", added: 1), row("Artist J", "T2", album: "別のアルバム", added: 2), row("Artist O", "T3", album: "Ö", added: 3),
        ], scrobbles: [])
        check("an album whose title the usual rule reduces to nothing (another script, accents only) still matches itself", scripts.rows(artist: "Artist J", album: "テスト").count == 1 && scripts.rows(artist: "Artist O", album: "Ö").count == 1)
        check("…and two different such albums are not mistaken for one another", scripts.rows(artist: "Artist J", album: "別のアルバム").count == 1 && scripts.rows(artist: "Artist J", album: "テスト").first?.title == "T1")
        check("an artist matches the songs credited to them or on their albums", albums.rows(artist: "Artist A").count == 2 && albums.rows(artist: "Nobody").isEmpty)
    }

    // MARK: Values

    private static func valueChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let copies = [row("A", "S", genre: "Rock", added: 9), row("A", "S", genre: "Rock", added: 4), row("A", "S", genre: "Pop", added: 6), row("A", "S", added: nil)]
        check("date added is the earliest across a song's copies, ignoring a copy with no date", Index.earliestAdded(copies) == day(4))
        check("no dates at all gives none", Index.earliestAdded([row("A", "S")]) == nil)
        check("genre is the one most copies carry", Index.commonGenre(copies) == "Rock")
        check("a tie goes to the genre on the earliest-added copy", Index.commonGenre([row("A", "S", genre: "Pop", added: 2), row("A", "S", genre: "Rock", added: 8)]) == "Pop")
        check("a tie with no dates goes alphabetically, and empty genres never count", Index.commonGenre([row("A", "S", genre: "Rock"), row("A", "S", genre: "Folk"), row("A", "S")]) == "Folk")
        check("no genre at all gives none", Index.commonGenre([row("A", "S"), row("A", "S")]) == nil)
    }

    // MARK: Tempo

    private static func tempoChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let key = BPMEngine.cacheKey(artist: "A", track: "S")
        check("a single tempo tag is used", Index.tempoByKey([row("A", "S", bpm: 120)])[key] == 120)
        check("copies within 2 BPM of each other give the middle one", Index.tempoByKey([row("A", "S", bpm: 120), row("A", "S", bpm: 121), row("A", "S", bpm: 122)])[key] == 121)
        check("copies that disagree by more than 2 BPM give none, rather than a guess", Index.tempoByKey([row("A", "S", bpm: 120), row("A", "S", bpm: 124)])[key] == nil)
        check("a tag of zero means no tempo", Index.tempoByKey([row("A", "S", bpm: 0)])[key] == nil)
        check("a copy with no tag is ignored when another has one", Index.tempoByKey([row("A", "S", bpm: 0), row("A", "S", bpm: 98)])[key] == 98)
        check("the key is the one tempo uses everywhere, so case and spacing around the names don't matter",
              Index.tempoByKey([row(" a ", " s ", bpm: 100)])[key] == 100)
        check("only identical titles get a tempo: a spelling variant is a different key", Index.tempoByKey([row("A", "S (feat. X)", bpm: 100)])[key] == nil)
    }

    // MARK: Storage

    private static func storageChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let folder = FileManager.default.temporaryDirectory.appending(path: "musicdetails-check-\(UUID().uuidString)", directoryHint: .isDirectory)
        let url = folder.appending(path: "library-details.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        check("with no file there is nothing", AppleMusicDetailsStorage.load(from: url) == nil)
        let file = AppleMusicDetailsFile(readAt: t0, rows: [row("A", "S", album: "Al", albumArtist: "AA", genre: "Rock", bpm: 99, added: 7), row("B", "T")])
        do { try AppleMusicDetailsStorage.save(file, to: url) } catch { check("a read can be saved", false, "\(error)"); return }
        let back = AppleMusicDetailsStorage.load(from: url)
        check("a saved read comes back exactly, dates included", back?.rows == file.rows && back?.readAt == t0)
        let again = AppleMusicDetailsStorage.load(from: url)
        check("asking again gives the same data", again?.rows == file.rows)
        let changed = AppleMusicDetailsFile(readAt: t0.addingTimeInterval(60), rows: [row("C", "U")])
        try? AppleMusicDetailsStorage.save(changed, to: url)
        check("a changed file is read afresh, not served from the earlier copy", AppleMusicDetailsStorage.load(from: url)?.rows.map(\.artist) == ["C"])
        AppleMusicDetailsStorage.delete(at: url)
        check("deleting it leaves nothing", AppleMusicDetailsStorage.load(from: url) == nil)
        check("a file in an unknown format is ignored, not trusted", {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? Data("{\"version\":99,\"readAt\":0,\"rows\":[]}".utf8).write(to: url)
            return AppleMusicDetailsStorage.load(from: url) == nil
        }())
    }

    // MARK: An independent count on generated data

    private static func crossCheck(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        var seed: UInt64 = 20_261_108
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        var rows: [AppleMusicDetailRow] = []
        var scrobbles: [ScrobbleSnapshot] = []
        for i in 0..<3000 {
            let artist = "Artist \(i % 90)", title = "Song \(i)"
            if next(4) > 0 { for _ in 0..<(1 + next(2)) { rows.append(row(artist, title, genre: ["Rock", "Pop", "Folk"][next(3)], bpm: next(3) == 0 ? 0 : 80 + next(80), added: next(900))) } }
            if next(3) > 0 { scrobbles += play(i % 2 == 0 ? artist.uppercased() : artist, i % 3 == 0 ? " \(title) " : title, 1 + next(3)) }
        }
        let started = Date()
        let index = Index(rows: rows, scrobbles: scrobbles)
        let built = Date().timeIntervalSince(started)
        var wrong = 0, checked = 0
        func plain(_ s: String) -> String { s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
        for (a, t) in Set(scrobbles.map { "\($0.artistName)\u{1F}\($0.trackName)" }).map({ $0.components(separatedBy: "\u{1F}") }).map({ ($0[0], $0[1]) }) {
            let expected = rows.indices.filter { plain(rows[$0].artist) == plain(a) && plain(rows[$0].title) == plain(t) }
            if case .matched(let got, _) = index.match(artist: a, track: t) { if got.sorted() != expected { wrong += 1 } } else if !expected.isEmpty { wrong += 1 }
            checked += 1
        }
        check("generated library: every identical-title match equals an independent brute-force match", wrong == 0 && checked > 1000, "wrong \(wrong) of \(checked)")
        check("generated library: building the index for 4,000 library songs and many plays is quick", built < 3, String(format: "%.2f s", built))
    }

    // MARK: When the library is read (live)

    /// Runs the store against the real Music and a scratch folder (private preferences, nothing real touched): turning it on reads; a second
    /// refresh finds nothing changed and doesn't read; a different song count, or an old read, makes it read again.
    @MainActor
    private static func policyDump(container: ModelContainer, path: String) async throws {
        var out: [String] = []
        AppleMusicDetailsStorage.delete()
        let suite = UserDefaults(suiteName: "apple-music-details-policy")!
        suite.removePersistentDomain(forName: "apple-music-details-policy")
        let store = AppleMusicDetailsStore(defaults: suite)
        store.start(container: container)
        func wait() async { for _ in 0..<240 where store.isReading || false { try? await Task.sleep(for: .milliseconds(250)) } }
        func startReading(force: Bool) async -> Double {
            let began = Date()
            store.refresh(force: force)
            try? await Task.sleep(for: .milliseconds(200))
            await wait()
            return Date().timeIntervalSince(began)
        }

        let t1 = await startReading(force: true)   // not enabled yet: must do nothing
        out.append("DISABLED_REFRESH read=\(AppleMusicDetailsStorage.load() != nil) (expect false) \(String(format: "%.1fs", t1))")
        store.setEnabled(true)                      // turning it on reads at once
        try? await Task.sleep(for: .milliseconds(300))
        await wait()
        let first = AppleMusicDetailsStorage.load()
        out.append("ENABLE read=\(first != nil) songs=\(first?.rows.count ?? 0) problem=\(store.problem ?? "none")")
        guard let first else { try out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8); exit(0) }

        let t2 = await startReading(force: false)   // nothing changed: one cheap count, no full read
        let second = AppleMusicDetailsStorage.load()
        out.append(String(format: "UNCHANGED_REFRESH took %.1fs, read again=%@ (expect false)", t2, "\(second?.readAt != first.readAt)"))

        var fewer = first; fewer.rows.removeLast(); fewer.readAt = Date()
        try AppleMusicDetailsStorage.save(fewer)    // a song "was added" since the saved read
        let t3 = await startReading(force: false)
        let third = AppleMusicDetailsStorage.load()
        out.append(String(format: "COUNT_CHANGED took %.1fs, read again=%@ (expect true), songs now %d (was %d)", t3, "\(third?.readAt != fewer.readAt)", third?.rows.count ?? 0, fewer.rows.count))

        var old = third ?? first; old.readAt = Date().addingTimeInterval(-13 * 3600)
        try AppleMusicDetailsStorage.save(old)      // same songs, 13 hours old
        let t4 = await startReading(force: false)
        let fourth = AppleMusicDetailsStorage.load()
        out.append(String(format: "OLD_READ took %.1fs, read again=%@ (expect true)", t4, "\(fourth?.readAt != old.readAt)"))

        var recent = fourth ?? first; recent.readAt = Date().addingTimeInterval(-11 * 3600)
        try AppleMusicDetailsStorage.save(recent)   // same songs, 11 hours old: not due yet
        let t5 = await startReading(force: false)
        out.append(String(format: "ELEVEN_HOURS took %.1fs, read again=%@ (expect false)", t5, "\(AppleMusicDetailsStorage.load()?.readAt != recent.readAt)"))
        out.append("STATUS \(store.statusText)")
        store.setEnabled(false)
        AppleMusicDetailsStorage.delete()
        suite.removePersistentDomain(forName: "apple-music-details-policy")
        try out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        print("wrote \(path)")
        exit(0)
    }

    // MARK: Real Queries over the real library

    /// Reads the library, saves it where a scratch run keeps it, then runs real Queries over songs, albums and artists with the new fields and the tempo
    /// fields, and writes one line per entity so the answers can be compared with an independent calculation.
    @MainActor
    private static func queryDump(container: ModelContainer, path: String) async throws {
        var out: [String] = []
        let rows = try await AppleMusicFavoritesReader.readLibraryDetails()
        try AppleMusicDetailsStorage.save(AppleMusicDetailsFile(readAt: Date(), rows: rows))
        let scrobbles = try await offMain { try await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container) }
        let snapshots = QuerySnapshots(bpm: BPMEngine.loadSnapshot(context: container.mainContext), appleMusic: AppleMusicDetailsSnapshot.load())
        out.append("SAVED rows=\(rows.count) scrobbles=\(scrobbles.count)")
        let loadStarted = Date()
        _ = AppleMusicDetailsStorage.load()
        let coldLoad = Date().timeIntervalSince(loadStarted)
        let warmStarted = Date()
        _ = AppleMusicDetailsStorage.load()
        let tempoStarted = Date()
        _ = AppleMusicDetailsStorage.tempoMap()
        out.append(String(format: "LOAD cold %.3fs, again %.4fs, tempo map %.4fs", coldLoad, tempoStarted.timeIntervalSince(warmStarted), Date().timeIntervalSince(tempoStarted)))
        for target in [QueryTarget.track, .album, .artist] {
            var spec = QuerySpec(target: target)
            var columns = [QueryFieldRef("musicDateAdded"), QueryFieldRef("musicGenre")]
            if target == .track { columns += [QueryFieldRef("bpm"), QueryFieldRef("bpmSource")] }
            spec.columns = columns
            spec.sorts = [QuerySort(key: .field(QueryFieldRef("plays")), direction: .descending)]
            let validated = try spec.validate(against: .standard)
            let started = Date()
            let result = await Task.detached(priority: .userInitiated) { () -> QueryResult in
                let run = QueryRun(target: target, asOf: Date(), scrobbles: scrobbles, allTimeScrobbles: scrobbles, snapshots: snapshots)
                return QueryEngine.evaluate(validated, run: run)
            }.value
            out.append(String(format: "QUERY %@ %.2fs entities=%d", "\(target)", Date().timeIntervalSince(started), result.rows.count))
            let keys = Dictionary(uniqueKeysWithValues: result.columns.map { ($0.field.id, $0.cacheKey) })
            func text(_ row: QueryRow, _ id: String) -> String {
                guard let key = keys[id], let cell = row.cells[key] else { return "" }
                switch cell {
                case .value(.date(let d)): return String(Int(d.timeIntervalSince1970))
                case .value(.text(let t)): return t
                case .value(.number(let n)): return String(n)
                case .value: return "?"
                case .missing: return ""
                case .pending: return "PENDING"
                }
            }
            for row in result.rows {
                out.append("\(target)\t\(row.entity.artist)\t\(row.entity.name)\t\(text(row, "musicDateAdded"))\t\(text(row, "musicGenre"))\t\(text(row, "bpm"))\t\(text(row, "bpmSource"))")
            }
        }
        try out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        print("wrote \(path)")
        exit(0)
    }

    // MARK: The real library (read-only)

    @MainActor
    private static func dump(container: ModelContainer, path: String) async throws {
        var out: [String] = []
        let started = Date()
        let rows = try await AppleMusicFavoritesReader.readLibraryDetails()
        out.append(String(format: "READ %.2fs rows=%d", Date().timeIntervalSince(started), rows.count))
        out.append("WITH_DATE \(rows.filter { $0.dateAdded != nil }.count) WITH_GENRE \(rows.filter { !$0.genre.isEmpty }.count) WITH_BPM \(rows.filter { $0.bpm > 0 }.count)")
        let scrobbles = try await offMain { try await ScrobbleHistoryCache.shared.snapshots(container: container) }
        let buildStarted = Date()
        let index = Index(rows: rows, scrobbles: scrobbles)
        out.append(String(format: "INDEX_BUILD %.2fs scrobbles=%d", Date().timeIntervalSince(buildStarted), scrobbles.count))
        var titles: [String: (String, String)] = [:]
        for s in scrobbles where !s.trackName.isEmpty && !s.artistName.isEmpty { titles[UnscrobbledPlaysEngine.exactKey(artist: s.artistName, track: s.trackName)] = (s.artistName, s.trackName) }
        var exact = 0, spelling = 0, ambiguous = 0, none = 0
        for (_, t) in titles {
            switch index.match(artist: t.0, track: t.1) {
            case .matched(_, let viaSpelling): if viaSpelling { spelling += 1 } else { exact += 1 }
            case .ambiguous: ambiguous += 1
            case .none: none += 1
            }
        }
        out.append("MATCH distinct_lastfm_titles=\(titles.count) exact=\(exact) viaSpelling=\(spelling) ambiguous=\(ambiguous) none=\(none)")
        out.append("TEMPO_USABLE \(Index.tempoByKey(rows).count)")
        for u in index.unmatched().prefix(25) { out.append("UNMATCHED\t\(u.artist)\t\(u.track)\t\(u.plays)\t\(u.candidates.joined(separator: " | "))") }
        for r in rows { out.append("ROW\t\(r.artist)\t\(r.title)\t\(r.album)\t\(r.albumArtist)\t\(r.genre)\t\(r.bpm)\t\(r.dateAdded.map { String(Int($0.timeIntervalSince1970)) } ?? "")") }
        try out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        print("wrote \(path)")
        exit(0)
    }
}
#endif
