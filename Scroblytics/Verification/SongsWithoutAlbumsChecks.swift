import Foundation
import SwiftData

#if DEBUG
/// `SCROBLYTICS_SONGSNOALBUM_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): the two groups of Songs Without Albums on
/// made-up scrobbles and a made-up Music library. No Music, no network. Exits 0 on success.
///
/// `SCROBLYTICS_SONGSNOALBUM_DUMP=<file>` runs it on the REAL library (a store copy on `SCROBLYTICS_STORE_PATH`, and a read-only read
/// of the running Music) and writes the counts and every row, so they can be compared with an independent count. Changes nothing.
enum SongsWithoutAlbumsChecks {
    typealias Engine = SongsWithoutAlbumsEngine

    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["SCROBLYTICS_SONGSNOALBUM_DUMP"] {
            HeadlessTask.run("songsnoalbum-dump") {
                let result = try await SongsWithoutAlbumsRunner.run(container: container)
                var out: [String] = []
                out.append("MUSIC_TRACKS \(result.musicTracks ?? -1)")
                out.append("MUSIC_ALBUMS \(result.musicAlbums ?? -1)")
                out.append("NOALBUM \(result.noAlbum.count)")
                out.append("NOALBUM_IN_MUSIC \(result.noAlbum.filter(\.emptyInMusic).count)")
                out.append("NOALBUM_SCROBBLES \(result.noAlbum.reduce(0) { $0 + $1.albumlessPlays })")
                out.append("ALONE \(result.alone.count)")
                out.append("ALONE_NAMED_AFTER_SONG \(result.alone.filter(\.namedAfterSong).count)")
                out.append("ALONE_SINGLES \(result.alone.filter(\.isSingle).count)")
                out.append("ALONE_SINGLES_BY_TRACKLIST \(result.alone.filter { $0.singleBasis == .tracklist }.count)")
                out.append("ALONE_KNOWN_TRACKLIST \(result.alone.filter { $0.knownTrackCount != nil }.count)")
                out.append("ALONE_KNOWN_LONGER \(result.alone.filter { ($0.knownTrackCount ?? 0) > 1 }.count)")
                out.append("ALONE_ON_ANOTHER_ALBUM \(result.alone.filter { !$0.hints.isEmpty }.count)")
                out.append("ALONE_SIBLING \(result.alone.filter { !$0.siblings.isEmpty }.count)")
                for r in result.noAlbum.sorted(by: { $0.id < $1.id }) {
                    out.append("ROW_NOALBUM\t\(r.artist)\t\(r.track)\t\(r.emptyInMusic)\t\(r.albumlessPlays)\t\(r.totalPlays)\t\(r.hints.map(\.album).joined(separator: " | "))")
                }
                for r in result.alone.sorted(by: { $0.id < $1.id }) {
                    out.append("ROW_ALONE\t\(r.artist)\t\(r.album)\t\(r.trackArtist)\t\(r.track)\t\(r.plays)\t\(r.knownTrackCount ?? -1)\t\(r.singleBasis.map { "\($0)" } ?? "-")")
                }
                try out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
                print("wrote \(path)")
                exit(0)
            }
            return
        }
        guard environment["SCROBLYTICS_SONGSNOALBUM_CHECK"] != nil else { return }
        HeadlessTask.run("songsnoalbum-check") {
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            historyChecks(check)
            musicChecks(check)
            aloneChecks(check)
            singleChecks(check)
            crossCheck(check)
            HeadlessTask.finish(failures)
        }
    }

    // MARK: Made-up data

    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private static func play(_ artist: String, _ track: String, _ album: String, _ day: Int = 0) -> ScrobbleSnapshot {
        ScrobbleSnapshot(artistName: artist, albumName: album, trackName: track, imageURL: nil, playedAt: t0.addingTimeInterval(Double(day) * 86_400))
    }

    private static func song(_ artist: String, _ name: String, _ album: String, albumArtist: String = "", cloud: String = "") -> AppleMusicSnapshot.Track {
        AppleMusicSnapshot.Track(name: name, artist: artist, album: album, cloudStatus: cloud, databaseID: nil, albumArtist: albumArtist)
    }

    private static func library(_ tracks: [AppleMusicSnapshot.Track]) -> AppleMusicSnapshot {
        AppleMusicSnapshot(favorites: [], library: tracks, source: .favoritedFlag, readSeconds: 0)
    }

    // MARK: Scrobbles with no album

    private static func historyChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let plays = [
            play("Artist A", "Song One", "", 1), play("Artist A", "Song One", "   ", 2),
            play("Artist A", "Song One", "Real Album", 3), play("Artist A", "Song One", "Real Album", 4), play("Artist A", "Song One", "Real Album", 5),
            play("Artist B", "Song Two", "", 6),
            play("Artist C", "Song Three", "Some Album", 7),
        ]
        let r = Engine.compute(scrobbles: plays, music: nil, now: t0)
        check("only songs with a play lacking an album are listed", Set(r.noAlbum.map(\.track)) == ["Song One", "Song Two"], "\(r.noAlbum.map(\.track))")
        check("Music wasn't read, so there are no one-song albums and no library counts", r.alone.isEmpty && r.musicTracks == nil && r.musicAlbums == nil)
        let one = r.noAlbum.first { $0.track == "Song One" }
        check("a blank or whitespace album counts as none: 2 of 5 plays", one?.albumlessPlays == 2 && one?.totalPlays == 5)
        check("the last album-less play is the latest one", one?.lastPlayed == t0.addingTimeInterval(2 * 86_400))
        check("the album the song is on elsewhere is offered, with its plays", one?.hints == [.init(album: "Real Album", plays: 3, inMusic: false)])
        let two = r.noAlbum.first { $0.track == "Song Two" }
        check("a song that never has an album has no hint", two?.hints.isEmpty == true && two?.totalPlays == 1 && two?.emptyInMusic == false)
    }

    // MARK: Music songs with no album

    private static func musicChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let plays = [play("Artist A", "Song One", "", 1), play("Artist A", "Song One", "Real Album", 2)]
        let music = library([
            song("artist a", "SONG ONE", "", cloud: "uploaded"),
            song("Artist A", "Song One", "Real Album"),
            song("Artist D", "Loose Song", "  "),
            song("Artist E", "Fine Song", "Fine Album"),
        ])
        let r = Engine.compute(scrobbles: plays, music: music, now: t0)
        check("an empty Album in Music is listed, matched to the scrobbled song by its key", Set(r.noAlbum.map(\.track)) == ["Song One", "Loose Song"], "\(r.noAlbum.map(\.track))")
        let one = r.noAlbum.first { $0.track == "Song One" }
        check("a song that is empty in Music and also scrobbled without an album is one row", r.noAlbum.filter { $0.track == "Song One" }.count == 1 && one?.emptyInMusic == true && one?.albumlessPlays == 1 && one?.totalPlays == 2)
        check("the cloud status of the library copy is kept", one?.cloudStatus == "uploaded")
        check("the library's other copy shows as in Music on the hint", one?.hints == [.init(album: "Real Album", plays: 1, inMusic: true)], "\(String(describing: one?.hints))")
        let loose = r.noAlbum.first { $0.track == "Loose Song" }
        check("a song only in Music has no plays", loose?.totalPlays == 0 && loose?.albumlessPlays == 0 && loose?.lastPlayed == nil && loose?.emptyInMusic == true)
        check("the library counts are reported", r.musicTracks == 4 && r.musicAlbums == 2, "\(String(describing: r.musicTracks)) \(String(describing: r.musicAlbums))")
        let none = Engine.compute(scrobbles: [], music: library([song("Artist E", "Fine Song", "Fine Album")]), now: t0)
        check("nothing is listed when every song has an album", none.noAlbum.isEmpty)
    }

    // MARK: Albums holding one song

    private static func aloneChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        // Names
        check("baseName drops - Single, - EP and (EP)", Engine.baseName("Hollows - EP") == Engine.baseName("Hollows") && Engine.baseName("Hollows (EP)") == Engine.baseName("hollows") && Engine.baseName("Song - Single") == "song")
        check("baseName drops an edition suffix too", Engine.baseName("Album (Deluxe Edition)") == "album")
        check("plain collapses case and stray spaces", Engine.plain(" 99.9 F° ") == Engine.plain("99.9 f°") && Engine.plain("A   B") == "a b")

        let music = library([
            // A one-song album.
            song("Artist A", "Lonely", "Lonely Album"),
            // A two-song album, one with a guest credit but the same album artist.
            song("Artist B", "First", "Pair", albumArtist: "Artist B"),
            song("Artist B feat. Guest", "Second", "Pair", albumArtist: "Artist B"),
            // A compilation: three different track artists, one album artist.
            song("Artist C", "C1", "Comp", albumArtist: "Various Artists"),
            song("Artist D", "D1", "Comp", albumArtist: "Various Artists"),
            song("Artist E", "E1", "Comp", albumArtist: "Various Artists"),
            // The same song twice on one album (uploaded and streaming copy) is still one song.
            song("Artist F", "Twice", "Twice Album", cloud: "uploaded"),
            song("Artist F", "Twice", "Twice Album", cloud: "subscription"),
            // A name with a trailing space is the same album as without.
            song("Artist G", "G1", "Spaced "),
            song("Artist G", "G2", "Spaced"),
            // Single-style: album named after the song, with a bigger sibling.
            song("Artist H", "Hollow", "Hollow - Single"),
            song("Artist H", "Other 1", "Hollow"),
            song("Artist H", "Other 2", "Hollow"),
            // A different artist's album with the same name is not a sibling.
            song("Artist I", "Hollow Too", "Hollow - EP"),
            // The same song is also on another album (library and history).
            song("Artist J", "Everywhere", "Everywhere - Single"),
            song("Artist J", "Everywhere", "Greatest"),
            song("Artist J", "Filler", "Greatest"),
            // An edition variant of the same album is not "another album".
            song("Artist K", "Kay", "Kay Album"),
        ])
        let plays = [
            play("Artist A", "Lonely", "Lonely Album", 1), play("Artist A", "Lonely", "Lonely Album", 2), play("Artist A", "Lonely", "Lonely Album (Deluxe Edition)", 3),
            play("Artist J", "Everywhere", "Everywhere - Single", 4), play("Artist J", "Everywhere", "Live Album", 5), play("Artist J", "Everywhere", "Live Album", 6),
            play("Artist K", "Kay", "Kay Album (Deluxe Edition)", 7),
        ]
        let r = Engine.compute(scrobbles: plays, music: music, now: t0)
        let byAlbum = Dictionary(uniqueKeysWithValues: r.alone.map { ($0.album, $0) })
        check("a one-song album is listed", byAlbum["Lonely Album"] != nil)
        check("a two-song album is not (a guest credit on the same album doesn't make a second album)", byAlbum["Pair"] == nil)
        check("the tracks of a compilation are not one-song albums", byAlbum["Comp"] == nil && !r.alone.contains { $0.album == "Comp" })
        check("two copies of one song are still one song", byAlbum["Twice Album"] != nil)
        check("a trailing space doesn't split an album in two", byAlbum["Spaced"] == nil && byAlbum["Spaced "] == nil)
        check("exactly the expected albums are listed", Set(r.alone.map(\.album)) == ["Lonely Album", "Twice Album", "Hollow - Single", "Hollow - EP", "Everywhere - Single", "Kay Album"], "\(r.alone.map(\.album).sorted())")
        check("the album count covers every album group", r.musicAlbums == 11, "\(String(describing: r.musicAlbums))")

        let lonely = byAlbum["Lonely Album"]
        check("plays of the song are counted from the history", lonely?.plays == 3 && lonely?.artist == "Artist A")
        check("an edition of the same album is not offered as another album", lonely?.hints.isEmpty == true, "\(String(describing: lonely?.hints))")
        let kay = byAlbum["Kay Album"]
        check("a deluxe edition in the scrobbles isn't another album", kay?.hints.isEmpty == true)

        let single = byAlbum["Hollow - Single"]
        check("an album named after its song (with - Single) is flagged", single?.namedAfterSong == true && byAlbum["Lonely Album"]?.namedAfterSong == false)
        check("a same-named bigger album by the same artist is a sibling, with its song count", single?.siblings == [.init(album: "Hollow", songs: 2)], "\(String(describing: single?.siblings))")
        check("a different artist's album of that name is not", byAlbum["Hollow - EP"]?.siblings.isEmpty == true)

        let everywhere = byAlbum["Everywhere - Single"]
        check("the other albums the song is on come from history and library, most played first",
              everywhere?.hints == [.init(album: "Live Album", plays: 2, inMusic: false), .init(album: "Greatest", plays: 0, inMusic: true)],
              "\(String(describing: everywhere?.hints))")
        check("an album with no plays has zero plays and no last played", byAlbum["Twice Album"]?.plays == 0 && byAlbum["Twice Album"]?.lastPlayed == nil)
        check("the streaming copy's cloud status is available for the row", byAlbum["Twice Album"]?.cloudStatus == "uploaded" || byAlbum["Twice Album"]?.cloudStatus == "subscription")
        check("an album artist that is empty falls back to the track's artist (so compilation tracks without one are alone)",
              Engine.compute(scrobbles: [], music: library([song("Artist P", "P1", "No Album Artist"), song("Artist Q", "Q1", "No Album Artist")]), now: t0).alone.count == 2)
    }

    // MARK: Singles

    private static func tracklist(_ artist: String, _ album: String, _ tracks: [String]) -> (String, AlbumTracklistResult) {
        (AlbumTurnoverEngine.tracklistCacheKey(artist: artist, album: album), .found(AlbumTracklist(album: album, artist: artist, tracks: tracks)))
    }

    private static func singleChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let music = library([
            song("Artist S", "Radio", "Radio Cut"),                                   // not named after its song; tracklist has 1 track
            song("Artist T", "Hollow", "Hollow"),                                     // named after its song, but the tracklist has 9
            song("Artist U", "Plain", "Plain"),                                       // named after its song, nothing known
            song("Artist V", "Solo", "Odd Album"),                                    // not named after its song, nothing known
            song("Artist W", "Manual Song", "Manual Album"),                          // a saved pasted tracklist of 1
            song("Artist X", "Alias Song", "Alias Album"),                            // a saved match to another Last.fm album
            song("Artist N", "Never Cached Album", "Never Cached Album"),                   // saved match whose tracklist isn't cached
            song("Artist O", "Observed Song", "Observed Album"),                      // "just use what I've played"; a cache exists but is not used
            song("Artist Y", "Why", "Why (Deluxe Edition)"),                          // cached under the plain name
            song("Artist Z", "Zed", "Zed Album", albumArtist: "Artist Z Band"),       // cached under the track's artist
            song("Artist M", "Missing", "Missing Album"),                             // a cached "no match"
            song("Artist L", "Empty", "Empty Album"),                                 // a cached tracklist with no tracks
        ])
        var turnover = AlbumTurnoverEngine.Snapshot()
        for (key, value) in [
            tracklist("Artist S", "Radio Cut", ["Radio"]),
            tracklist("Artist T", "Hollow", (1...9).map { "T\($0)" }),
            tracklist("Artist X", "Alias Album Real", ["Alias Song"]),
            tracklist("Artist O", "Observed Album", (1...12).map { "O\($0)" }),
            tracklist("Artist Y", "Why", ["Why"]),
            tracklist("Artist Z", "Zed Album", ["Zed"]),
            tracklist("Artist L", "Empty Album", []),
        ] { turnover.tracklists[key] = value }
        turnover.tracklists[AlbumTurnoverEngine.tracklistCacheKey(artist: "Artist M", album: "Missing Album")] = .noMatch
        turnover.resolutions[TextNormalization.albumIdentityKey(artist: "Artist W", album: "Manual Album")] = .manual(tracks: ["Manual Song"])
        turnover.resolutions[TextNormalization.albumIdentityKey(artist: "Artist X", album: "Alias Album")] = .canonical(canonicalArtist: "Artist X", canonicalAlbum: "Alias Album Real")
        turnover.resolutions[TextNormalization.albumIdentityKey(artist: "Artist N", album: "Never Cached Album")] = .canonical(canonicalArtist: "Artist N", canonicalAlbum: "Somewhere Else")
        turnover.resolutions[TextNormalization.albumIdentityKey(artist: "Artist O", album: "Observed Album")] = .observed

        let r = Engine.compute(scrobbles: [], music: music, turnover: turnover, now: t0)
        let byAlbum = Dictionary(uniqueKeysWithValues: r.alone.map { ($0.album, $0) })
        check("every one-song album is still listed with a tracklist snapshot", r.alone.count == 12, "\(r.alone.count)")

        check("a cached one-track tracklist makes a single even when the name differs from the song",
              byAlbum["Radio Cut"]?.singleBasis == .tracklist && byAlbum["Radio Cut"]?.knownTrackCount == 1 && byAlbum["Radio Cut"]?.namedAfterSong == false)
        check("an album named after its song is not a single when its tracklist has several tracks",
              byAlbum["Hollow"]?.namedAfterSong == true && byAlbum["Hollow"]?.knownTrackCount == 9 && byAlbum["Hollow"]?.isSingle == false)
        check("with no tracklist known, an album named after its song is a single by its name", byAlbum["Plain"]?.singleBasis == .name && byAlbum["Plain"]?.knownTrackCount == nil)
        check("with no tracklist known and a different name it is not a single", byAlbum["Odd Album"]?.isSingle == false && byAlbum["Odd Album"]?.knownTrackCount == nil)
        check("a saved pasted tracklist counts", byAlbum["Manual Album"]?.knownTrackCount == 1 && byAlbum["Manual Album"]?.singleBasis == .tracklist)
        check("a saved match to a Last.fm album uses that album's cached tracklist", byAlbum["Alias Album"]?.knownTrackCount == 1 && byAlbum["Alias Album"]?.isSingle == true)
        check("a saved match whose tracklist isn't cached knows nothing (and nothing is fetched)", byAlbum["Never Cached Album"]?.knownTrackCount == nil && byAlbum["Never Cached Album"]?.isSingle == true)
        check("\"just use the tracks I've played\" is no statement about the release", byAlbum["Observed Album"]?.knownTrackCount == nil && byAlbum["Observed Album"]?.isSingle == false)
        check("an edition-suffixed album finds the tracklist cached under its plain name", byAlbum["Why (Deluxe Edition)"]?.knownTrackCount == 1)
        check("the track's artist is tried when the album artist found nothing", byAlbum["Zed Album"]?.knownTrackCount == 1)
        check("a cached \"no match\" and an empty tracklist know nothing", byAlbum["Missing Album"]?.knownTrackCount == nil && byAlbum["Empty Album"]?.knownTrackCount == nil)

        // A decision saved on another spelling of the same release (the library says "(2019)", Last.fm "2019 - Single").
        check("same release: punctuation, - Single and - EP differences", Engine.sameRelease("Song R (2019)", "Song R 2019 - Single") && Engine.sameRelease("Song R - EP", "Song R") && Engine.sameRelease("Song R (Deluxe Edition)", "Song R"))
        check("same release: a different title is not", !Engine.sameRelease("Song R", "Song R Live") && !Engine.sameRelease("Greatest Hits", "Song R"))
        var bridged = AlbumTurnoverEngine.Snapshot()
        bridged.resolutions[TextNormalization.albumIdentityKey(artist: "Artist R", album: "Song R 2019 - Single")] = .canonical(canonicalArtist: "Artist R", canonicalAlbum: "Song R 2019 - Single")
        let (key, value) = tracklist("Artist R", "Song R 2019 - Single", ["Song R (2019)"])
        bridged.tracklists[key] = value
        let bridgeMusic = library([song("Artist R", "Song R (2019)", "Song R (2019)"), song("Artist S2", "Other Song", "Other Song")])
        // The song's plays are on a real album; the single's own scrobble has a title that doesn't merge with the song.
        let bridgePlays = [play("Artist R", "Song R", "Greatest Hits", 2), play("Artist R", "Song R 2019", "Song R 2019 - Single", 1)]
        let bridgedResult = Engine.compute(scrobbles: bridgePlays, music: bridgeMusic, turnover: bridged, now: t0)
        let bridgedRow = bridgedResult.alone.first { $0.album == "Song R (2019)" }
        check("a match saved on another spelling of the same release counts for the library's album", bridgedRow?.knownTrackCount == 1 && bridgedRow?.singleBasis == .tracklist, "\(String(describing: bridgedRow?.knownTrackCount))")
        check("that other spelling is not offered as another album, but a different album the song is on still is", bridgedRow?.hints.map(\.album) == ["Greatest Hits"], "\(String(describing: bridgedRow?.hints))")
        let unbridged = Engine.compute(scrobbles: [play("Artist R", "Song R (2019)", "Greatest Hits", 2)], music: bridgeMusic, turnover: bridged, now: t0)
        check("a decision on a different album the song is on does not make this album a single", unbridged.alone.first { $0.album == "Song R (2019)" }?.knownTrackCount == nil)

        // What a view lists
        let rows = r.alone
        let singleCount = rows.filter(\.isSingle).count
        check("All with Hide singles on leaves the singles out", SongsWithoutAlbumsView.listed(rows, filter: .all, hideSingles: true).count == rows.count - singleCount && !SongsWithoutAlbumsView.listed(rows, filter: .all, hideSingles: true).contains { $0.isSingle })
        check("All with Hide singles off lists every album", SongsWithoutAlbumsView.listed(rows, filter: .all, hideSingles: false).count == rows.count)
        check("Likely singles lists exactly the singles whether or not they are hidden", SongsWithoutAlbumsView.listed(rows, filter: .singles, hideSingles: true).count == singleCount && SongsWithoutAlbumsView.listed(rows, filter: .singles, hideSingles: false).count == singleCount)

        // The same library with nothing known behaves as before: singles come from the name alone.
        let plain = Engine.compute(scrobbles: [], music: music, now: t0)
        check("without a snapshot nothing has a known track count", plain.alone.allSatisfy { $0.knownTrackCount == nil })
        check("without a snapshot only albums named after their song are singles", Set(plain.alone.filter(\.isSingle).map(\.album)) == ["Hollow", "Never Cached Album", "Plain", "Why (Deluxe Edition)"], "\(plain.alone.filter(\.isSingle).map(\.album).sorted())")
        check("with a snapshot the singles are exactly those with a one-track tracklist, or named after the song and unknown",
              Set(r.alone.filter(\.isSingle).map(\.album)) == ["Radio Cut", "Plain", "Manual Album", "Alias Album", "Never Cached Album", "Why (Deluxe Edition)", "Zed Album"],
              "\(r.alone.filter(\.isSingle).map(\.album).sorted())")
    }

    // MARK: An independent count on generated data

    private static func crossCheck(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        var seed: UInt64 = 7
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        var tracks: [AppleMusicSnapshot.Track] = []
        for i in 0..<600 {
            let artist = "Artist \(next(40))"
            let album = next(12) == 0 ? "" : "Album \(next(90))"
            let owner = next(5) == 0 ? "Various Artists" : (next(3) == 0 ? "" : artist)
            tracks.append(song(artist, "Track \(i % 350)", album, albumArtist: owner))
        }
        let result = Engine.compute(scrobbles: [], music: library(tracks), now: t0)
        // Plain loops, written differently: album key → distinct songs.
        var songs: [String: Set<String>] = [:]
        var empty = Set<String>()
        for t in tracks {
            let album = t.album.trimmingCharacters(in: .whitespaces).lowercased()
            let songKey = t.artist.lowercased() + "|" + t.name.lowercased()
            if album.isEmpty { empty.insert(songKey); continue }
            let owner = (t.albumArtist.isEmpty ? t.artist : t.albumArtist).lowercased()
            songs[owner + "|" + album, default: []].insert(songKey)
        }
        check("generated library: one-song albums equal an independent count", result.alone.count == songs.values.filter { $0.count == 1 }.count, "\(result.alone.count) vs \(songs.values.filter { $0.count == 1 }.count)")
        check("generated library: album count equals an independent count", result.musicAlbums == songs.count)
        check("generated library: empty-album songs equal an independent count", result.noAlbum.count == empty.count && result.noAlbum.allSatisfy(\.emptyInMusic), "\(result.noAlbum.count) vs \(empty.count)")
    }
}
#endif
