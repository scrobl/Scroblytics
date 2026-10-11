import AppKit
import Foundation

/// Opens the Music app on a search for an artist, album or track. `music://` is registered to Music.app, so this goes
/// straight to Music rather than a browser, and Scroblytics sends nothing itself: the search is Music's own.
enum AppleMusicLinks {
    /// What to search for: the artist alone, or the artist followed by the album or track name.
    nonisolated static func searchTerm(kind: ImageTargetKind, artist: String, album: String?, track: String?) -> String {
        func clean(_ text: String?) -> String? {
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
        let name = clean(artist) ?? ""
        let extra: String?
        switch kind {
        case .artist: extra = nil
        case .album: extra = clean(album)
        case .track: extra = clean(track)
        }
        return [name, extra].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// `music://music.apple.com/search?term=…`. Every character except letters, digits and `-._~` is percent-encoded, so
    /// `&`, `+`, `#`, `?`, `/` and quotes can't change what is searched for.
    nonisolated static func searchURL(term: String) -> URL? {
        guard !term.isEmpty else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "music://music.apple.com/search?term=\(encoded)")
    }

    /// Opens the item's own page in the Music app, found through Apple's catalogue; when it can't be found (no
    /// confident match, Offline mode, no connection) Music is opened on a search for it instead.
    @MainActor
    static func open(kind: ImageTargetKind, artist: String, album: String?, track: String?) async {
        if let page = try? await AppleMusicCatalog.lookup(kind: kind, artist: artist, album: album, track: track),
           let url = AppleMusicCatalog.musicURL(from: page) {
            NSWorkspace.shared.open(url)
            return
        }
        openSearch(kind: kind, artist: artist, album: album, track: track)
    }

    @MainActor
    static func openSearch(kind: ImageTargetKind, artist: String, album: String?, track: String?) {
        guard let url = searchURL(term: searchTerm(kind: kind, artist: artist, album: album, track: track)) else { return }
        NSWorkspace.shared.open(url)
    }
}
