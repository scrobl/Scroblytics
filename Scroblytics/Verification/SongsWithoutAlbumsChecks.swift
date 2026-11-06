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
                out.append("ALONE_ON_ANOTHER_ALBUM \(result.alone.filter { !$0.hints.isEmpty }.count)")
                out.append("ALONE_SIBLING \(result.alone.filter { !$0.siblings.isEmpty }.count)")
                for r in result.noAlbum.sorted(by: { $0.id < $1.id }) {
                    out.append("ROW_NOALBUM\t\(r.artist)\t\(r.track)\t\(r.emptyInMusic)\t\(r.albumlessPlays)\t\(r.totalPlays)\t\(r.hints.map(\.album).joined(separator: " | "))")
                }
                for r in result.alone.sorted(by: { $0.id < $1.id }) {
                    out.append("ROW_ALONE\t\(r.artist)\t\(r.album)\t\(r.trackArtist)\t\(r.track)\t\(r.plays)")
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
