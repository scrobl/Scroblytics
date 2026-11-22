import Foundation
import Combine
import SwiftData
import os

extension Notification.Name {
    /// Posted (on the main actor) after a name correction was saved, reset or restored, once `NameCorrections.current` already holds the
    /// new set. Screens that show names reload on it.
    static let nameCorrectionsDidChange = Notification.Name("nameCorrectionsDidChange")
}

enum NameCorrectionKind: String, Codable, Sendable, CaseIterable {
    case artist, album, track
}

/// What the person decided about one name: `corrected` = show this spelling, `looksRight` = reviewed in the finder, leave it as Last.fm has it.
enum NameCorrectionStatus: String, Codable, Sendable {
    case corrected, looksRight
}

/// How the person wants one artist, album or track name SHOWN, locally. Only capitalization and spacing can differ from Last.fm's spelling,
/// so every name key in the app (loved, artwork, edition, artist identity…, all lower-cased) stays valid. The scrobbles themselves, and
/// everything sent to Last.fm and Apple Music, keep Last.fm's spelling. Part of backups.
@Model
final class NameCorrection {
    /// `NameKeys.artist/album/track(...)`: kind, then the folded artist, then (album, track) the folded name.
    @Attribute(.unique) var key: String
    var kind: String
    /// The folded artist the correction belongs to. Empty means any artist (an album shared by several artists).
    var artistKey: String
    /// The folded album or track name; for an artist correction the same as `artistKey`.
    var nameKey: String
    /// Last.fm's artist spelling when the correction was saved, kept so a backup is readable and the collab-credit match has a name to use.
    var artist: String
    /// Last.fm's spelling of the name when the correction was saved (for the sheet's "Reset to…" line and for backups).
    var original: String
    /// The spelling to show. nil for a `looksRight` row.
    var display: String?
    var status: String
    var createdAt: Date
    var updatedAt: Date

    init(key: String, kind: NameCorrectionKind, artistKey: String, nameKey: String, artist: String, original: String, display: String?, status: NameCorrectionStatus, at date: Date = Date()) {
        self.key = key
        self.kind = kind.rawValue
        self.artistKey = artistKey
        self.nameKey = nameKey
        self.artist = artist
        self.original = original
        self.display = display
        self.status = status.rawValue
        self.createdAt = date
        self.updatedAt = date
    }
}

/// A plain copy of one `NameCorrection`, safe to hand across actors.
struct NameCorrectionSnapshot: Sendable, Equatable {
    let key: String
    let kind: NameCorrectionKind
    let artistKey: String
    let nameKey: String
    let artist: String
    let original: String
    let display: String?
    let status: NameCorrectionStatus

    init?(row: NameCorrection) {
        guard let kind = NameCorrectionKind(rawValue: row.kind), let status = NameCorrectionStatus(rawValue: row.status) else { return nil }
        self.key = row.key
        self.kind = kind
        self.artistKey = row.artistKey
        self.nameKey = row.nameKey
        self.artist = row.artist
        self.original = row.original
        self.display = row.display
        self.status = status
    }

    init(key: String, kind: NameCorrectionKind, artistKey: String, nameKey: String, artist: String, original: String, display: String?, status: NameCorrectionStatus) {
        self.key = key; self.kind = kind; self.artistKey = artistKey; self.nameKey = nameKey
        self.artist = artist; self.original = original; self.display = display; self.status = status
    }
}

/// The keys corrections are stored and looked up by. `fold` is the one definition of "the same name apart from capitalization and spacing".
enum NameKeys {
    private static let separator = "\u{241F}" // ␟, as the other keys: printable, SQLite-safe

    /// Trimmed, lower-cased, runs of whitespace collapsed to one space. Diacritics and punctuation are kept.
    static func fold(_ name: String) -> String {
        name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    /// True when two names are the same apart from capitalization and spacing. Used to find a page's plays under every spelling of its name,
    /// because a page that was opened by the spelling the person chose (or by Last.fm's) must still find the plays stored under the other.
    static func same(_ a: String, _ b: String) -> Bool { a == b || fold(a) == fold(b) }

    /// The name with its spacing tidied (trimmed, whitespace runs collapsed to one space) and its capitalization left as typed.
    static func tidy(_ name: String) -> String {
        name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func artist(_ artist: String) -> String { "artist\(separator)\(fold(artist))" }

    /// An album is its exact name (edition words kept, so "Album" and "Album (Deluxe Edition)" stay apart) under one artist.
    static func album(artist: String, album: String) -> String { "album\(separator)\(fold(artist))\(separator)\(fold(album))" }

    static func track(artist: String, title: String) -> String { "track\(separator)\(fold(artist))\(separator)\(fold(title))" }

    static func trackPair(artist: String, title: String) -> String { "\(fold(artist))\(separator)\(fold(title))" }
}

/// What may be typed as a correction.
enum NameCorrectionRules {
    enum Verdict: Equatable {
        /// The spelling to save, with its spacing tidied.
        case ok(String)
        /// Same as Last.fm's spelling (after tidying), so there is nothing to save.
        case unchanged
        case rejected(String)
    }

    /// Only capitalization and spacing may change: the typed name must be the original apart from case and whitespace.
    static func validate(original: String, proposed: String) -> Verdict {
        let tidied = NameKeys.tidy(proposed)
        guard !tidied.isEmpty else { return .rejected("Enter a name.") }
        guard NameKeys.fold(tidied) == NameKeys.fold(original) else {
            return .rejected("Only capitalization and spacing can be changed here. Last.fm’s spelling stays the same underneath.")
        }
        return tidied == NameKeys.tidy(original) ? .unchanged : .ok(tidied)
    }
}

/// Every correction the person has made, as lookups, held in memory. Pure: checks build their own with made-up rows.
struct NameCorrectionBook: Sendable, Equatable {
    struct AlbumRule: Sendable, Equatable {
        let artistKey: String
        /// Last.fm's artist spelling the correction was made under (for the collab-credit match).
        let artist: String
        let display: String
    }

    /// folded artist -> the spelling to show.
    private(set) var artists: [String: String] = [:]
    /// folded album -> the corrections for albums of that name (one per artist).
    private(set) var albums: [String: [AlbumRule]] = [:]
    /// folded artist + folded title -> the spelling to show.
    private(set) var tracks: [String: String] = [:]
    /// The folded titles that have a correction under some artist: a cheap pre-test for large loops.
    private(set) var trackTitles: Set<String> = []
    /// Bumped each time the book is rebuilt, so caches built from it know when to drop.
    var version = 0

    var isEmpty: Bool { artists.isEmpty && albums.isEmpty && tracks.isEmpty }

    init() {}

    init(rows: [NameCorrectionSnapshot], version: Int = 0) {
        self.version = version
        for row in rows where row.status == .corrected {
            guard let display = row.display, !display.isEmpty else { continue }
            switch row.kind {
            case .artist: artists[row.nameKey] = display
            case .album: albums[row.nameKey, default: []].append(AlbumRule(artistKey: row.artistKey, artist: row.artist, display: display))
            case .track:
                tracks["\(row.artistKey)\u{241F}\(row.nameKey)"] = display
                trackTitles.insert(row.nameKey)
            }
        }
        // A stable order, so which rule a collab credit matches never depends on dictionary order.
        for key in albums.keys { albums[key]?.sort { ($0.artistKey, $0.display) < ($1.artistKey, $1.display) } }
    }

    /// The spelling to show for this artist, or nil when it has no correction.
    func artist(_ raw: String) -> String? { artists[NameKeys.fold(raw)] }

    /// The spelling to show for an album, found by its exact name and its raw artist. A play credited to a collaboration that names the
    /// corrected artist ("Artist A feat. Artist B") matches too, and a rule with no artist applies to every artist.
    func album(artist raw: String, album: String) -> String? {
        guard let rules = albums[NameKeys.fold(album)] else { return nil }
        let artistKey = NameKeys.fold(raw)
        if let exact = rules.first(where: { $0.artistKey == artistKey }) { return exact.display }
        if let any = rules.first(where: { $0.artistKey.isEmpty }) { return any.display }
        return rules.first { TextNormalization.trackMatchesArtistContext(trackArtist: raw, context: $0.artist) }?.display
    }

    func track(artist raw: String, title: String) -> String? { tracks[NameKeys.trackPair(artist: raw, title: title)] }

    /// True when `album` (a raw album name) has at least one correction, whatever the artist. Cheap pre-test for large loops.
    func mayCorrectAlbum(_ album: String) -> Bool { !albums.isEmpty && albums[NameKeys.fold(album)] != nil }

    /// True when `title` (a raw track title) has a correction under some artist.
    func mayCorrectTrack(_ title: String) -> Bool { !trackTitles.isEmpty && trackTitles.contains(NameKeys.fold(title)) }
}

/// Applies a book to many plays cheaply: whether a distinct album or track string could have a correction is worked out once per string
/// (not once per play). One instance per bulk run, used from one thread.
final class NameCorrectionApplier {
    private let book: NameCorrectionBook
    private var artistCache: [String: String?] = [:]
    private var albumMay: [String: Bool] = [:]
    private var trackMay: [String: Bool] = [:]

    init(book: NameCorrectionBook = NameCorrections.current) { self.book = book }

    /// True when the book has nothing to apply, so a caller can skip its pass.
    var isIdentity: Bool { book.isEmpty }

    /// The corrected spelling of an artist, or nil.
    func artist(_ raw: String) -> String? {
        if book.artists.isEmpty { return nil }
        if let cached = artistCache[raw] { return cached }
        let found = book.artist(raw)
        artistCache[raw] = .some(found)
        return found
    }

    /// The corrected album and track for a play by the RAW artist `artist` (corrections are found by Last.fm's spelling of the artist).
    func albumAndTrack(artist: String, album: String, track: String) -> (album: String, track: String) {
        var album = album
        var track = track
        if !book.albums.isEmpty, !album.isEmpty {
            let may: Bool
            if let cached = albumMay[album] { may = cached } else { may = book.mayCorrectAlbum(album); albumMay[album] = may }
            if may, let corrected = book.album(artist: artist, album: album) { album = corrected }
        }
        if !book.trackTitles.isEmpty {
            let may: Bool
            if let cached = trackMay[track] { may = cached } else { may = book.mayCorrectTrack(track); trackMay[track] = may }
            if may, let corrected = book.track(artist: artist, title: track) { track = corrected }
        }
        return (album, track)
    }
}

/// The book the whole app reads, loaded at launch and rebuilt after every save, reset or restore.
enum NameCorrections {
    private static let state = OSAllocatedUnfairLock<NameCorrectionBook>(initialState: NameCorrectionBook())

    static var current: NameCorrectionBook { state.withLock { $0 } }

    /// Replaces the book with one made from `rows` (and a new version).
    @discardableResult
    static func install(_ rows: [NameCorrectionSnapshot]) -> NameCorrectionBook {
        state.withLock { book in
            book = NameCorrectionBook(rows: rows, version: book.version + 1)
            return book
        }
    }

    /// Reads every correction from the database (a handful of rows) and installs it. Done synchronously at launch, before any screen
    /// asks for names, so the first thing shown already uses the person's spellings.
    static func load(container: ModelContainer) {
        let rows = (try? ModelContext(container).fetch(FetchDescriptor<NameCorrection>())) ?? []
        install(rows.compactMap(NameCorrectionSnapshot.init(row:)))
    }

    #if DEBUG
    /// Checks only: puts a made-up book in place and returns the old one so it can be put back.
    @discardableResult
    static func useForTesting(_ rows: [NameCorrectionSnapshot]) -> NameCorrectionBook {
        let old = current
        install(rows)
        return old
    }
    #endif
}

enum NameCorrectionError: Error, LocalizedError {
    case rejected(String)

    var errorDescription: String? {
        switch self { case .rejected(let message): return message }
    }
}

/// The SwiftData side of corrections, on its own background context.
@ModelActor
actor NameCorrectionStore {
    func all() throws -> [NameCorrectionSnapshot] {
        try modelContext.fetch(FetchDescriptor<NameCorrection>()).compactMap(NameCorrectionSnapshot.init(row:))
    }

    private static func keys(kind: NameCorrectionKind, artist: String, name: String) -> (key: String, artistKey: String, nameKey: String) {
        switch kind {
        case .artist: return (NameKeys.artist(artist), NameKeys.fold(artist), NameKeys.fold(artist))
        case .album: return (NameKeys.album(artist: artist, album: name), NameKeys.fold(artist), NameKeys.fold(name))
        case .track: return (NameKeys.track(artist: artist, title: name), NameKeys.fold(artist), NameKeys.fold(name))
        }
    }

    private func row(forKey key: String) throws -> NameCorrection? {
        var descriptor = FetchDescriptor<NameCorrection>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// Saves the spelling to show for a name. `artist` is Last.fm's artist spelling (for an album with no single artist pass ""),
    /// `original` Last.fm's spelling of the name. Throws when the text changes more than capitalization and spacing.
    func set(kind: NameCorrectionKind, artist: String, original: String, display proposed: String) throws {
        let verdict = NameCorrectionRules.validate(original: original, proposed: proposed)
        let display: String
        switch verdict {
        case .rejected(let reason): throw NameCorrectionError.rejected(reason)
        case .unchanged: try reset(kind: kind, artist: artist, original: original); return
        case .ok(let tidied): display = tidied
        }
        let k = Self.keys(kind: kind, artist: artist, name: kind == .artist ? artist : original)
        if let existing = try row(forKey: k.key) {
            existing.display = display
            existing.status = NameCorrectionStatus.corrected.rawValue
            existing.artist = artist
            existing.original = original
            existing.updatedAt = Date()
        } else {
            modelContext.insert(NameCorrection(key: k.key, kind: kind, artistKey: k.artistKey, nameKey: k.nameKey, artist: artist, original: original, display: display, status: .corrected))
        }
        try modelContext.save()
    }

    /// Removes the correction (and a "looks right" mark), so the name is shown as Last.fm spells it.
    func reset(kind: NameCorrectionKind, artist: String, original: String) throws {
        let k = Self.keys(kind: kind, artist: artist, name: kind == .artist ? artist : original)
        if let existing = try row(forKey: k.key) {
            modelContext.delete(existing)
            try modelContext.save()
        }
    }
}

extension NameCorrections {
    /// Saves a correction, then rebuilds the book and tells every screen. `onMain` work only: the store runs off the main actor.
    @MainActor
    static func save(container: ModelContainer, kind: NameCorrectionKind, artist: String, original: String, display: String) async throws {
        let store = NameCorrectionStore(modelContainer: container)
        try await store.set(kind: kind, artist: artist, original: original, display: display)
        try await reload(store: store)
    }

    @MainActor
    static func reset(container: ModelContainer, kind: NameCorrectionKind, artist: String, original: String) async throws {
        let store = NameCorrectionStore(modelContainer: container)
        try await store.reset(kind: kind, artist: artist, original: original)
        try await reload(store: store)
    }

    @MainActor
    static func reload(store: NameCorrectionStore) async throws {
        install(try await store.all())
        NotificationCenter.default.post(name: .nameCorrectionsDidChange, object: nil)
    }
}

// MARK: - Identities of the detail pages

extension NameCorrectionBook {
    /// The identity with the person's spellings in it. Corrections are found by capitalization-insensitive keys, so an identity made from
    /// Last.fm's spelling and one made from a corrected name both come out right.
    func corrected(_ identity: ArtistIdentity) -> ArtistIdentity {
        ArtistIdentity(name: artist(identity.name) ?? identity.name, imageURL: identity.imageURL)
    }

    func corrected(_ identity: AlbumIdentity) -> AlbumIdentity {
        AlbumIdentity(artist: artist(identity.artist) ?? identity.artist, name: album(artist: identity.artist, album: identity.name) ?? identity.name, imageURL: identity.imageURL)
    }

    func corrected(_ identity: TrackIdentity) -> TrackIdentity {
        TrackIdentity(
            artist: artist(identity.artist) ?? identity.artist,
            name: track(artist: identity.artist, title: identity.name) ?? identity.name,
            album: identity.album.map { album(artist: identity.artist, album: $0) ?? $0 },
            imageURL: identity.imageURL,
            scopedAlbum: identity.scopedAlbum.map { album(artist: identity.artist, album: $0) ?? $0 }
        )
    }
}

extension NotificationCenter {
    /// Fires when plays were added or the person's name corrections changed: what a screen that shows names reloads on.
    static var historyOrNamesChanged: Publishers.Merge<NotificationCenter.Publisher, NotificationCenter.Publisher> {
        NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete).merge(with: NotificationCenter.default.publisher(for: .nameCorrectionsDidChange))
    }
}
