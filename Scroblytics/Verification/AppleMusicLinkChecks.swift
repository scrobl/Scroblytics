import AppKit
import Foundation

#if DEBUG
/// `SCROBLYTICS_MUSICLINK_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): the "View in Apple Music" link is
/// built correctly for each kind and for awkward names, decodes back to exactly the intended search text, and macOS
/// hands it to Music.app. Nothing is opened.
enum AppleMusicLinkChecks {
    static func runHeadlessIfRequested() {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_MUSICLINK_CHECK"] != nil else { return }
        Task {
            await run()
        }
    }

    private static func run() async {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
            if !ok { failures += 1 }
        }
        /// The search term a link carries, read back the way Music would read it.
        func decodedTerm(_ url: URL?) -> String? {
            guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
            return items.count == 1 && items[0].name == "term" ? items[0].value : nil
        }

        // Terms by kind.
        check("artist: just the artist", AppleMusicLinks.searchTerm(kind: .artist, artist: "Artist A", album: "Album X", track: "Song Y") == "Artist A")
        check("album: artist and album", AppleMusicLinks.searchTerm(kind: .album, artist: "Artist A", album: "Album X", track: nil) == "Artist A Album X")
        check("track: artist and track", AppleMusicLinks.searchTerm(kind: .track, artist: "Artist A", album: "Album X", track: "Song Y") == "Artist A Song Y")
        check("a missing album or track leaves just the artist", AppleMusicLinks.searchTerm(kind: .album, artist: "Artist A", album: nil, track: nil) == "Artist A"
              && AppleMusicLinks.searchTerm(kind: .track, artist: "Artist A", album: "X", track: "  ") == "Artist A")
        check("stray spaces are trimmed", AppleMusicLinks.searchTerm(kind: .track, artist: "  Artist A ", album: nil, track: " Song Y  ") == "Artist A Song Y")
        check("nothing to search for gives no link", AppleMusicLinks.searchURL(term: "") == nil)

        // The link itself, for names that could break a URL.
        let awkward = [
            "Artist A & Artist B Song", "AC/DC Back In Black", "Artist #1 Track?", "Plus+Minus Track", "Say \"Hello\" Now",
            "Beyoncé Déjà Vu", "Artist 🎵 Song", "100% Real", "A=B&C=D", "Semi;colon", "Tab\there",
        ]
        for term in awkward {
            let url = AppleMusicLinks.searchURL(term: term)
            let ok = url?.scheme == "music" && url?.host == "music.apple.com" && url?.path == "/search" && decodedTerm(url) == term
            check("round-trips: \(term)", ok, url?.absoluteString ?? "no url")
        }
        check("the whole term is one query value", (AppleMusicLinks.searchURL(term: "A & B")?.absoluteString ?? "").hasSuffix("?term=A%20%26%20B"),
              AppleMusicLinks.searchURL(term: "A & B")?.absoluteString ?? "")

        // macOS gives the link to Music.app.
        if let url = AppleMusicLinks.searchURL(term: "Artist A") {
            let handler = NSWorkspace.shared.urlForApplication(toOpen: url)
            check("macOS hands the link to Music.app", handler.flatMap { Bundle(url: $0)?.bundleIdentifier } == "com.apple.Music", handler?.path ?? "no handler")
        }

        // Choosing the page from catalogue results (shapes as Apple returns them; made-up names).
        func page(_ id: Int, _ query: String = "") -> String { "https://music.apple.com/us/album/x/\(id)\(query)" }
        let albums = [
            AppleMusicCatalog.Hit(artistName: "Artist A", collectionName: "Album X (Deluxe Edition)", collectionViewUrl: page(111, "?uo=4")),
            AppleMusicCatalog.Hit(artistName: "Artist A", collectionName: "Album X", collectionViewUrl: page(222, "?uo=4")),
            AppleMusicCatalog.Hit(artistName: "Artist B", collectionName: "Album X", collectionViewUrl: page(333, "?uo=4")),
        ]
        check("album: the exact title and artist wins over an edition and over another artist",
              AppleMusicCatalog.choose(kind: .album, artist: "artist a", album: "Album X", track: nil, from: albums)?.absoluteString == page(222, "?uo=4"))
        check("album: an edition tag in the request still finds the album",
              AppleMusicCatalog.choose(kind: .album, artist: "Artist A", album: "Album X (Remastered)", track: nil, from: albums) != nil)
        check("album: a different artist's album is never chosen",
              AppleMusicCatalog.choose(kind: .album, artist: "Artist C", album: "Album X", track: nil, from: albums) == nil)
        check("album: no album name, no page", AppleMusicCatalog.choose(kind: .album, artist: "Artist A", album: nil, track: nil, from: albums) == nil)
        let artists = [
            AppleMusicCatalog.Hit(artistName: "Artist AB", artistLinkUrl: "https://music.apple.com/us/artist/artist-ab/1?uo=4"),
            AppleMusicCatalog.Hit(artistName: "Artist A", artistLinkUrl: "https://music.apple.com/us/artist/artist-a/2?uo=4"),
        ]
        check("artist: the exact name, not a look-alike",
              AppleMusicCatalog.choose(kind: .artist, artist: "ARTIST A", album: nil, track: nil, from: artists)?.absoluteString.contains("/artist-a/2") == true)
        check("artist: no match gives no page", AppleMusicCatalog.choose(kind: .artist, artist: "Nobody", album: nil, track: nil, from: artists) == nil)
        let songs = [
            AppleMusicCatalog.Hit(artistName: "Artist A", collectionName: "Album X", trackName: "Song Y - Remastered 2011", trackViewUrl: page(222, "?i=9&uo=4")),
            AppleMusicCatalog.Hit(artistName: "Artist A", collectionName: "Greatest Hits", trackName: "Song Y", trackViewUrl: page(444, "?i=8&uo=4")),
            AppleMusicCatalog.Hit(artistName: "Artist B", collectionName: "Album X", trackName: "Song Y", trackViewUrl: page(555, "?i=7&uo=4")),
        ]
        check("track: with its album, the song on that album",
              AppleMusicCatalog.choose(kind: .track, artist: "Artist A", album: "Album X", track: "Song Y", from: songs)?.absoluteString.contains("i=9") == true)
        check("track: without an album, the exact title beats an edition",
              AppleMusicCatalog.choose(kind: .track, artist: "Artist A", album: nil, track: "Song Y", from: songs)?.absoluteString.contains("i=8") == true)
        check("track: another artist's song is never chosen", AppleMusicCatalog.choose(kind: .track, artist: "Artist C", album: nil, track: "Song Y", from: songs) == nil)
        // Editions: a request for the deluxe edition lands on it, a plain request on the plain one, for albums and songs.
        func edition(_ id: Int, _ name: String) -> (album: AppleMusicCatalog.Hit, song: AppleMusicCatalog.Hit) {
            (AppleMusicCatalog.Hit(artistName: "Artist A", collectionName: name, collectionViewUrl: page(id, "?uo=4")),
             AppleMusicCatalog.Hit(artistName: "Artist A", collectionName: name, trackName: "Song Y", trackViewUrl: page(id, "?i=\(id)1&uo=4")))
        }
        let plain = edition(100, "Album X"), deluxe = edition(200, "Album X (Deluxe Version)"), expanded = edition(300, "Album X (Expanded Edition)")
        // Apple lists the plain edition first.
        let ordered = [plain, deluxe, expanded]
        let editionAlbums = ordered.map(\.album), editionSongs = ordered.map(\.song)
        check("album: “(Deluxe Version)” lands on the deluxe edition, not the plain one listed first",
              AppleMusicCatalog.choose(kind: .album, artist: "Artist A", album: "Album X (Deluxe Version)", track: nil, from: editionAlbums)?.absoluteString.contains("/200") == true)
        check("album: “(Deluxe Edition)” still finds the deluxe edition (Version and Edition are the same word)",
              AppleMusicCatalog.choose(kind: .album, artist: "Artist A", album: "Album X (Deluxe Edition)", track: nil, from: editionAlbums)?.absoluteString.contains("/200") == true)
        check("album: the plain title lands on the plain edition",
              AppleMusicCatalog.choose(kind: .album, artist: "Artist A", album: "Album X", track: nil, from: editionAlbums)?.absoluteString.contains("/100") == true)
        check("album: an expanded edition lands on the expanded one",
              AppleMusicCatalog.choose(kind: .album, artist: "Artist A", album: "Album X (Expanded Edition)", track: nil, from: editionAlbums)?.absoluteString.contains("/300") == true)
        check("song: scrobbled on the deluxe album, opens the deluxe album",
              AppleMusicCatalog.choose(kind: .track, artist: "Artist A", album: "Album X (Deluxe Version)", track: "Song Y", from: editionSongs)?.absoluteString.contains("/200") == true)
        check("song: scrobbled on the plain album, opens the plain album",
              AppleMusicCatalog.choose(kind: .track, artist: "Artist A", album: "Album X", track: "Song Y", from: editionSongs)?.absoluteString.contains("/100") == true)
        check("song: with no album it still opens one of the song's albums",
              AppleMusicCatalog.choose(kind: .track, artist: "Artist A", album: nil, track: "Song Y", from: editionSongs) != nil)
        let decoded = try? AppleMusicCatalog.decode(Data("""
            {"resultCount":1,"results":[{"wrapperType":"collection","artistName":"Artist A","collectionName":"Album X","collectionViewUrl":"https://music.apple.com/us/album/x/1?uo=4","extra":1}]}
            """.utf8))
        check("a catalogue answer decodes (extra fields ignored)", decoded?.first?.collectionName == "Album X")
        check("the page opens in the Music app, without the tracking parameter",
              AppleMusicCatalog.musicURL(from: URL(string: "https://music.apple.com/us/album/a/1?i=2&uo=4")!)?.absoluteString == "music://music.apple.com/us/album/a/1?i=2")
        check("…and no empty query is left behind",
              AppleMusicCatalog.musicURL(from: URL(string: "https://music.apple.com/us/artist/a/1?uo=4")!)?.absoluteString == "music://music.apple.com/us/artist/a/1")
        check("a link that isn't an Apple Music page is refused", AppleMusicCatalog.musicURL(from: URL(string: "https://example.com/x")!) == nil)
        if let url = AppleMusicCatalog.musicURL(from: URL(string: "https://music.apple.com/us/album/a/1")!) {
            let handler = NSWorkspace.shared.urlForApplication(toOpen: url)
            check("macOS hands an album page to Music.app", handler.flatMap { Bundle(url: $0)?.bundleIdentifier } == "com.apple.Music")
        }

        // Against Apple's real catalogue, with well-known public examples (skipped when it can't be reached).
        do {
            let artist = try await AppleMusicCatalog.lookup(kind: .artist, artist: "The Beatles", album: nil, track: nil)
            let album = try await AppleMusicCatalog.lookup(kind: .album, artist: "The Beatles", album: "Abbey Road", track: nil)
            let song = try await AppleMusicCatalog.lookup(kind: .track, artist: "The Beatles", album: "Abbey Road", track: "Come Together")
            let remastered = try await AppleMusicCatalog.lookup(kind: .track, artist: "The Beatles", album: "Abbey Road (Remastered)", track: "Come Together")
            check("live: a song on the “(Remastered)” edition opens that edition, not the first one Apple lists",
                  remastered?.path.hasSuffix("/1441164426") == true, remastered?.absoluteString ?? "nil")
            if let probe = ProcessInfo.processInfo.environment["SCROBLYTICS_MUSICLINK_PROBE"] {
                // "kind|artist|album|track": prints the page that would be opened (for trying a case by hand).
                let parts = probe.components(separatedBy: "|") + ["", "", "", ""]
                let kind = ImageTargetKind(rawValue: parts[0]) ?? .track
                let answer = try await AppleMusicCatalog.lookup(kind: kind, artist: parts[1], album: parts[2].isEmpty ? nil : parts[2], track: parts[3].isEmpty ? nil : parts[3])
                print("PROBE \(probe) -> \(answer?.absoluteString ?? "no page (search fallback)")")
            }
            let nothing = try await AppleMusicCatalog.lookup(kind: .album, artist: "Zzzz Not An Artist", album: "Nothing Here", track: nil)
            check("live: an artist page", artist?.host == "music.apple.com" && artist?.path.contains("/artist/") == true, artist?.absoluteString ?? "nil")
            check("live: an album page", album?.host == "music.apple.com" && album?.path.contains("/album/") == true, album?.absoluteString ?? "nil")
            check("live: a song opens its album with the song selected", song?.query?.contains("i=") == true, song?.absoluteString ?? "nil")
            check("live: something that doesn't exist gives no page (so the search fallback is used)", nothing == nil, nothing?.absoluteString ?? "")
        } catch {
            print("SKIP  live lookup (\(error.localizedDescription))")
        }

        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
