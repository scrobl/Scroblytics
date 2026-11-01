import Foundation
import SwiftData

#if DEBUG
/// `SCROBLYTICS_RELEASEYEAR_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): the comparison of Scroblytics' release years
/// with Apple Music's, on made-up data, the recording of which service gave a date, and the reading of Music's answer. No Music, no
/// network. Exits 0 on success.
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
            + ["Artist A", "", "Various Artists"].joined(separator: rs) + gs + ["Album One", "Album One", "Mix"].joined(separator: rs) + gs + ["1998", "0", "2005"].joined(separator: rs) + "\n"
        let tracks = AppleMusicYearReader.parse(reply)
        check("Music's columns are read into tracks", tracks?.count == 3 && tracks?[0] == AppleMusicTrackYear(name: "Song A", artist: "Artist A", albumArtist: "Artist A", album: "Album One", year: 1998), "\(String(describing: tracks))")
        check("a year of 0 is no year, an empty album artist stays empty, and other scripts survive", tracks?[1].year == nil && tracks?[1].albumArtist == "" && tracks?[2].name == "Naïve 日本" && tracks?[2].year == 2005)
        check("a reply with the wrong number of columns or rows is refused, not guessed", AppleMusicYearReader.parse("a" + gs + "b") == nil && AppleMusicYearReader.parse("a" + rs + "b" + gs + "x" + gs + "y" + gs + "z" + gs + "1998") == nil)
        check("an empty library reads as no tracks", AppleMusicYearReader.parse(gs + gs + gs + gs)?.isEmpty == true)
    }

    // MARK: - The comparison

    private static func album(_ artist: String, _ title: String, _ date: String?, _ origin: AlbumDateOrigin = .musicBrainz) -> AuditAlbum {
        AuditAlbum(title: title, artist: artist, artistKey: TextNormalization.artistIdentityKey(artist), normalizedTitle: TextNormalization.normalizeAlbumName(title), date: date, origin: date == nil ? .none : origin)
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
        music += [track("old", "Artist A", "Compilation", 1953), track("older", "Artist A", "Compilation", 1953), track("new", "Artist A", "Compilation", 2004), track("same", "Artist A", "Compilation", 2004), track("none", "Artist A", "Compilation", nil)]
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
        check("…and the album year here (2004) disagrees with its most common track year (1953), but only the 2 older tracks differ", compilation?.category == .differs && compilation?.trackDifferences.map(\.name).sorted() == ["old", "older"] && compilation?.trackDifferences.allSatisfy { !$0.ownDate } == true)
        check("tracks with no year in Music are never differences", compilation?.trackDifferences.contains { $0.name == "none" } == false && report.musicTracksWithoutYear == 1)
        check("the totals add up", report.count(.same) + report.count(.offByOne) + report.count(.differs) + report.count(.scroblyticsUndated) + report.count(.musicUndated) == report.matched && report.disagreements == 3)

        // A date set on a track is what Scroblytics shows for it.
        let overrides = [TextNormalization.lovedKey(artist: "Artist A", track: "old"): "1953-01-12", TextNormalization.lovedKey(artist: "Artist A", track: "same"): "1999"]
        let withOwn = ReleaseYearAudit.compare(music: music, albums: albums, trackOverrides: overrides)
        let own = withOwn.rows.first { $0.scroblytics.title == "Compilation" }
        check("a track with its own date that matches Music is no longer a difference; one that doesn't is, marked as its own", own?.trackDifferences.map(\.name).sorted() == ["older", "same"] && own?.trackDifferences.first { $0.name == "same" }?.ownDate == true && own?.trackDifferences.first { $0.name == "same" }?.scroblyticsYear == 1999)
        check("an album date doesn't change with a track date: the album-level category stays", own?.category == compilation?.category)
        check("with nothing in Music, nothing is compared", ReleaseYearAudit.compare(music: [], albums: albums).rows.isEmpty)

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
        check("a year apart and 2+ years are told apart", titles(.offByOne) == ["One Off", "Late"] && titles(.differs) == ["Far Off", "Mine", "Compilation"])
        check("your own dates are listed on their own, and so are the compilations", titles(.yourDates) == ["Mine"] && titles(.musicVaries) == ["Compilation"])
        let key = { (title: String) in sample.rows.first { $0.scroblytics.title == title }!.albumKey }
        let row = sample.rows.first { $0.scroblytics.title == "One Off" }!
        let keep = ReleaseYearAudit.Decision(albumKey: key("One Off"), verdict: .keepMine, scroblyticsYear: 2003, musicYear: 2002)
        check("an album you kept leaves every list", ReleaseYearAudit.isDecided(row, decisions: [keep.albumKey: keep]) && !titles(.all, [keep.albumKey: keep]).contains("One Off") && !titles(.offByOne, [keep.albumKey: keep]).contains("One Off"))
        let staleSelf = ReleaseYearAudit.Decision(albumKey: key("One Off"), verdict: .keepMine, scroblyticsYear: 2004, musicYear: 2002)
        let staleMusic = ReleaseYearAudit.Decision(albumKey: key("One Off"), verdict: .keepMine, scroblyticsYear: 2003, musicYear: 2001)
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
    }

    @MainActor
    private static func dump(container: ModelContainer) async throws {
        let music = try await AppleMusicYearReader.read()
        let loaded = await ReleaseYearAuditStoreReader(modelContainer: container).load()
        let report = ReleaseYearAudit.compare(music: music, albums: loaded.albums, trackOverrides: loaded.trackOverrides)
        print("Music: \(report.musicTracks) tracks in \(report.musicAlbums) albums (\(report.musicTracksWithoutYear) tracks with no year); Scroblytics: \(loaded.albums.count) albums, \(loaded.trackOverrides.count) track dates")
        print("matched albums: \(report.matched); not matched: \(report.unmatchedMusicAlbums)")
        for category in ReleaseYearAudit.Category.allCases { print("  \(category.rawValue): \(report.count(category))") }
        let dupes = Dictionary(grouping: report.rows, by: \.albumKey).filter { $0.value.count > 1 }
        print("Scroblytics albums matched by more than one Music album: \(dupes.count)")
        for (_, group) in dupes.sorted(by: { $0.key < $1.key }).prefix(8) {
            print("   \(group[0].scroblytics.artist) — \(group[0].scroblytics.title): " + group.map { "[Music: \($0.musicArtist) — \($0.musicAlbum), \($0.trackCount) tracks, \($0.musicYear.map(String.init) ?? "-"), by \($0.matchedBy.rawValue)]" }.joined(separator: " "))
        }
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
        if ProcessInfo.processInfo.environment["SCROBLYTICS_RELEASEYEAR_DUMP_APPLY"] != nil {
            try await applyAndUndo(container: container, music: music, report: report)
        }
        HeadlessTask.finish(0)
    }
}
#endif
