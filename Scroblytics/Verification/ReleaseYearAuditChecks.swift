import Foundation
import SwiftData

#if DEBUG
/// `SCROBLYTICS_RELEASEYEAR_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): the comparison of Scroblytics' release years
/// with Apple Music's, on made-up data, the recording of which service gave a date, and the reading of Music's answer. No Music, no
/// network. Exits 0 on success.
///
/// `SCROBLYTICS_RELEASEYEAR_LIVE_READ=1` (read-only) reads a sample of tracks from the running Music one by one through the real backend, as
/// "Update Apple Music" does, checks each against the bulk read, and dry-runs a change to each (nothing is written).
/// `SCROBLYTICS_RELEASEYEAR_LIVE_WRITE=<persistent ID>` dry-runs a change to that one track, and writes it only with
/// `SCROBLYTICS_RELEASEYEAR_LIVE_WRITE_CONFIRM=yes`: it sets the track's year to the year it already has, to prove the write works. It is
/// only run with the owner's say-so.
///
/// `SCROBLYTICS_RELEASEYEAR_DUMP=1` runs the comparison on the REAL library (a store copy on `SCROBLYTICS_STORE_PATH`, and a
/// read-only read of the running Music) and prints the counts and examples. It changes nothing and is not part of release.sh.
enum ReleaseYearAuditChecks {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        let environment = ProcessInfo.processInfo.environment
        if environment["SCROBLYTICS_RELEASEYEAR_DUMP"] != nil {
            HeadlessTask.run("releaseyear-dump") { try await dump(container: container) }
            return
        }
        if environment["SCROBLYTICS_RELEASEYEAR_LIVE_READ"] != nil {
            HeadlessTask.run("releaseyear-live-read") { try await liveRead() }
            return
        }
        if let id = environment["SCROBLYTICS_RELEASEYEAR_LIVE_WRITE"] {
            HeadlessTask.run("releaseyear-live-write") { try await liveWrite(persistentID: id, confirmed: environment["SCROBLYTICS_RELEASEYEAR_LIVE_WRITE_CONFIRM"] == "yes") }
            return
        }
        guard environment["SCROBLYTICS_RELEASEYEAR_CHECK"] != nil else { return }
        HeadlessTask.run("releaseyear-check") {
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            try await sourceChecks(check)
            parseChecks(check)
            engineChecks(check)
            try await storeChecks(check)
            decisionChecks(check)
            try await actionChecks(check)
            try await trackChecks(check)
            musicUpdateChecks(check)
            await writerChecks(check)
            HeadlessTask.finish(failures)
        }
    }

    // MARK: - Which service gave the date

    private static func sourceChecks(_ report: (String, Bool, String) -> Void) async throws {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        struct Boom: Error {}
        let mb = try await ReleaseDateEngine.pickAlbumDate(musicBrainz: { "1986-05" }, deezer: { "1990-01-01" })
        check("MusicBrainz answering is recorded as MusicBrainz, and Deezer is not asked", mb?.date == "1986-05" && mb?.source == .musicBrainz)
        var deezerAsked = false
        let dz = try await ReleaseDateEngine.pickAlbumDate(musicBrainz: { nil }, deezer: { deezerAsked = true; return "1990-01-01" })
        check("a MusicBrainz miss goes to Deezer, which is then the source", dz?.date == "1990-01-01" && dz?.source == .deezer && deezerAsked)
        let none = try await ReleaseDateEngine.pickAlbumDate(musicBrainz: { nil }, deezer: { nil })
        check("both missing gives no date and no source", none == nil)
        var asked = false
        do {
            _ = try await ReleaseDateEngine.pickAlbumDate(musicBrainz: { throw Boom() }, deezer: { asked = true; return "1990" })
            check("a MusicBrainz failure is not turned into a Deezer answer", false)
        } catch {
            check("a MusicBrainz failure is not turned into a Deezer answer", !asked)
        }

        func origin(_ override: String?, _ detected: String?, _ recorded: String?) -> AlbumDateOrigin { .of(override: override, detected: detected, recorded: recorded) }
        check("your own date is manual, whatever was detected", origin("1971", "2021-01-01", "deezer") == .manual)
        check("a recorded source is used", origin(nil, "2007-04-30", "musicBrainz") == .musicBrainz && origin(nil, "2007-04-30", "deezer") == .deezer)
        check("an old date known only to the year or month can only have come from MusicBrainz", origin(nil, "1986", nil) == .musicBrainzInferred && origin(nil, "1986-05", nil) == .musicBrainzInferred)
        check("an old full date could be either, and says so", origin(nil, "2007-04-30", nil) == .detectedUnrecorded)
        check("no date is no origin", origin(nil, nil, nil) == .none && origin("", "", nil) == .none)
        check("every origin has words", [AlbumDateOrigin.manual, .musicBrainz, .deezer, .musicBrainzInferred, .detectedUnrecorded, .none].allSatisfy { !$0.label.isEmpty })
    }

    // MARK: - Reading Music's answer

    private static func parseChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let rs = "\u{1E}", gs = "\u{1D}"
        let reply = ["Song A", "Song, B", "Naïve 日本"].joined(separator: rs) + gs + ["Artist A", "Artist A", "Artist B"].joined(separator: rs) + gs
            + ["Artist A", "", "Various Artists"].joined(separator: rs) + gs + ["Album One", "Album One", "Mix"].joined(separator: rs) + gs + ["1998", "0", "2005"].joined(separator: rs)
            + gs + ["ID1", "ID2", "ID3"].joined(separator: rs) + "\n"
        let tracks = AppleMusicYearReader.parse(reply)
        check("Music's columns are read into tracks", tracks?.count == 3 && tracks?[0] == AppleMusicTrackYear(name: "Song A", artist: "Artist A", albumArtist: "Artist A", album: "Album One", year: 1998, persistentID: "ID1"), "\(String(describing: tracks))")
        check("a year of 0 is no year, an empty album artist stays empty, and other scripts survive", tracks?[1].year == nil && tracks?[1].albumArtist == "" && tracks?[2].name == "Naïve 日本" && tracks?[2].year == 2005)
        check("a reply with the wrong number of columns or rows is refused, not guessed", AppleMusicYearReader.parse("a" + gs + "b") == nil && AppleMusicYearReader.parse("a" + rs + "b" + gs + "x" + gs + "y" + gs + "z" + gs + "1998") == nil)
        check("an empty library reads as no tracks", AppleMusicYearReader.parse(gs + gs + gs + gs + gs)?.isEmpty == true)
        check("each track keeps Music's persistent ID, which is how a change finds it", tracks?.map(\.persistentID) == ["ID1", "ID2", "ID3"])
    }

    // MARK: - The comparison

    private static func album(_ artist: String, _ title: String, _ date: String?, _ origin: AlbumDateOrigin = .musicBrainz, plays: Int = 0) -> AuditAlbum {
        AuditAlbum(title: title, artist: artist, artistKey: TextNormalization.artistIdentityKey(artist), normalizedTitle: TextNormalization.normalizeAlbumName(title), date: date, origin: date == nil ? .none : origin, plays: plays)
    }

    private static func track(_ name: String, _ artist: String, _ album: String, _ year: Int?, albumArtist: String? = nil) -> AppleMusicTrackYear {
        AppleMusicTrackYear(name: name, artist: artist, albumArtist: albumArtist ?? artist, album: album, year: year)
    }

    private static func engineChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        check("the categories: same, a year apart either way, more, and each side with no year",
              ReleaseYearAudit.category(scroblytics: 1990, music: 1990) == .same && ReleaseYearAudit.category(scroblytics: 1991, music: 1990) == .offByOne
              && ReleaseYearAudit.category(scroblytics: 1989, music: 1990) == .offByOne && ReleaseYearAudit.category(scroblytics: 2021, music: 1971) == .differs
              && ReleaseYearAudit.category(scroblytics: nil, music: 1990) == .scroblyticsUndated && ReleaseYearAudit.category(scroblytics: 1990, music: nil) == .musicUndated)
        check("the album's Music year is the most common track year, the earliest of a tie, none for none",
              ReleaseYearAudit.modalYear([1960, 1960, 1953]) == 1960 && ReleaseYearAudit.modalYear([1965, 1953]) == 1953 && ReleaseYearAudit.modalYear([]) == nil)

        let albums = [
            album("Artist A", "Agree", "2001-05-05"), album("Artist A", "One Off", "2003-01-01"), album("Artist A", "Far Off", "2021-01-01", .detectedUnrecorded),
            album("Artist A", "Compilation", "2004-06-01"), album("Artist A", "Undated", nil), album("Artist B", "Edition Album", "1995"),
            album("Artist C", "Shared Title", "1980"), album("Artist A", "Mine", "1971", .manual),
            album("Various Artists", "Now Hits", "2003"), album("Artist D", "Green River", "1968"),
        ]
        var music: [AppleMusicTrackYear] = []
        music += ["x", "y", "z"].map { track($0, "Artist A", "Agree", 2001) }
        music += ["x", "y"].map { track($0, "Artist A", "One Off", 2002) }
        music += ["x", "y"].map { track($0, "Artist A", "Far Off", 1971) }
        music += [track("old", "Artist A", "Compilation", 1953), track("older", "Artist A", "Compilation", 1953), track("oldest", "Artist A", "Compilation", 1953), track("new", "Artist A", "Compilation", 2004), track("same", "Artist A", "Compilation", 2004), track("none", "Artist A", "Compilation", nil)]
        music += [track("x", "Artist A", "Undated", 1999)]
        music += [track("x", "Artist B", "Edition Album (Deluxe Edition)", 1995)]
        music += [track("x", "Artist C", "Shared Title", 1980, albumArtist: "Various Artists")]   // album artist differs: matched by its track artist
        music += [track("x", "Someone", "Now Hits", 2003, albumArtist: "")]                      // a compilation with no album artist in Music: matched by its title
        music += [track("x", "Artist E", "Green River", 2006)]                                    // another artist's album with the same title: NOT a match
        music += [track("x", "Artist A", "Mine", 1971)]
        music += [track("x", "Artist Z", "Not Scrobbled", 2010)]
        let report = ReleaseYearAudit.compare(music: music, albums: albums, trackOverrides: [:])
        func row(_ title: String) -> ReleaseYearAudit.AlbumRow? { report.rows.first { $0.scroblytics.title == title } }

        check("every album in both is matched once; the one never scrobbled and the same-titled album of another artist are not", report.matched == 9 && report.unmatchedMusicAlbums == 2 && report.musicAlbums == 11, "\(report.matched) \(report.unmatchedMusicAlbums) \(report.musicAlbums)")
        check("an album whose tracks agree with Scroblytics is the same, with nothing differing", row("Agree")?.category == .same && row("Agree")?.trackDifferences.isEmpty == true)
        check("a year apart is off by one, in either direction", row("One Off")?.category == .offByOne && row("One Off")?.gap == 1)
        check("a reissue date is a real difference with its gap, and its tracks all differ", row("Far Off")?.category == .differs && row("Far Off")?.gap == 50 && row("Far Off")?.trackDifferences.count == 2)
        check("an album with no date in Scroblytics is its own kind", row("Undated")?.category == .scroblyticsUndated)
        check("an edition suffix does not stop an album matching", row("Edition Album")?.category == .same && row("Edition Album")?.matchedBy == .albumArtist)
        check("a different album artist is matched through the track's artist; a compilation by its title; another artist's same title not at all", row("Shared Title")?.matchedBy == .trackArtist && row("Now Hits")?.matchedBy == .titleOnly && row("Green River")?.musicAlbum == nil, "\(String(describing: row("Green River")))")
        let compilation = row("Compilation")
        check("a compilation's years are read: modal, range, how many, and no year is left out", compilation?.musicYear == 1953 && compilation?.musicEarliest == 1953 && compilation?.musicLatest == 2004 && compilation?.musicDistinctYears == 2 && compilation?.musicVaries == true)
        check("…and the album year here (2004) disagrees with its most common track year (1953), but only the 3 older tracks differ", compilation?.category == .differs && compilation?.trackDifferences.map(\.name).sorted() == ["old", "older", "oldest"] && compilation?.trackDifferences.allSatisfy { !$0.ownDate } == true)
        check("tracks with no year in Music are never differences", compilation?.trackDifferences.contains { $0.name == "none" } == false && report.musicTracksWithoutYear == 1)
        check("the totals add up", report.count(.same) + report.count(.offByOne) + report.count(.differs) + report.count(.scroblyticsUndated) + report.count(.musicUndated) == report.matched && report.disagreements == 3)

        // A date set on a track is what Scroblytics shows for it.
        let overrides = [TextNormalization.lovedKey(artist: "Artist A", track: "old"): "1953-01-12", TextNormalization.lovedKey(artist: "Artist A", track: "same"): "1999"]
        let withOwn = ReleaseYearAudit.compare(music: music, albums: albums, trackOverrides: overrides)
        let own = withOwn.rows.first { $0.scroblytics.title == "Compilation" }
        check("a track with its own date that matches Music is no longer a difference; one that doesn't is, marked as its own", own?.trackDifferences.map(\.name).sorted() == ["older", "oldest", "same"] && own?.trackDifferences.first { $0.name == "same" }?.ownDate == true && own?.trackDifferences.first { $0.name == "same" }?.scroblyticsYear == 1999)
        check("an album date doesn't change with a track date: the album-level category stays", own?.category == compilation?.category)
        check("with nothing in Music, nothing is compared", ReleaseYearAudit.compare(music: [], albums: albums).rows.isEmpty)

        // Tracks spread evenly over several years: the album has no most common year, so any tied year agrees with it.
        let spread: [AppleMusicTrackYear] = (1988...1990).flatMap { (year: Int) -> [AppleMusicTrackYear] in ["a", "b"].map { track("\($0)\(year)", "Artist A", "Spread", year) } }
        func spreadRow(_ albumDate: String) -> ReleaseYearAudit.AlbumRow? {
            ReleaseYearAudit.compare(music: spread, albums: [album("Artist A", "Spread", albumDate)], trackOverrides: [:]).rows.first
        }
        check("an even spread: the latest tied year agrees, and so does the earliest and a middle one", ["1990", "1988", "1989"].allSatisfy { spreadRow($0)?.category == .same && spreadRow($0)?.gap == 0 })
        check("…a year outside the tied years still disagrees, against the earliest", spreadRow("1995")?.category == .differs && spreadRow("1995")?.musicYear == 1988 && spreadRow("1987")?.category == .offByOne)
        check("…a clear majority year is still the album's Music year, not any year in the spread",
              ReleaseYearAudit.modalYears([1988, 1989, 1989]) == [1989] && ReleaseYearAudit.modalYears([1988, 1989]) == [1988, 1989] && ReleaseYearAudit.modalYears([]).isEmpty)

        // One Scroblytics album is compared once, however many of Music's albums look like it.
        let dupAlbums = [album("Artist A", "Dup", "2000")]
        let dupMusic = [track("x", "Artist A", "Dup", 2000), track("y", "Artist A", "Dup", 2000), track("z", "Artist A", "Dup", 1990, albumArtist: "Various Artists")]
        let dup = ReleaseYearAudit.compare(music: dupMusic, albums: dupAlbums)
        check("two of Music's albums matching one of yours: the better match is the one compared, the other is left unmatched", dup.rows.count == 1 && dup.rows[0].matchedBy == .albumArtist && dup.rows[0].trackCount == 2 && dup.rows[0].category == .same && dup.unmatchedMusicAlbums == 1, "\(dup.rows.count) \(dup.unmatchedMusicAlbums)")
        check("every album in a report appears once", Set(report.rows.map(\.albumKey)).count == report.rows.count && Set(withOwn.rows.map(\.albumKey)).count == withOwn.rows.count)
    }

    // MARK: - The Scroblytics side, from a store

    private static func storeChecks(_ report: (String, Bool, String) -> Void) async throws {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let container = try ModelContainer(for: Schema([Artist.self, Album.self, Track.self]), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let artist = Artist(normalizedName: "artist a", name: "Artist A")
        context.insert(artist)
        func insert(_ title: String, override: String?, detected: String?, source: String?) {
            let row = Album(identityKey: TextNormalization.albumIdentityKey(artist: "artist a", album: title), title: title, normalizedTitle: TextNormalization.normalizeAlbumName(title), artist: artist)
            row.releaseDateOverride = override
            row.releaseDateDetected = detected
            row.releaseDateSource = source
            context.insert(row)
        }
        insert("Mine", override: "1971", detected: "2021-01-01", source: "deezer")
        insert("From MB", override: nil, detected: "2007-04-30", source: "musicBrainz")
        insert("Old Detection", override: nil, detected: "1986", source: nil)
        insert("Nothing", override: nil, detected: nil, source: nil)
        let trackRow = Track(identityKey: TextNormalization.lovedKey(artist: "Artist A", track: "Song"), title: "Song", normalizedTitle: "song", artist: artist)
        trackRow.releaseDateOverride = "1953"
        context.insert(trackRow)
        context.insert(Track(identityKey: TextNormalization.lovedKey(artist: "Artist A", track: "Other"), title: "Other", normalizedTitle: "other", artist: artist))
        try context.save()

        let loaded = await ReleaseYearAuditStoreReader(modelContainer: container).load()
        func origin(_ title: String) -> AlbumDateOrigin? { loaded.albums.first { $0.title == title }?.origin }
        check("every album is read with the date Scroblytics shows: your override first", loaded.albums.count == 4 && loaded.albums.first { $0.title == "Mine" }?.date == "1971")
        check("and its origin: manual, a recorded service, an inferred one, none", origin("Mine") == .manual && origin("From MB") == .musicBrainz && origin("Old Detection") == .musicBrainzInferred && origin("Nothing") == AlbumDateOrigin.none)
        check("only the dates set on tracks are read, by the key a track's page saves under", loaded.trackOverrides == [TextNormalization.lovedKey(artist: "Artist A", track: "Song"): "1953"], "\(loaded.trackOverrides)")
    }

    // MARK: - Decisions and the lists

    private static func sampleReport() -> ReleaseYearAudit.Report {
        let albums = [
            album("Artist A", "Agree", "2001"), album("Artist A", "One Off", "2003"), album("Artist A", "Far Off", "2021-01-01", .detectedUnrecorded),
            album("Artist A", "Mine", "1971", .manual), album("Artist A", "Compilation", "2004"), album("Artist B", "Late", "2010", .deezer),
        ]
        var music: [AppleMusicTrackYear] = []
        music += [track("x", "Artist A", "Agree", 2001)]
        music += [track("x", "Artist A", "One Off", 2002)]
        music += [track("x", "Artist A", "Far Off", 1971)]
        music += [track("x", "Artist A", "Mine", 1969)]
        music += [track("a", "Artist A", "Compilation", 1953), track("b", "Artist A", "Compilation", 1953), track("c", "Artist A", "Compilation", 1980)]
        music += [track("x", "Artist B", "Late", 2009)]
        return ReleaseYearAudit.compare(music: music, albums: albums)
    }

    private static func decisionChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let sample = sampleReport()
        func titles(_ filter: ReleaseYearAudit.Filter, _ decisions: [String: ReleaseYearAudit.Decision] = [:]) -> Set<String> {
            Set(ReleaseYearAudit.listed(sample.rows, filter: filter, decisions: decisions).map(\.scroblytics.title))
        }
        check("the lists hold only albums that disagree, never ones that agree", titles(.all) == ["One Off", "Far Off", "Mine", "Compilation", "Late"], "\(titles(.all))")
        check("the filters split at two years: 1–2 apart (One Off +1, Mine +2, Late +1) and 3 or more (Far Off +50, Compilation +51)", titles(.close) == ["One Off", "Mine", "Late"] && titles(.far) == ["Far Off", "Compilation"], "\(titles(.close)) \(titles(.far))")
        check("a gap is placed by its size, not its direction, and no gap is no band", ReleaseYearAudit.band(forGap: 1) == .close && ReleaseYearAudit.band(forGap: -2) == .close && ReleaseYearAudit.band(forGap: 3) == .far && ReleaseYearAudit.band(forGap: -73) == .far && ReleaseYearAudit.band(forGap: 0) == nil && ReleaseYearAudit.band(forGap: nil) == nil)
        check("the headline counts follow the same bands", sample.count(band: .close) == 3 && sample.count(band: .far) == 2)
        check("the saved filter names from before the split still read", ReleaseYearAudit.Filter(rawValue: "offByOne") == .close && ReleaseYearAudit.Filter(rawValue: "differs") == .far)
        check("your own dates are listed on their own, and so are the compilations", titles(.yourDates) == ["Mine"] && titles(.musicVaries) == ["Compilation"])
        let key = { (title: String) in sample.rows.first { $0.scroblytics.title == title }!.albumKey }
        let row = sample.rows.first { $0.scroblytics.title == "One Off" }!
        // Sorting.
        func order(_ key: ReleaseYearAudit.SortKey, _ ascending: Bool? = nil) -> [String] { ReleaseYearAudit.sorted(sample.rows, by: key, ascending: ascending).map(\.scroblytics.title) }
        check("every sort in either direction keeps every album once", ReleaseYearAudit.SortKey.allCases.allSatisfy { key in [true, false].allSatisfy { Set(order(key, $0)).count == sample.rows.count && order(key, $0).count == sample.rows.count } })
        check("by difference, largest first: the 51-year gap, the 50, then the 2, then the 1s (ties by artist, then album)", order(.difference) == ["Compilation", "Far Off", "Mine", "One Off", "Late", "Agree"], "\(order(.difference))")
        check("…and smallest first is the reverse of the differences (ties still A to Z)", order(.difference, true) == ["Agree", "One Off", "Late", "Mine", "Far Off", "Compilation"], "\(order(.difference, true))")
        check("by album, A to Z to begin with, and back", order(.album) == ["Agree", "Compilation", "Far Off", "Late", "Mine", "One Off"] && order(.album, false) == order(.album).reversed(), "\(order(.album)) \(order(.album, false))")
        check("by artist, A to Z, with each artist's albums in order", order(.artist, true).prefix(5) == ["Agree", "Compilation", "Far Off", "Mine", "One Off"] && order(.artist, true).last == "Late", "\(order(.artist, true))")
        check("by Scroblytics year, newest first to begin with", order(.scroblyticsYear).first == "Far Off" && order(.scroblyticsYear, true).first == "Mine", "\(order(.scroblyticsYear))")
        check("by Apple Music year, oldest first when asked", order(.musicYear, true).first == "Compilation" && order(.musicYear).first == "Late", "\(order(.musicYear))")
        check("by source, alphabetically by the source's name: Deezer first, then the unrecorded, Manual, and MusicBrainz last", order(.source, true).first == "Late" && order(.source, true).dropFirst().first == "Far Off" && order(.source, true).dropFirst(2).first == "Mine", "\(order(.source, true))")
        // Plays: counted per album across edition names and artist spellings, and a sort puts the most played first.
        func play(_ artist: String, _ album: String) -> ScrobbleSnapshot { ScrobbleSnapshot(artistName: artist, albumName: album, trackName: "t", imageURL: nil, playedAt: Date(timeIntervalSince1970: 0)) }
        let played = [play("Artist P", "Big"), play("artist p", "Big (Deluxe Edition)"), play("Artist P", "Big"), play("Artist P", "Small"), play("Artist P", ""), play("Artist Q", "Big")]
        let counts = ReleaseYearAudit.playCounts(of: played)
        func count(_ artist: String, _ title: String) -> Int { counts[ReleaseYearAudit.albumKey(artistKey: TextNormalization.artistIdentityKey(artist), normalizedTitle: TextNormalization.normalizeAlbumName(title))] ?? 0 }
        check("plays count every edition name and case spelling of an album together, and no other artist's album of the same name", count("Artist P", "Big") == 3 && count("Artist Q", "Big") == 1 && count("Artist P", "Small") == 1, "\(counts)")
        check("a play with no album name belongs to no album", counts.values.reduce(0, +) == 5)
        let playedAlbums = [album("Artist P", "Quiet", "2001", plays: 5), album("Artist P", "Loud", "2001", plays: 500), album("Artist P", "Middle", "2001", plays: 50), album("Artist P", "Alpha", "2001", plays: 50)]
        let playedMusic = playedAlbums.map { track("x", "Artist P", $0.title, 1990) }
        let playedRows = ReleaseYearAudit.compare(music: playedMusic, albums: playedAlbums).rows
        check("by plays, most played first to begin with (ties by artist, then album), and fewest first when asked", ReleaseYearAudit.sorted(playedRows, by: .plays).map(\.scroblytics.title) == ["Loud", "Alpha", "Middle", "Quiet"] && ReleaseYearAudit.sorted(playedRows, by: .plays, ascending: true).map(\.scroblytics.title) == ["Quiet", "Alpha", "Middle", "Loud"] && ReleaseYearAudit.SortKey.plays.startsAscending == false)
        check("a row carries its album's plays", playedRows.first { $0.scroblytics.title == "Loud" }?.plays == 500)
        let withNoYear = sample.rows + ReleaseYearAudit.compare(music: [track("x", "Artist Z", "Undated", 2000)], albums: [album("Artist Z", "Undated", nil)]).rows
        check("an album with no year in one place comes last, whichever way the list runs", ReleaseYearAudit.sorted(withNoYear, by: .scroblyticsYear, ascending: true).last?.scroblytics.title == "Undated" && ReleaseYearAudit.sorted(withNoYear, by: .scroblyticsYear, ascending: false).last?.scroblytics.title == "Undated")
        check("each sort starts in its own direction and every direction has words", ReleaseYearAudit.SortKey.allCases.allSatisfy { !$0.directionLabel(ascending: true).isEmpty && $0.directionLabel(ascending: true) != $0.directionLabel(ascending: false) } && ReleaseYearAudit.SortKey.difference.startsAscending == false && ReleaseYearAudit.SortKey.album.startsAscending)
        let signature = ReleaseYearAudit.tracksSignature(row.trackDifferences)
        let keep = ReleaseYearAudit.Decision(albumKey: key("One Off"), verdict: .keepMine, scroblyticsYear: 2003, musicYear: 2002, tracksSignature: signature)
        check("an album you kept leaves every list", ReleaseYearAudit.isDecided(row, decisions: [keep.albumKey: keep]) && !titles(.all, [keep.albumKey: keep]).contains("One Off") && !titles(.close, [keep.albumKey: keep]).contains("One Off"))
        let staleSelf = ReleaseYearAudit.Decision(albumKey: key("One Off"), verdict: .keepMine, scroblyticsYear: 2004, musicYear: 2002, tracksSignature: signature)
        let staleMusic = ReleaseYearAudit.Decision(albumKey: key("One Off"), verdict: .keepMine, scroblyticsYear: 2003, musicYear: 2001, tracksSignature: signature)
        check("it comes back when either year has changed since", !ReleaseYearAudit.isDecided(row, decisions: [keep.albumKey: staleSelf]) && !ReleaseYearAudit.isDecided(row, decisions: [keep.albumKey: staleMusic]) && titles(.all, [keep.albumKey: staleMusic]).contains("One Off"))
        let used = ReleaseYearAudit.Decision(albumKey: key("One Off"), verdict: .usedApple, scroblyticsYear: 2003, musicYear: 2002)
        check("a record of having used Music's year doesn't hide an album that differs again", !ReleaseYearAudit.isDecided(row, decisions: [used.albumKey: used]))
        check("an album's key is its artist and normalized title", key("Agree") == ReleaseYearAudit.albumKey(artistKey: "artist a", normalizedTitle: "agree") && Set(sample.rows.map(\.albumKey)).count == sample.rows.count)
    }

    // MARK: - Changing a date, and undoing it

    @MainActor
    private static func actionChecks(_ emit: (String, Bool, String) -> Void) async throws {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { emit(label, ok, detail) }
        let container = try ModelContainer(for: Schema([Artist.self, Album.self, Track.self, ReleaseYearDecision.self]), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let artist = Artist(normalizedName: "artist a", name: "Artist A")
        context.insert(artist)
        func insert(_ title: String, override: String?, detected: String?) {
            let row = Album(identityKey: TextNormalization.albumIdentityKey(artist: "artist a", album: title), title: title, normalizedTitle: TextNormalization.normalizeAlbumName(title), artist: artist)
            row.releaseDateOverride = override
            row.releaseDateDetected = detected
            context.insert(row)
        }
        insert("One Off", override: nil, detected: "2003")
        insert("Far Off", override: "1999", detected: "2021-01-01")
        insert("Compilation", override: nil, detected: "2004")
        insert("Mine", override: nil, detected: "1971")
        insert("Late", override: nil, detected: "2010")
        try context.save()
        func stored(_ title: String) -> Album? { ReleaseDateEngine.albumRow(context: context, artist: "Artist A", album: title) }
        func report() async -> ReleaseYearAudit.Report {
            let loaded = await ReleaseYearAuditStoreReader(modelContainer: container).load()
            return ReleaseYearAudit.compare(music: sampleMusic(), albums: loaded.albums, trackOverrides: [:])
        }
        func rows(_ titles: [String], from r: ReleaseYearAudit.Report) -> [ReleaseYearAudit.AlbumRow] { titles.compactMap { t in r.rows.first { $0.scroblytics.title == t } } }
        let before = await report()
        let oneOff = rows(["One Off"], from: before)

        // Use Apple Music's year.
        var result = try ReleaseYearAuditActions.useAppleYear(oneOff, context: context)
        check("using Music's year sets the album's own date to it, once", result == .init(applied: 1, skipped: 0, skippedVaries: 0) && stored("One Off")?.releaseDateOverride == "2002")
        var decisions = try context.fetch(FetchDescriptor<ReleaseYearDecision>())
        check("…and remembers the date it replaced (none: the detected date showed) and both years", decisions.count == 1 && decisions[0].verdict == "usedApple" && decisions[0].previousOverride == nil && decisions[0].scroblyticsYear == 2003 && decisions[0].musicYear == 2002)
        let after = await report()
        check("the album now agrees with Music, and is manual in Scroblytics", after.rows.first { $0.scroblytics.title == "One Off" }?.category == .same && after.rows.first { $0.scroblytics.title == "One Off" }?.scroblytics.origin == .manual)
        try ReleaseYearAuditActions.undo(decisions[0], context: context)
        let remaining = try context.fetch(FetchDescriptor<ReleaseYearDecision>())
        check("undoing puts the earlier date back (none) and removes the record", stored("One Off")?.releaseDateOverride == nil && stored("One Off")?.releaseDateDetected == "2003" && remaining.isEmpty)

        // A date that had been set by hand comes back as it was.
        let farOff = rows(["Far Off"], from: before)
        check("an album you had given a date of your own is in the list", farOff.count == 1 && farOff[0].scroblytics.year == 1999)
        _ = try ReleaseYearAuditActions.useAppleYear(farOff, context: context)
        decisions = try context.fetch(FetchDescriptor<ReleaseYearDecision>())
        check("its earlier date is what is remembered", stored("Far Off")?.releaseDateOverride == "1971" && decisions.first?.previousOverride == "1999")
        // …but not if you have changed it again since.
        stored("Far Off")?.releaseDateOverride = "1972"
        try context.save()
        try ReleaseYearAuditActions.undo(decisions[0], context: context)
        check("undoing leaves a date you changed after that alone", stored("Far Off")?.releaseDateOverride == "1972")

        // Bulk: an album whose tracks span years is skipped.
        let both = rows(["One Off", "Compilation", "Late"], from: await report())
        result = try ReleaseYearAuditActions.useAppleYear(both, skipVaries: true, context: context)
        check("a bulk change skips an album whose Music tracks span several years, and says so", result.applied == 2 && result.skippedVaries == 1 && stored("Compilation")?.releaseDateOverride == nil && stored("Late")?.releaseDateOverride == "2009")
        let single = rows(["Compilation"], from: await report())
        result = try ReleaseYearAuditActions.useAppleYear(single, context: context)
        check("one album chosen by hand is changed even though its Music tracks span years (to the most common year)", result.applied == 1 && stored("Compilation")?.releaseDateOverride == "1953")

        // An album whose Music tracks span years, chosen alone: the album and its tracks, together.
        // (covered with the other track checks below)

        // Keep Scroblytics.
        let mine = rows(["Mine"], from: await report())
        result = try ReleaseYearAuditActions.keepMine(mine, context: context)
        let kept = try context.fetch(FetchDescriptor<ReleaseYearDecision>()).first { $0.album == "Mine" }
        check("keeping Scroblytics’ date changes no date and remembers both years", result.applied == 1 && stored("Mine")?.releaseDateOverride == nil && kept?.verdict == "keepMine" && kept?.scroblyticsYear == 1971 && kept?.musicYear == 1969)
        let count = try context.fetch(FetchDescriptor<ReleaseYearDecision>()).filter { $0.album == "Mine" }.count
        _ = try ReleaseYearAuditActions.keepMine(mine, context: context)
        check("deciding the same album again replaces the earlier decision", try context.fetch(FetchDescriptor<ReleaseYearDecision>()).filter { $0.album == "Mine" }.count == count)
        if let kept { try ReleaseYearAuditActions.undo(kept, context: context) }
        check("removing a keep-mine decision changes no date", stored("Mine")?.releaseDateOverride == nil && stored("Mine")?.releaseDateDetected == "1971")
        check("an album with no year in Music, or no row to change, is skipped rather than guessed", try ReleaseYearAuditActions.useAppleYear([], context: context) == .init())

        // The backup.
        try context.save()
        _ = try ReleaseYearAuditActions.keepMine(mine, context: context)
        let document = try NativeBackupEngine.makeDocument(context: context)
        let (archive, summary) = try NativeBackupEngine.inspect(document: document)
        let have = try context.fetch(FetchDescriptor<ReleaseYearDecision>()).count
        check("the backup holds the decisions and says so", archive.releaseYearDecisions?.count == have && have > 0 && summary.description.contains("release-year decisions"), summary.description)
        for item in try context.fetch(FetchDescriptor<ReleaseYearDecision>()) { context.delete(item) }
        try context.save()
        try NativeBackupEngine.restoreReleaseYearDecisions(archive.releaseYearDecisions, context: context)
        let restored = try context.fetch(FetchDescriptor<ReleaseYearDecision>())
        check("restoring brings them back with their years", restored.count == have && restored.contains { $0.album == "Mine" && $0.scroblyticsYear == 1971 && $0.musicYear == 1969 })
        try NativeBackupEngine.restoreReleaseYearDecisions(nil, context: context)
        check("an older backup (no field) leaves the decisions alone", try context.fetch(FetchDescriptor<ReleaseYearDecision>()).count == have)
        try NativeBackupEngine.restoreReleaseYearDecisions([], context: context)
        check("a backup with none clears them", try context.fetch(FetchDescriptor<ReleaseYearDecision>()).isEmpty)
    }

    // MARK: - Compilations: the tracks' own dates

    @MainActor
    private static func trackChecks(_ emit: (String, Bool, String) -> Void) async throws {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { emit(label, ok, detail) }
        let container = try ModelContainer(for: Schema([Artist.self, Album.self, Track.self, ReleaseYearDecision.self]), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let artist = Artist(normalizedName: "artist a", name: "Artist A")
        context.insert(artist)
        func insertAlbum(_ title: String, detected: String) {
            let row = Album(identityKey: TextNormalization.albumIdentityKey(artist: "artist a", album: title), title: title, normalizedTitle: TextNormalization.normalizeAlbumName(title), artist: artist)
            row.releaseDateDetected = detected
            context.insert(row)
        }
        func insertTrack(_ title: String, override: String? = nil) {
            let row = Track(identityKey: TextNormalization.lovedKey(artist: "Artist A", track: title), title: title, normalizedTitle: TextNormalization.normalizeTrackTitle(title), artist: artist)
            row.releaseDateOverride = override
            context.insert(row)
        }
        insertAlbum("Comp", detected: "2004")
        insertAlbum("Other Comp", detected: "1985")
        insertTrack("Old One")
        insertTrack("Don't Stop")                 // scrobbled with a straight apostrophe; Music spells it with a curly one
        insertTrack("Mine", override: "1999")      // your own date, and not Music's year
        insertTrack("It's Mine Too", override: "1971")   // your own date, under a different apostrophe than Music's
        insertTrack("Same")
        insertTrack("Early"); insertTrack("Late")
        // A stored track whose normalized title is not what normalizing its title now gives (it was saved by an earlier version): the
        // audit finds it, and leaves its own date alone, by the stored one.
        let oddly = Track(identityKey: TextNormalization.lovedKey(artist: "Artist A", track: "Odd Title"), title: "Odd Title", normalizedTitle: TextNormalization.normalizeTrackTitle("Odd Name"), artist: artist)
        oddly.releaseDateOverride = "1968"
        context.insert(oddly)
        try context.save()

        let music: [AppleMusicTrackYear] = [
            track("Old One", "Artist A", "Comp", 1953), track("Don’t Stop", "Artist A", "Comp", 1960), track("Mine", "Artist A", "Comp", 1970),
            track("It’s Mine Too", "Artist A", "Comp", 1971), track("Never Played", "Artist A", "Comp", 1965), track("Same", "Artist A", "Comp", 2004),
            track("Early", "Artist A", "Other Comp", 1980), track("Late", "Artist A", "Other Comp", 1990),
            track("Odd Name", "Artist A", "Comp", 1968),
            // A second 1953 track (never played, so never a difference) makes 1953 the album's clear most common year.
            track("Also Unplayed", "Artist A", "Comp", 1953),
        ]
        func analyse() async -> ReleaseYearAudit.Report {
            let loaded = await ReleaseYearAuditStoreReader(modelContainer: container).load()
            return ReleaseYearAudit.compare(music: music, albums: loaded.albums, trackOverrides: loaded.trackOverrides, trackOverrideIndex: loaded.trackOverrideIndex, knownTracks: loaded.known)
        }
        func row(_ title: String, _ r: ReleaseYearAudit.Report) -> ReleaseYearAudit.AlbumRow? { r.rows.first { $0.scroblytics.title == title } }
        func stored(_ title: String) -> Track? {
            let key = TextNormalization.lovedKey(artist: "Artist A", track: title)
            return try? context.fetch(FetchDescriptor<Track>(predicate: #Predicate { $0.identityKey == key })).first
        }
        func decisionCount() -> Int { (try? context.fetch(FetchDescriptor<ReleaseYearDecision>()).count) ?? -1 }

        let first = await analyse()
        let comp = row("Comp", first)
        check("a track with a date of your own is found even when its apostrophe differs (it agrees with Music, so it is not a difference); one that disagrees is marked as your date", comp?.trackDifferences.contains { $0.name == "It’s Mine Too" } == false && comp?.trackDifferences.first { $0.name == "Mine" }?.ownDate == true, "\(String(describing: comp?.trackDifferences))")
        check("a track found only by its stored normalized title is still recognised as having its own date (and agrees, so is no difference)", comp?.trackDifferences.contains { $0.name == "Odd Name" } == false)
        check("the tracks that differ: those shown at the album's year and those with a date of their own; never the one that agrees, and never a track you haven't played (nothing of it here to change)", Set(comp?.trackDifferences.map(\.name) ?? []) == ["Old One", "Don’t Stop", "Mine"], "\(String(describing: comp?.trackDifferences.map(\.name)))")

        // Compilations: albums whose Music tracks span several years and some differ, whether or not the album's own year agrees.
        let listedNames = Set(ReleaseYearAudit.mixedYears(first.rows, decisions: [:]).map(\.scroblytics.title))
        check("the Mixed years list holds the albums with several years in Music and tracks that differ", listedNames == ["Comp", "Other Comp"], "\(listedNames)")
        // Other Comp's album year (1985) is neither 1980 nor 1990, but is the most common year of neither: both its tracks differ.
        check("an album whose tracks all agree with it, or have one year in Music, is not listed as mixed years", ReleaseYearAudit.mixedYears(analyseSample(), decisions: [:]).isEmpty)

        // The minimums that narrow the list, checked against a plain filter over the same rows.
        let mixedRows = first.rows.filter { $0.musicVaries && !$0.trackDifferences.isEmpty }
        let widest = mixedRows.map(\.yearSpread).max() ?? 0
        let mostTracks = mixedRows.map { $0.trackDifferences.count }.max() ?? 0
        func mixedTitles(_ criteria: ReleaseYearAudit.MixedYearsCriteria) -> Set<String> { Set(ReleaseYearAudit.mixedYears(first.rows, decisions: [:], criteria: criteria).map(\.scroblytics.title)) }
        check("the defaults list every album with mixed years", ReleaseYearAudit.MixedYearsCriteria().isDefault && mixedTitles(.init()) == Set(mixedRows.map(\.scroblytics.title)))
        func limit(_ comparison: ReleaseYearAudit.Limit.Comparison, _ value: Int) -> ReleaseYearAudit.Limit { .init(comparison: comparison, value: value) }
        // Each operator, against a plain filter over the same rows (the rows are the ones the Mixed years list starts from).
        func expected(_ keep: (ReleaseYearAudit.AlbumRow) -> Bool) -> Set<String> { Set(mixedRows.filter(keep).map(\.scroblytics.title)) }
        check("spread more than a bound lists the albums whose years are further apart than that, and more than the widest lists none", mixedTitles(.init(spread: limit(.greater, widest - 1))) == expected { $0.yearSpread > widest - 1 } && !mixedTitles(.init(spread: limit(.greater, widest - 1))).isEmpty && mixedTitles(.init(spread: limit(.greater, widest))).isEmpty, "widest \(widest)")
        check("spread fewer than a bound lists the albums closer together than that", mixedTitles(.init(spread: limit(.less, widest))) == expected { $0.yearSpread < widest } && mixedTitles(.init(spread: limit(.less, 1))).isEmpty)
        check("spread exactly a number lists the albums with just that spread", mixedTitles(.init(spread: limit(.equal, widest))) == expected { $0.yearSpread == widest } && !mixedTitles(.init(spread: limit(.equal, widest))).isEmpty)
        check("differing tracks more than, fewer than and exactly work the same way", mixedTitles(.init(tracks: limit(.greater, mostTracks - 1))) == expected { $0.trackDifferences.count > mostTracks - 1 } && mixedTitles(.init(tracks: limit(.less, mostTracks))) == expected { $0.trackDifferences.count < mostTracks } && mixedTitles(.init(tracks: limit(.equal, mostTracks))) == expected { $0.trackDifferences.count == mostTracks } && mixedTitles(.init(tracks: limit(.greater, mostTracks))).isEmpty, "most \(mostTracks)")
        check("both conditions must hold: few tracks far apart is a different list from many tracks far apart", mixedTitles(.init(spread: limit(.greater, 0), tracks: limit(.less, mostTracks))) == expected { $0.trackDifferences.count < mostTracks } && mixedTitles(.init(spread: limit(.greater, widest), tracks: limit(.greater, 0))).isEmpty && mixedTitles(.init(spread: limit(.equal, widest), tracks: limit(.less, 1))).isEmpty)
        check("few tracks far apart and many tracks far apart together are every album that is far apart (with the split at one number)", { let few = mixedTitles(.init(spread: limit(.greater, 1), tracks: limit(.less, 3))), many = mixedTitles(.init(spread: limit(.greater, 1), tracks: limit(.greater, 2))); return few.isDisjoint(with: many) && few.union(many) == expected { $0.yearSpread > 1 } }())
        let strictest = ReleaseYearAudit.MixedYearsCriteria(spread: limit(.greater, widest), tracks: .init())
        check("the conditions narrow only the Mixed years list, not the others", ReleaseYearAudit.listed(first.rows, filter: .musicVaries, decisions: [:], mixed: strictest).isEmpty && ReleaseYearAudit.listed(first.rows, filter: .all, decisions: [:], mixed: strictest).map(\.albumKey) == ReleaseYearAudit.listed(first.rows, filter: .all, decisions: [:]).map(\.albumKey))
        check("fewer than or exactly nothing is not offered (it could never hold), and more than 0 stays as it is", limit(.less, 0).normalized.value == 1 && limit(.equal, 0).normalized.value == 1 && limit(.greater, 0).normalized.value == 0 && limit(.greater, -3).normalized.value == 0)
        let oldOptions = try? JSONDecoder().decode(ReleaseYearAuditView.Options.self, from: Data(#"{"filter":"musicVaries","sort":"plays","hasRun":true}"#.utf8))
        check("saved options from before the conditions existed read, with the conditions off", oldOptions?.filter == .musicVaries && oldOptions?.mixed.isDefault == true)
        let firstVersion = try? JSONDecoder().decode(ReleaseYearAuditView.Options.self, from: Data(#"{"filter":"musicVaries","mixed":{"minSpread":3,"minTracks":2}}"#.utf8))
        check("the first version's plain minimums read as the same thing (at least 3 is more than 2)", firstVersion?.mixed.spread == limit(.greater, 2) && firstVersion?.mixed.tracks == limit(.greater, 1) && mixedRows.allSatisfy { firstVersion?.mixed.accepts($0) == ($0.yearSpread >= 3 && $0.trackDifferences.count >= 2) })
        let roundTrip = (try? JSONEncoder().encode({ var o = ReleaseYearAuditView.Options(); o.mixed = .init(spread: limit(.greater, 2), tracks: limit(.less, 3)); return o }())).flatMap { try? JSONDecoder().decode(ReleaseYearAuditView.Options.self, from: $0) }
        check("the conditions are saved with the other options", roundTrip?.mixed == .init(spread: limit(.greater, 2), tracks: limit(.less, 3)))

        // Using Music's years for the tracks.
        var result = try ReleaseYearAuditActions.useAppleYearsForTracks(comp.map { [$0] } ?? [], context: context)
        check("the tracks shown at the album's year are set to Music's: Old One and the curly-apostrophe track", result.tracksSet == 2 && result.albums == 1 && stored("Old One")?.releaseDateOverride == "1953" && stored("Don't Stop")?.releaseDateOverride == "1960", "\(result) \(String(describing: stored("Don't Stop")?.releaseDateOverride))")
        check("a track with a date of your own is left alone", result.skippedOwnDate == 1 && result.skippedNoTrack == 0 && stored("Mine")?.releaseDateOverride == "1999" && stored("It's Mine Too")?.releaseDateOverride == "1971")
        check("one decision remembers it, with the tracks and no change to the album", decisionCount() == 1)
        let used = try context.fetch(FetchDescriptor<ReleaseYearDecision>()).first
        let changes = used?.trackChangesJSON.flatMap { try? JSONDecoder().decode([ReleaseYearAudit.TrackChange].self, from: $0) } ?? []
        check("…as tracks only: the album's date is untouched and each track's earlier date (none) is kept", used?.albumChanged == false && changes.count == 2 && changes.allSatisfy { $0.previous == nil } && ReleaseDateEngine.albumRow(context: context, artist: "Artist A", album: "Comp")?.releaseDateOverride == nil)
        check("the Decisions list says what it did", used.map(ReleaseYearAuditActions.summary(of:)) == "Used Apple Music’s years for 2 tracks’ years")
        let afterApply = await analyse()
        check("those tracks then agree with Music: only the one with a date of your own still differs", Set(row("Comp", afterApply)?.trackDifferences.map(\.name) ?? []) == ["Mine"], "\(String(describing: row("Comp", afterApply)?.trackDifferences.map(\.name)))")
        if let used { try ReleaseYearAuditActions.undo(used, context: context) }
        check("undoing puts each track's earlier date back (none) and removes the decision", stored("Old One")?.releaseDateOverride == nil && stored("Don't Stop")?.releaseDateOverride == nil && stored("Mine")?.releaseDateOverride == "1999" && decisionCount() == 0)

        // A track with no row (rows computed without knowing which tracks were played) is skipped, not invented.
        let loadedForGuard = await ReleaseYearAuditStoreReader(modelContainer: container).load()
        let unguarded = ReleaseYearAudit.compare(music: music, albums: loadedForGuard.albums, trackOverrides: loadedForGuard.trackOverrides, trackOverrideIndex: loadedForGuard.trackOverrideIndex)
        let guarded = try ReleaseYearAuditActions.useAppleYearsForTracks(unguarded.rows.filter { $0.scroblytics.title == "Comp" }, context: context)
        check("a track with no row here is left alone and counted, not created", guarded.skippedNoTrack == 2 && guarded.tracksSet == 2 && stored("Never Played") == nil && stored("Also Unplayed") == nil, "\(guarded)")
        for item in try context.fetch(FetchDescriptor<ReleaseYearDecision>()) { try ReleaseYearAuditActions.undo(item, context: context) }

        // A track you have changed since is not undone over your change.
        let again = try ReleaseYearAuditActions.useAppleYearsForTracks([row("Comp", await analyse())!], context: context)
        check("applying again after an undo works the same", again.tracksSet == 2)
        stored("Old One")?.releaseDateOverride = "1954"
        try context.save()
        if let d = try context.fetch(FetchDescriptor<ReleaseYearDecision>()).first { try ReleaseYearAuditActions.undo(d, context: context) }
        check("undoing leaves a track date you changed after that alone, and still restores the other", stored("Old One")?.releaseDateOverride == "1954" && stored("Don't Stop")?.releaseDateOverride == nil)
        stored("Old One")?.releaseDateOverride = nil
        try context.save()

        // The album's date and its tracks, in either order, are one decision and one undo.
        let albumFirst = row("Comp", await analyse())!
        _ = try ReleaseYearAuditActions.useAppleYear([albumFirst], context: context)
        _ = try ReleaseYearAuditActions.useAppleYearsForTracks([row("Comp", await analyse())!], context: context)
        var merged = try context.fetch(FetchDescriptor<ReleaseYearDecision>())
        let mergedChanges = merged.first?.trackChangesJSON.flatMap { try? JSONDecoder().decode([ReleaseYearAudit.TrackChange].self, from: $0) } ?? []
        check("changing the album and then its tracks is one decision that remembers both, with the album's original date", merged.count == 1 && merged[0].albumChanged == true && merged[0].previousOverride == nil && merged[0].scroblyticsYear == 2004 && mergedChanges.count == 2, "\(merged.count) \(String(describing: merged.first?.previousOverride)) \(mergedChanges.count)")
        try ReleaseYearAuditActions.undo(merged[0], context: context)
        check("undoing it puts the album's date and every track's date back", ReleaseDateEngine.albumRow(context: context, artist: "Artist A", album: "Comp")?.releaseDateOverride == nil && stored("Old One")?.releaseDateOverride == nil && stored("Don't Stop")?.releaseDateOverride == nil)
        _ = try ReleaseYearAuditActions.useAppleYearsForTracks([row("Comp", await analyse())!], context: context)
        _ = try ReleaseYearAuditActions.useAppleYear([row("Comp", await analyse())!], context: context)
        merged = try context.fetch(FetchDescriptor<ReleaseYearDecision>())
        check("…and the other way round (tracks, then the album) is the same one decision", merged.count == 1 && merged[0].albumChanged == true && (merged[0].trackChangesJSON != nil) && merged[0].scroblyticsYear == 2004)
        try ReleaseYearAuditActions.undo(merged[0], context: context)
        check("…which undoes the same way", ReleaseDateEngine.albumRow(context: context, artist: "Artist A", album: "Comp")?.releaseDateOverride == nil && stored("Old One")?.releaseDateOverride == nil)

        // Several albums at once.
        let all = await analyse()
        result = try ReleaseYearAuditActions.useAppleYearsForTracks(ReleaseYearAudit.mixedYears(all.rows, decisions: [:]), context: context)
        check("several albums at once: every eligible track is set, and each album gets its own decision", result.albums == 2 && result.tracksSet == 4 && decisionCount() == 2, "\(result) \(decisionCount())")

        // Choosing Music's year on one album whose tracks span years sets the album and every track that shows the album's date, in one go.
        for item in try context.fetch(FetchDescriptor<ReleaseYearDecision>()) { try ReleaseYearAuditActions.undo(item, context: context) }
        let compNow = row("Comp", await analyse())!
        // 1953 is the most common year on this album (two tracks), and Old One already has it.
        let combined = try ReleaseYearAuditActions.useAppleYear([compNow], tracksOfVaried: true, context: context)
        check("the album gets the most common year and the tracks that show another get their own, in one action", combined.applied == 1 && combined.tracksSet == 2 && ReleaseDateEngine.albumRow(context: context, artist: "Artist A", album: "Comp")?.releaseDateOverride == "1953" && stored("Don't Stop")?.releaseDateOverride == "1960" && stored("Same")?.releaseDateOverride == "2004", "\(combined)")
        check("a track already at the album's new year is left to inherit it, and one you gave a date of your own keeps it", stored("Old One")?.releaseDateOverride == nil && stored("Mine")?.releaseDateOverride == "1999" && stored("It's Mine Too")?.releaseDateOverride == "1971")
        let combinedDecisions = try context.fetch(FetchDescriptor<ReleaseYearDecision>())
        check("it is one decision covering the album and the tracks", combinedDecisions.count == 1 && combinedDecisions[0].albumChanged == true && combinedDecisions[0].trackChangesJSON != nil, "\(combinedDecisions.count)")
        try ReleaseYearAuditActions.undo(combinedDecisions[0], context: context)
        check("one undo puts the album and every track back", ReleaseDateEngine.albumRow(context: context, artist: "Artist A", album: "Comp")?.releaseDateOverride == nil && stored("Don't Stop")?.releaseDateOverride == nil && stored("Same")?.releaseDateOverride == nil && stored("Mine")?.releaseDateOverride == "1999")
        let plainBatch = try ReleaseYearAuditActions.useAppleYear([compNow], skipVaries: true, tracksOfVaried: false, context: context)
        check("in a batch such an album is still skipped, tracks and all", plainBatch.skippedVaries == 1 && plainBatch.tracksSet == 0 && stored("Don't Stop")?.releaseDateOverride == nil)
        check("without the option the album alone is set, as before", try ReleaseYearAuditActions.useAppleYear([compNow], context: context).tracksSet == 0 && stored("Don't Stop")?.releaseDateOverride == nil)
        for item in try context.fetch(FetchDescriptor<ReleaseYearDecision>()) { try ReleaseYearAuditActions.undo(item, context: context) }

        // A song on two of the albums changed together is set once, for the first.
        insertAlbum("Share A", detected: "2004"); insertAlbum("Share B", detected: "2004")
        insertTrack("Shared Song"); insertTrack("Filler A"); insertTrack("Filler B")
        try context.save()
        let sharedMusic = [track("Shared Song", "Artist A", "Share A", 1962), track("Filler A", "Artist A", "Share A", 1980), track("Shared Song", "Artist A", "Share B", 1962), track("Filler B", "Artist A", "Share B", 1985)]
        let loadedShared = await ReleaseYearAuditStoreReader(modelContainer: container).load()
        let sharedReport = ReleaseYearAudit.compare(music: sharedMusic, albums: loadedShared.albums, trackOverrides: loadedShared.trackOverrides, trackOverrideIndex: loadedShared.trackOverrideIndex, knownTracks: loadedShared.known)
        let shared = try ReleaseYearAuditActions.useAppleYearsForTracks(sharedReport.rows.filter { $0.scroblytics.title.hasPrefix("Share") }, context: context)
        check("a song on two of the albums changed together is set once, and the second album says so instead of calling it your date", shared.tracksSet == 3 && shared.albums == 2 && shared.skippedShared == 1 && shared.skippedOwnDate == 0 && stored("Shared Song")?.releaseDateOverride == "1962", "\(shared)")

        // Keeping Scroblytics' dates for a compilation holds while the same tracks differ the same way.
        for item in try context.fetch(FetchDescriptor<ReleaseYearDecision>()) { try ReleaseYearAuditActions.undo(item, context: context) }
        let fresh = row("Comp", await analyse())!
        _ = try ReleaseYearAuditActions.keepMine([fresh], context: context)
        let kept = try context.fetch(FetchDescriptor<ReleaseYearDecision>()).first
        check("keeping a compilation records which of its tracks differed", kept?.tracksSignature == ReleaseYearAudit.tracksSignature(fresh.trackDifferences) && kept?.tracksSignature?.isEmpty == false)
        func decisions() throws -> [String: ReleaseYearAudit.Decision] {
            Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<ReleaseYearDecision>()).map { ($0.albumKey, ReleaseYearAudit.Decision(albumKey: $0.albumKey, verdict: .init(rawValue: $0.verdict)!, scroblyticsYear: $0.scroblyticsYear, musicYear: $0.musicYear, tracksSignature: $0.tracksSignature ?? "")) })
        }
        check("it leaves the Mixed years list", !ReleaseYearAudit.mixedYears(await analyse().rows, decisions: try decisions()).contains { $0.scroblytics.title == "Comp" })
        let changedMusic = music.map { $0.name == "Old One" ? track("Old One", "Artist A", "Comp", 1954) : $0 }
        let loaded = await ReleaseYearAuditStoreReader(modelContainer: container).load()
        let changedReport = ReleaseYearAudit.compare(music: changedMusic, albums: loaded.albums, trackOverrides: loaded.trackOverrides, trackOverrideIndex: loaded.trackOverrideIndex, knownTracks: loaded.known)
        check("…and comes back when Music's year for one of its tracks changes", ReleaseYearAudit.mixedYears(changedReport.rows, decisions: try decisions()).contains { $0.scroblytics.title == "Comp" })
        check("the fingerprint doesn't depend on the order of the tracks, and is empty for none", ReleaseYearAudit.tracksSignature(fresh.trackDifferences) == ReleaseYearAudit.tracksSignature(fresh.trackDifferences.reversed()) && ReleaseYearAudit.tracksSignature([]) == "")

        // The backup keeps all of it.
        for item in try context.fetch(FetchDescriptor<ReleaseYearDecision>()) { try ReleaseYearAuditActions.undo(item, context: context) }
        _ = try ReleaseYearAuditActions.useAppleYear([row("Comp", await analyse())!], context: context)
        _ = try ReleaseYearAuditActions.useAppleYearsForTracks([row("Comp", await analyse())!], context: context)
        _ = try ReleaseYearAuditActions.keepMine([row("Other Comp", await analyse())!], context: context)
        let document = try NativeBackupEngine.makeDocument(context: context)
        let (archive, _) = try NativeBackupEngine.inspect(document: document)
        for item in try context.fetch(FetchDescriptor<ReleaseYearDecision>()) { context.delete(item) }
        try context.save()
        try NativeBackupEngine.restoreReleaseYearDecisions(archive.releaseYearDecisions, context: context)
        let restored = try context.fetch(FetchDescriptor<ReleaseYearDecision>())
        let used2 = restored.first { $0.album == "Comp" }, kept2 = restored.first { $0.album == "Other Comp" }
        check("a backup keeps what each decision changed: the tracks' earlier dates, whether the album was changed, and which tracks differed", restored.count == 2 && used2?.albumChanged == true && used2?.trackChangesJSON != nil && kept2?.tracksSignature?.isEmpty == false)
        if let used2 { try ReleaseYearAuditActions.undo(used2, context: context) }
        check("and a restored decision still undoes everything it did", ReleaseDateEngine.albumRow(context: context, artist: "Artist A", album: "Comp")?.releaseDateOverride == nil && stored("Old One")?.releaseDateOverride == nil)
        if let old = try? JSONSerialization.jsonObject(with: document.data) as? [String: Any], var records = old["releaseYearDecisions"] as? [[String: Any]] {
            for i in records.indices { records[i].removeValue(forKey: "tracksSignature"); records[i].removeValue(forKey: "albumChanged"); records[i].removeValue(forKey: "trackChangesJSON") }
            var json = old; json["releaseYearDecisions"] = records
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let decoded = try? decoder.decode(NativeBackupFormat.Archive.self, from: try JSONSerialization.data(withJSONObject: json))
            check("a backup made before tracks were compared still decodes", decoded?.releaseYearDecisions?.count == archive.releaseYearDecisions?.count && decoded?.releaseYearDecisions?.first?.trackChangesJSON == nil)
        }
    }

    /// A report with one uniform album and one compilation whose tracks all agree: nothing to list.
    private static func analyseSample() -> [ReleaseYearAudit.AlbumRow] {
        let albums = [album("Artist A", "Uniform", "2001"), album("Artist A", "Agreeing", "1990")]
        let music = [track("a", "Artist A", "Uniform", 2000), track("b", "Artist A", "Uniform", 2000), track("c", "Artist A", "Agreeing", 1990), track("d", "Artist A", "Agreeing", 1990)]
        return ReleaseYearAudit.compare(music: music, albums: albums).rows
    }

    /// Music's tracks for the action checks: the same albums as `sampleReport`.
    private static func sampleMusic() -> [AppleMusicTrackYear] {
        var music: [AppleMusicTrackYear] = []
        music += [track("x", "Artist A", "One Off", 2002)]
        music += [track("x", "Artist A", "Far Off", 1971)]
        music += [track("x", "Artist A", "Mine", 1969)]
        music += [track("a", "Artist A", "Compilation", 1953), track("b", "Artist A", "Compilation", 1953), track("c", "Artist A", "Compilation", 1980)]
        music += [track("x", "Artist A", "Late", 2009)]
        return music
    }

    // MARK: - Bringing Music's years into line

    private static func musicTrack(_ name: String, _ year: Int?, id: String, album: String = "Album", own: Int? = nil) -> (AppleMusicTrackYear, Int?) {
        (AppleMusicTrackYear(name: name, artist: "Artist A", albumArtist: "Artist A", album: album, year: year, persistentID: id), own)
    }

    private static func musicUpdateChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        // A uniform album: Scroblytics says 2007, Music says 2006 on every track.
        let uniform = ReleaseYearAudit.compare(
            music: ["a", "b", "c"].enumerated().map { AppleMusicTrackYear(name: $1, artist: "Artist A", albumArtist: "Artist A", album: "Back", year: 2006, persistentID: "U\($0)") },
            albums: [album("Artist A", "Back", "2007")]
        ).rows[0]
        let updates = ReleaseYearAudit.musicUpdates(for: uniform, albumYear: nil)
        check("keeping Scroblytics' year changes every track of the album in Music to it", updates.count == 3 && updates.allSatisfy { $0.from == 2006 && $0.to == 2007 && $0.album == "Back" })
        check("a different year chosen by hand (an edit) is what the tracks are changed to", ReleaseYearAudit.musicUpdates(for: uniform, albumYear: 2005).allSatisfy { $0.to == 2005 })
        check("an album that already agrees has nothing to change", ReleaseYearAudit.musicUpdates(for: ReleaseYearAudit.compare(music: [AppleMusicTrackYear(name: "x", artist: "Artist A", albumArtist: "Artist A", album: "Same", year: 2001, persistentID: "S")], albums: [album("Artist A", "Same", "2001")]).rows[0], albumYear: nil).isEmpty)

        // A track you gave a date of your own keeps it, whatever the album's year is; a track with no year in Music gets one.
        let own = ReleaseYearAudit.compare(
            music: [AppleMusicTrackYear(name: "plain", artist: "Artist A", albumArtist: "Artist A", album: "Mixed", year: 2006, persistentID: "P"),
                    AppleMusicTrackYear(name: "mine", artist: "Artist A", albumArtist: "Artist A", album: "Mixed", year: 2006, persistentID: "M"),
                    AppleMusicTrackYear(name: "blank", artist: "Artist A", albumArtist: "Artist A", album: "Mixed", year: nil, persistentID: "B")],
            albums: [album("Artist A", "Mixed", "2007")],
            trackOverrides: [TextNormalization.lovedKey(artist: "Artist A", track: "mine"): "1999"]
        ).rows[0]
        let mixed = Dictionary(uniqueKeysWithValues: ReleaseYearAudit.musicUpdates(for: own, albumYear: nil).map { ($0.persistentID, $0) })
        check("each track gets the year Scroblytics shows for it: its own date if it has one, else the album's, and one with no year gets one", mixed["P"]?.to == 2007 && mixed["M"]?.to == 1999 && mixed["B"]?.to == 2007 && mixed["B"]?.from == nil)

        // A compilation: Music's years are real, so only tracks you set a date on are brought into line.
        let comp = ReleaseYearAudit.compare(
            music: [AppleMusicTrackYear(name: "old", artist: "Artist A", albumArtist: "Artist A", album: "Hits", year: 1965, persistentID: "H1"),
                    AppleMusicTrackYear(name: "newer", artist: "Artist A", albumArtist: "Artist A", album: "Hits", year: 1970, persistentID: "H2"),
                    AppleMusicTrackYear(name: "chosen", artist: "Artist A", albumArtist: "Artist A", album: "Hits", year: 1968, persistentID: "H3")],
            albums: [album("Artist A", "Hits", "1972")],
            trackOverrides: [TextNormalization.lovedKey(artist: "Artist A", track: "chosen"): "1999"]
        ).rows[0]
        let compUpdates = ReleaseYearAudit.musicUpdates(for: comp, albumYear: nil)
        check("a compilation's years in Music are not overwritten with the album's year; only a track you set a date on follows it", comp.musicVaries && compUpdates.map(\.persistentID) == ["H3"] && compUpdates.first?.to == 1999)
        check("a track list is shown only for an album whose tracks differ among themselves in Music, not for one whose every track differs just because the album's year does", !uniform.trackDifferences.isEmpty && !ReleaseYearAuditRowView.showsTrackDetails(uniform) && !comp.trackDifferences.isEmpty && ReleaseYearAuditRowView.showsTrackDetails(comp))
        // The same compilation, when you chose that one album yourself: every track follows, and the prompt can say so.
        let chosen = ReleaseYearAudit.musicUpdates(for: comp, albumYear: nil, includeVaried: true)
        check("an album you chose yourself is offered in full even when its tracks span years: every track but the one with a date of your own gets the album's year", Set(chosen.map(\.persistentID)) == ["H1", "H2", "H3"] && chosen.first { $0.persistentID == "H1" }?.to == 1972 && chosen.first { $0.persistentID == "H3" }?.to == 1999)
        // The Bachelor-No.-2 shape: nine tracks at one year, four at the next, and the album at the later one.
        let near = ReleaseYearAudit.compare(
            music: (0..<13).map { AppleMusicTrackYear(name: "t\($0)", artist: "Artist A", albumArtist: "Artist A", album: "Near", year: $0 < 9 ? 1999 : 2000, persistentID: "N\($0)") },
            albums: [album("Artist A", "Near", "2000")]
        ).rows[0]
        check("an album whose years are close but not equal still offers the tracks that differ (9 of 13) when chosen alone, and nothing in a batch", near.musicVaries && ReleaseYearAudit.musicUpdates(for: near, albumYear: nil, includeVaried: true).count == 9 && ReleaseYearAudit.musicUpdates(for: near, albumYear: nil).isEmpty)
        check("a track Music gave no ID is never offered (there would be no way to find it)", ReleaseYearAudit.musicUpdates(for: ReleaseYearAudit.compare(music: [AppleMusicTrackYear(name: "x", artist: "Artist A", albumArtist: "Artist A", album: "NoID", year: 2000)], albums: [album("Artist A", "NoID", "2005")]).rows[0], albumYear: nil).isEmpty)
    }

    /// A stand-in for Music with made-up tracks.
    private final class FakeMusicYears: MusicYearBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var tracks: [String: MusicTrackState]
        var running = true
        /// Tracks that ignore a change, as a streaming track Music can't edit does.
        var readOnly: Set<String> = []
        private(set) var writes: [String] = []
        init(_ tracks: [String: MusicTrackState]) { self.tracks = tracks }
        var isMusicRunning: Bool { running }
        func currentTrack(persistentID: String) async throws -> MusicTrackState? { lock.withLock { tracks[persistentID] } }
        func setYear(persistentID: String, year: Int) async throws {
            lock.withLock {
                writes.append(persistentID)
                if !readOnly.contains(persistentID), let t = tracks[persistentID] { tracks[persistentID] = MusicTrackState(name: t.name, artist: t.artist, year: year) }
            }
        }
        func year(_ id: String) -> Int? { lock.withLock { tracks[id]?.year } }
        func rename(_ id: String, to name: String) { lock.withLock { if let t = tracks[id] { tracks[id] = MusicTrackState(name: name, artist: t.artist, year: t.year) } } }
        func setSilently(_ id: String, year: Int?) { lock.withLock { if let t = tracks[id] { tracks[id] = MusicTrackState(name: t.name, artist: t.artist, year: year) } } }
    }

    @MainActor
    private static func writerChecks(_ report: (String, Bool, String) -> Void) async {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        func update(_ id: String, _ name: String, from: Int?, to: Int) -> ReleaseYearAudit.MusicYearUpdate {
            ReleaseYearAudit.MusicYearUpdate(persistentID: id, name: name, artist: "Artist A", album: "Album", from: from, to: to)
        }
        func fresh() -> FakeMusicYears {
            FakeMusicYears([
                "1": MusicTrackState(name: "One", artist: "Artist A", year: 2006), "2": MusicTrackState(name: "Two", artist: "Artist A", year: 2006),
                "3": MusicTrackState(name: "Three", artist: "Artist A", year: nil), "4": MusicTrackState(name: "Four", artist: "Artist A", year: 2006),
            ])
        }
        let plan = [update("1", "One", from: 2006, to: 2007), update("2", "Two", from: 2006, to: 2007), update("3", "Three", from: nil, to: 2007)]

        var music = fresh()
        var results = await AppleMusicYearWriter.apply(plan, backend: music)
        check("each track is changed to the year asked, once, and read back", results.allSatisfy { $0.outcome == .updated } && ["1", "2", "3"].allSatisfy { music.year($0) == 2007 } && music.writes == ["1", "2", "3"], "\(results.map(\.outcome))")
        check("a track that was not in the list is never touched", music.year("4") == 2006)
        check("the summary says what happened", AppleMusicYearWriter.summary(results) == "Changed the year of 3 tracks in Apple Music.")

        music = fresh()
        results = await AppleMusicYearWriter.apply(plan, dryRun: true, backend: music)
        check("a dry run finds and matches every track and changes nothing", results.allSatisfy { $0.outcome == .wouldUpdate } && music.writes.isEmpty && music.year("1") == 2006)

        music = fresh()
        music.rename("2", to: "Two (Remastered)")
        music.setSilently("3", year: 1999)
        results = await AppleMusicYearWriter.apply(plan + [update("9", "Ghost", from: 2000, to: 2001)], backend: music)
        check("a track renamed since is left alone and says what it is called now", results[1].outcome == .mismatch("Two (Remastered) / Artist A") && music.year("2") == 2006)
        check("a track whose year was changed in Music since is left alone, not overwritten", results[2].outcome == .changedSince(1999) && music.year("3") == 1999)
        check("a track Music no longer has is reported, not invented", results[3].outcome == .notFound && results[0].outcome == .updated)
        check("the summary counts each kind", AppleMusicYearWriter.summary(results).contains("Changed the year of 1 track") && AppleMusicYearWriter.summary(results).contains("1 left alone because their year in Music had changed") && AppleMusicYearWriter.summary(results).contains("1 left alone because they are named differently") && AppleMusicYearWriter.summary(results).contains("1 not found"), AppleMusicYearWriter.summary(results))

        music = fresh()
        music.readOnly = ["2"]
        results = await AppleMusicYearWriter.apply(plan, backend: music)
        check("a track Music won't change is reported as not changed, not assumed", { if case .failed = results[1].outcome { true } else { false } }() && results[0].outcome == .updated && results[2].outcome == .updated)
        check("…and the summary says so", AppleMusicYearWriter.summary(results).contains("1 couldn’t be changed"), AppleMusicYearWriter.summary(results))

        music = fresh()
        music.running = false
        results = await AppleMusicYearWriter.apply(plan, backend: music)
        check("with Music closed nothing is attempted and the summary says to open it", results.allSatisfy { $0.outcome == .musicNotRunning } && music.writes.isEmpty && AppleMusicYearWriter.summary(results).contains("Music isn’t open"))
        check("an empty list does nothing", await AppleMusicYearWriter.apply([], backend: fresh()).isEmpty)

        // Stopping part-way leaves the rest alone.
        music = fresh()
        let many = (0..<40).map { update("1", "One", from: $0 == 0 ? 2006 : 2007, to: 2007) }
        let runner = Task { await AppleMusicYearWriter.apply(many, backend: music, progress: { done, _ in if done == 3 { withUnsafeCurrentTask { $0?.cancel() } } }) }
        let stopped = await runner.value
        check("stopping part-way marks the rest as not attempted and says so", stopped.count == 40 && stopped.last?.outcome == .notAttempted && AppleMusicYearWriter.summary(stopped).contains("stopped before"), "\(stopped.filter { $0.outcome == .notAttempted }.count)")
        check("an estimate is given only when the change will take a while", AppleMusicYearWriter.estimate(tracks: 12) == nil && AppleMusicYearWriter.estimate(tracks: 300) == "about a minute" && AppleMusicYearWriter.estimate(tracks: 3000) == "about 10 minutes")
    }

    @MainActor
    private static func liveRead() async throws {
        let all = try await AppleMusicYearReader.read()
        let withYear = all.filter { $0.year != nil && !$0.persistentID.isEmpty }
        let step = max(1, withYear.count / 20)
        let sample = stride(from: 0, to: withYear.count, by: step).map { withYear[$0] }
        let backend = AppleScriptMusicYearBackend()
        var failures = 0
        var agreeing = 0
        let started = Date()
        for track in sample {
            let now = try await backend.currentTrack(persistentID: track.persistentID)
            if now == MusicTrackState(name: track.name, artist: track.artist, year: track.year) { agreeing += 1 } else {
                failures += 1
                print("DIFFERENT: \(track.persistentID) bulk \(track.name)/\(track.artist)/\(String(describing: track.year)) one-by-one \(String(describing: now))")
            }
        }
        print("LIVE READ: \(sample.count) tracks sampled across \(withYear.count); \(agreeing) read one by one exactly as the bulk read said (\((Date().timeIntervalSince(started) / Double(max(sample.count, 1)) * 1000).formatted(.number.precision(.fractionLength(0)))) ms each)")
        let plan = sample.map { ReleaseYearAudit.MusicYearUpdate(persistentID: $0.persistentID, name: $0.name, artist: $0.artist, album: $0.album, from: $0.year, to: ($0.year ?? 2000) + 1) }
        let dry = await AppleMusicYearWriter.apply(plan, dryRun: true)
        print("DRY RUN: \(dry.filter { $0.outcome == .wouldUpdate }.count) of \(dry.count) would be changed; outcomes: \(Dictionary(grouping: dry, by: { "\($0.outcome)" }).mapValues(\.count))")
        let stale = await AppleMusicYearWriter.apply(plan.prefix(3).map { ReleaseYearAudit.MusicYearUpdate(persistentID: $0.persistentID, name: $0.name, artist: $0.artist, album: $0.album, from: ($0.from ?? 0) + 5, to: $0.to) }, dryRun: true)
        print("STALE LIST: a wrong 'from' year is refused for all \(stale.count): \(stale.allSatisfy { if case .changedSince = $0.outcome { true } else { false } })")
        let wrongName = await AppleMusicYearWriter.apply(plan.prefix(3).map { ReleaseYearAudit.MusicYearUpdate(persistentID: $0.persistentID, name: $0.name + " x", artist: $0.artist, album: $0.album, from: $0.from, to: $0.to) }, dryRun: true)
        print("WRONG NAME: refused for all \(wrongName.count): \(wrongName.allSatisfy { if case .mismatch = $0.outcome { true } else { false } })")
        let missing = await AppleMusicYearWriter.apply([ReleaseYearAudit.MusicYearUpdate(persistentID: "0000000000000000", name: "x", artist: "x", album: "x", from: 1, to: 2)], dryRun: true)
        print("NO SUCH TRACK: \(missing.first?.outcome == .notFound ? "reported as not found" : "UNEXPECTED \(String(describing: missing.first?.outcome))")")
        HeadlessTask.finish(failures)
    }

    @MainActor
    private static func liveWrite(persistentID: String, confirmed: Bool) async throws {
        let backend = AppleScriptMusicYearBackend()
        guard let now = try await backend.currentTrack(persistentID: persistentID), let year = now.year else { print("no such track, or it has no year"); HeadlessTask.finish(1) }
        let update = ReleaseYearAudit.MusicYearUpdate(persistentID: persistentID, name: now.name, artist: now.artist, album: "", from: year, to: year)
        let dry = await AppleMusicYearWriter.apply([update], dryRun: true)
        print("DRY RUN on “\(now.name)” (\(year)): \(dry[0].outcome)")
        guard confirmed else { print("not written (no confirmation given)"); HeadlessTask.finish(0) }
        let real = await AppleMusicYearWriter.apply([update], dryRun: false)
        print("WRITE (to the year it already has): \(real[0].outcome)")
        HeadlessTask.finish(real[0].outcome == .updated ? 0 : 1)
    }

    // MARK: - The real library, read-only

    /// On a store COPY only: use Music's year for every album that disagrees, check they then agree, undo every decision, and check
    /// every album date is back exactly as it was.
    @MainActor
    private static func applyAndUndo(container: ModelContainer, music: [AppleMusicTrackYear], report: ReleaseYearAudit.Report) async throws {
        let context = container.mainContext
        func dates() throws -> [String: String] {
            Dictionary(try context.fetch(FetchDescriptor<Album>()).map { ($0.identityKey, "\($0.releaseDateOverride ?? "-")|\($0.releaseDateDetected ?? "-")|\($0.releaseDateSource ?? "-")") }, uniquingKeysWith: { first, _ in first })
        }
        let before = try dates()
        let open = ReleaseYearAudit.listed(report.rows, filter: .all, decisions: [:])
        let result = try ReleaseYearAuditActions.useAppleYear(open, skipVaries: true, context: context)
        let changed = try dates().filter { before[$0.key] != $0.value }.count
        print("APPLY: \(open.count) listed; applied \(result.applied), skipped (tracks span years) \(result.skippedVaries), couldn't \(result.skipped); album rows that changed \(changed)")
        let loaded = await ReleaseYearAuditStoreReader(modelContainer: container).load()
        let after = ReleaseYearAudit.compare(music: music, albums: loaded.albums, trackOverrides: loaded.trackOverrides)
        let nowAgree = open.filter { row in after.rows.first { $0.albumKey == row.albumKey }?.category == .same }.count
        print("APPLY: of those, now agreeing with Music: \(nowAgree) (expected \(result.applied)); disagreements left: \(after.disagreements) (was \(report.disagreements))")
        let others = after.rows.filter { row in !open.contains { $0.albumKey == row.albumKey } }
        let othersBefore = report.rows.filter { row in !open.contains { $0.albumKey == row.albumKey } }
        print("APPLY: albums that were not listed are unchanged: \(others.map { "\($0.albumKey)|\($0.scroblytics.date ?? "-")" } == othersBefore.map { "\($0.albumKey)|\($0.scroblytics.date ?? "-")" })")
        for decision in try context.fetch(FetchDescriptor<ReleaseYearDecision>()) { try ReleaseYearAuditActions.undo(decision, context: context) }
        let restored = try dates()
        print("UNDO: every album's override, detected date and source back as before: \(restored == before); decisions left \(try context.fetch(FetchDescriptor<ReleaseYearDecision>()).count)")

        // The tracks of the compilations, then the albums and the tracks together.
        func trackDates() throws -> [String: String] {
            Dictionary(try context.fetch(FetchDescriptor<Track>()).compactMap { t in t.releaseDateOverride.map { (t.identityKey, $0) } }, uniquingKeysWith: { first, _ in first })
        }
        let tracksBefore = try trackDates()
        let compilations = ReleaseYearAudit.mixedYears(report.rows, decisions: [:])
        print("TRACKS: \(compilations.count) compilations listed with \(compilations.reduce(0) { $0 + $1.trackDifferences.count }) tracks that differ (\(compilations.reduce(0) { $0 + $1.trackDifferences.filter(\.ownDate).count }) have a date of your own); \(tracksBefore.count) tracks have their own date now")
        let trackResult = try ReleaseYearAuditActions.useAppleYearsForTracks(compilations, context: context)
        let tracksAfter = try trackDates()
        print("TRACKS: applied \(trackResult.tracksSet) tracks on \(trackResult.albums) albums; left \(trackResult.skippedOwnDate) with a date of your own, \(trackResult.skippedShared) shared with an album set earlier in the batch, \(trackResult.skippedNoTrack) with no track row; track dates went \(tracksBefore.count) → \(tracksAfter.count) (expected +\(trackResult.tracksSet): \(tracksAfter.count == tracksBefore.count + trackResult.tracksSet))")
        print("TRACKS: your own track dates unchanged: \(tracksBefore.allSatisfy { tracksAfter[$0.key] == $0.value })")
        let loaded2 = await ReleaseYearAuditStoreReader(modelContainer: container).load()
        let again = ReleaseYearAudit.compare(music: music, albums: loaded2.albums, trackOverrides: loaded2.trackOverrides, trackOverrideIndex: loaded2.trackOverrideIndex, knownTracks: loaded2.known)
        print("TRACKS: tracks still differing after: \(again.trackDifferences) (was \(report.trackDifferences)); album categories unchanged: \(again.rows.map(\.category) == report.rows.map(\.category))")
        for decision in try context.fetch(FetchDescriptor<ReleaseYearDecision>()) { try ReleaseYearAuditActions.undo(decision, context: context) }
        print("TRACKS UNDO: every track's own date back exactly as before: \(try trackDates() == tracksBefore); album dates too: \(try dates() == before)")

        let everything = ReleaseYearAudit.listed(report.rows, filter: .all, decisions: [:])
        _ = try ReleaseYearAuditActions.useAppleYear(everything, skipVaries: true, context: context)
        let loaded3 = await ReleaseYearAuditStoreReader(modelContainer: container).load()
        let mid = ReleaseYearAudit.compare(music: music, albums: loaded3.albums, trackOverrides: loaded3.trackOverrides, trackOverrideIndex: loaded3.trackOverrideIndex, knownTracks: loaded3.known)
        let bothResult = try ReleaseYearAuditActions.useAppleYearsForTracks(mid.rows.filter { !$0.trackDifferences.isEmpty }, context: context)
        print("BOTH: albums set, then \(bothResult.tracksSet) tracks on \(bothResult.albums) albums; decisions \(try context.fetch(FetchDescriptor<ReleaseYearDecision>()).count)")
        for decision in try context.fetch(FetchDescriptor<ReleaseYearDecision>()) { try ReleaseYearAuditActions.undo(decision, context: context) }
        print("BOTH UNDO: album dates exactly as before: \(try dates() == before); track dates exactly as before: \(try trackDates() == tracksBefore); decisions left \(try context.fetch(FetchDescriptor<ReleaseYearDecision>()).count)")
    }

    @MainActor
    private static func dump(container: ModelContainer) async throws {
        let music = try await AppleMusicYearReader.read()
        let loaded = await ReleaseYearAuditStoreReader(modelContainer: container).load()
        let report = ReleaseYearAudit.compare(music: music, albums: loaded.albums, trackOverrides: loaded.trackOverrides, trackOverrideIndex: loaded.trackOverrideIndex, knownTracks: loaded.known)
        // Plays: every album's count against a plain loop over the Scrobble rows that normalizes each play itself.
        var independent: [String: Int] = [:]
        for play in try container.mainContext.fetch(FetchDescriptor<Scrobble>()) where !play.albumName.isEmpty {
            independent[ReleaseYearAudit.albumKey(artistKey: TextNormalization.artistIdentityKey(play.artistName), normalizedTitle: TextNormalization.normalizeAlbumName(play.albumName)), default: 0] += 1
        }
        let mismatched = loaded.albums.filter { $0.plays != (independent[ReleaseYearAudit.albumKey(artistKey: $0.artistKey, normalizedTitle: $0.normalizedTitle)] ?? 0) }
        print("PLAYS: \(loaded.albums.count) albums, \(loaded.albums.filter { $0.plays > 0 }.count) with plays, \(loaded.albums.map(\.plays).reduce(0, +)) plays on them (\(independent.values.reduce(0, +)) plays have an album); albums whose count differs from the independent loop: \(mismatched.count)")
        let mixedAll = report.rows.filter { $0.musicVaries && !$0.trackDifferences.isEmpty }
        func mixedCount(_ c: ReleaseYearAudit.MixedYearsCriteria) -> String {
            let listed = ReleaseYearAudit.mixedYears(report.rows, decisions: [:], criteria: c).count
            return "\(listed)\(listed == mixedAll.filter { c.spread.holds($0.yearSpread) && c.tracks.holds($0.trackDifferences.count) }.count ? "" : " (MISMATCH)")"
        }
        func lim(_ c: ReleaseYearAudit.Limit.Comparison, _ v: Int) -> ReleaseYearAudit.Limit { .init(comparison: c, value: v) }
        print("MIXED: \(mixedAll.count) albums have mixed years; years spanned > 2: \(mixedCount(.init(spread: lim(.greater, 2)))); tracks differing < 3: \(mixedCount(.init(tracks: lim(.less, 3)))); tracks differing < 3 and years spanned > 2 (few tracks far apart): \(mixedCount(.init(spread: lim(.greater, 2), tracks: lim(.less, 3)))); tracks differing > 2 and years spanned > 2 (collections): \(mixedCount(.init(spread: lim(.greater, 2), tracks: lim(.greater, 2)))); tracks differing = 1: \(mixedCount(.init(tracks: lim(.equal, 1))))")
        let listedByPlays = ReleaseYearAudit.sorted(ReleaseYearAudit.listed(report.rows, filter: .all, decisions: [:]), by: .plays)
        print("PLAYS: listed albums by plays, first five: \(listedByPlays.prefix(5).map { "\($0.plays)×" + String($0.scroblytics.title.prefix(1)) + "…" }.joined(separator: ", ")); sorted non-increasing: \(zip(listedByPlays, listedByPlays.dropFirst()).allSatisfy { $0.plays >= $1.plays })")
        print("Music: \(report.musicTracks) tracks in \(report.musicAlbums) albums (\(report.musicTracksWithoutYear) tracks with no year); Scroblytics: \(loaded.albums.count) albums, \(loaded.trackOverrides.count) track dates")
        print("matched albums: \(report.matched); not matched: \(report.unmatchedMusicAlbums)")
        for category in ReleaseYearAudit.Category.allCases { print("  \(category.rawValue): \(report.count(category))") }
        let dupes = Dictionary(grouping: report.rows, by: \.albumKey).filter { $0.value.count > 1 }
        print("Scroblytics albums matched by more than one Music album: \(dupes.count)")
        for (_, group) in dupes.sorted(by: { $0.key < $1.key }).prefix(8) {
            print("   \(group[0].scroblytics.artist) — \(group[0].scroblytics.title): " + group.map { "[Music: \($0.musicArtist) — \($0.musicAlbum), \($0.trackCount) tracks, \($0.musicYear.map(String.init) ?? "-"), by \($0.matchedBy.rawValue)]" }.joined(separator: " "))
        }
        let byGap = Dictionary(grouping: report.rows.compactMap(\.gap).filter { $0 != 0 }, by: { abs($0) <= 2 ? (abs($0) == 1 ? "1 year" : "2 years") : "3+ years" })
        print("by size of gap: \(byGap.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.count)" }.joined(separator: ", ")); filters: 1–2 years \(report.count(band: .close)), 3+ years \(report.count(band: .far)) (= \(report.disagreements) disagreeing: \(report.count(band: .close) + report.count(band: .far) == report.disagreements))")
        let largest = ReleaseYearAudit.sorted(ReleaseYearAudit.listed(report.rows, filter: .all, decisions: [:]), by: .difference).prefix(3)
        print("largest differences first: \(largest.map { "\($0.scroblytics.title) (\($0.gap ?? 0))" }.joined(separator: "; "))")
        print("by artist, first three: \(ReleaseYearAudit.sorted(ReleaseYearAudit.listed(report.rows, filter: .all, decisions: [:]), by: .artist).prefix(3).map { "\($0.scroblytics.artist) — \($0.scroblytics.title)" }.joined(separator: "; "))")
        print("music tracks vary within the album: \(report.rows.filter(\.musicVaries).count)")
        print("albums with a track differing: \(report.albumsWithTrackDifferences); tracks differing: \(report.trackDifferences)")
        let uniform = report.rows.filter { !$0.musicVaries }
        print("Music-uniform albums that differ: \(uniform.filter { $0.category == .offByOne || $0.category == .differs }.count) (later in Scroblytics \(uniform.filter { ($0.gap ?? 0) > 0 }.count), earlier \(uniform.filter { ($0.gap ?? 0) < 0 }.count))")
        var byOrigin: [String: Int] = [:]
        for row in report.rows where row.category == .offByOne || row.category == .differs { byOrigin[row.scroblytics.origin.label, default: 0] += 1 }
        print("disagreeing albums by where the Scroblytics date came from: \(byOrigin.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
        var matchedBy: [String: Int] = [:]
        for row in report.rows { matchedBy[row.matchedBy.rawValue, default: 0] += 1 }
        print("matched by: \(matchedBy.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
        if let name = ProcessInfo.processInfo.environment["SCROBLYTICS_RELEASEYEAR_DUMP_ALBUM"]?.lowercased() {
            for row in report.rows where row.scroblytics.title.lowercased().contains(name) {
                let years = Dictionary(grouping: row.musicTracks.compactMap(\.musicYear), by: { $0 }).mapValues(\.count).sorted { $0.key < $1.key }
                let updates = ReleaseYearAudit.musicUpdates(for: row, albumYear: nil, includeVaried: true)
                let dry = await AppleMusicYearWriter.apply(updates, dryRun: true)
                print("   offered when chosen alone: \(updates.count) tracks to \(row.scroblytics.year.map(String.init) ?? "-"); dry run against the live Music (nothing written): \(Dictionary(grouping: dry, by: { "\($0.outcome)" }).mapValues(\.count)); in a batch: \(ReleaseYearAudit.musicUpdates(for: row, albumYear: nil).count)")
                print("ALBUM \(row.scroblytics.artist) — \(row.scroblytics.title): Scroblytics \(row.scroblytics.date ?? "-") (\(row.scroblytics.origin.label)); Music \(years.map { "\($0.key)×\($0.value)" }.joined(separator: " ")); varies \(row.musicVaries); category \(row.category.rawValue); Music updates it would offer: \(updates.count); tracks with a date of your own: \(row.musicTracks.filter { $0.ownYear != nil }.count)")
            }
        }
        if let name = ProcessInfo.processInfo.environment["SCROBLYTICS_RELEASEYEAR_DUMP_ALBUM_APPLY"]?.lowercased() {
            // On a store COPY: put the album back as it was before any decision, choose Music's year for it, check its tracks followed, undo.
            let context = container.mainContext
            func albumState() throws -> [String: String] {
                var state: [String: String] = [:]
                for a in try context.fetch(FetchDescriptor<Album>()) { state["A|" + a.identityKey] = a.releaseDateOverride ?? "-" }
                for t in try context.fetch(FetchDescriptor<Track>()) { state["T|" + t.identityKey] = t.releaseDateOverride ?? "-" }
                return state
            }
            for decision in try context.fetch(FetchDescriptor<ReleaseYearDecision>()) where decision.album.lowercased().contains(name) { try ReleaseYearAuditActions.undo(decision, context: context) }
            let start = try albumState()
            func current() async -> ReleaseYearAudit.AlbumRow? {
                let l = await ReleaseYearAuditStoreReader(modelContainer: container).load()
                return ReleaseYearAudit.compare(music: music, albums: l.albums, trackOverrides: l.trackOverrides, trackOverrideIndex: l.trackOverrideIndex, knownTracks: l.known).rows.first { $0.scroblytics.title.lowercased().contains(name) }
            }
            if let before = await current() {
                print("ALBUM APPLY: \(before.scroblytics.title): Scroblytics \(before.scroblytics.year.map(String.init) ?? "-"), Music \(before.musicYear.map(String.init) ?? "-") (\(before.musicEarliest.map(String.init) ?? "-")–\(before.musicLatest.map(String.init) ?? "-")); \(before.trackDifferences.count) tracks differ")
                let result = try ReleaseYearAuditActions.useAppleYear([before], tracksOfVaried: true, context: context)
                if let after = await current() {
                    let played = after.musicTracks.filter(\.inScroblytics).count
                    print("ALBUM APPLY: album now \(after.scroblytics.year.map(String.init) ?? "-"); \(result.tracksSet) track dates set (of \(played) played tracks, \(after.musicTracks.count) in Music); tracks still differing from Music: \(after.trackDifferences.count) (\(after.trackDifferences.filter(\.ownDate).count) with a date of your own)")
                }
                for decision in try context.fetch(FetchDescriptor<ReleaseYearDecision>()) { try ReleaseYearAuditActions.undo(decision, context: context) }
                print("ALBUM UNDO: album and every track back exactly as before: \(try albumState() == start)")
            } else { print("ALBUM APPLY: no such album in the comparison") }
        }
        // What "Keep Scroblytics" would offer to write to Music, counted from this library, with a DRY RUN of a sample against the live Music.
        let listedAll = ReleaseYearAudit.listed(report.rows, filter: .all, decisions: [:])
        let offered = listedAll.map { ($0, ReleaseYearAudit.musicUpdates(for: $0, albumYear: nil)) }
        let allUpdates = offered.flatMap(\.1)
        print("MUSIC UPDATE if you kept Scroblytics for all \(listedAll.count) listed: \(allUpdates.count) tracks on \(offered.filter { !$0.1.isEmpty }.count) albums (\(offered.filter { $0.1.isEmpty }.count) albums offer nothing, e.g. compilations whose Music years are left alone); \(allUpdates.filter { $0.from == nil }.count) of the tracks have no year in Music now; \(AppleMusicYearWriter.estimate(tracks: allUpdates.count) ?? "a few seconds")")
        let sampleUpdates = stride(from: 0, to: allUpdates.count, by: max(1, allUpdates.count / 40)).map { allUpdates[$0] }
        let dry = await AppleMusicYearWriter.apply(sampleUpdates, dryRun: true)
        print("MUSIC UPDATE dry run on \(sampleUpdates.count) of them against the live Music (nothing written): \(Dictionary(grouping: dry, by: { "\($0.outcome)" }).mapValues(\.count))")
        if ProcessInfo.processInfo.environment["SCROBLYTICS_RELEASEYEAR_DUMP_APPLY"] != nil {
            try await applyAndUndo(container: container, music: music, report: report)
        }
        HeadlessTask.finish(0)
    }
}
#endif
