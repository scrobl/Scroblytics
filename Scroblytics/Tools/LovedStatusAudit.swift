import Foundation
import SwiftData

/// One side's view of a track. "Not present" is deliberately not "not loved": the track simply isn't in that
/// service's library/history at all.
enum LovedAuditState: Sendable, Equatable {
    case loved, notLoved, notPresent
}

/// A match the audit isn't sure about — shown with an amber badge, never as a confirmed discrepancy.
struct LovedAuditUncertainty: Sendable {
    enum Side: Sendable { case appleMusic, lastfm }
    /// The side the near-match was found on.
    let side: Side
    let artist: String
    let track: String

    var detail: String {
        "Possibly the same as “\(track)” by \(artist) on \(side == .appleMusic ? "Apple Music" : "Last.fm")"
    }
}

/// A favorite in Music's Favorite Songs playlist that is not a track in the library: either an Apple Music catalogue song
/// that was favorited but never added (cloud status `subscription`), or a leftover entry for a library track that was since
/// renamed or replaced. Music itself often doesn't show these, so they can't be undone there.
struct AppleFavoriteNotInLibrary: Sendable, Equatable {
    enum Origin: Sendable, Equatable { case catalogue, leftover }
    let origin: Origin
    let databaseID: Int
    /// The name and artist as the Favorite Songs playlist has them (what a removal must still find).
    let name: String
    let artist: String
}

struct LovedAuditRow: Identifiable, Sendable {
    let id: String
    let artist: String
    let track: String
    let album: String?
    let lastfm: LovedAuditState
    let appleMusic: LovedAuditState
    let uncertainty: LovedAuditUncertainty?
    /// Whether a scrobble exists under this exact (artist, title). Meaningful for rows loved on Last.fm: a love whose
    /// name no scrobble uses is a "loved, no scrobbles" row (the track was edited or its plays deleted after loving it).
    var lastfmHasScrobbles = true
    /// Set when this row's Apple Music favorite is not a library track (see `AppleFavoriteNotInLibrary`).
    var appleNotInLibrary: AppleFavoriteNotInLibrary? = nil

    /// The two spellings an Uncertain row is about, with the Last.fm one and the Apple Music one named, for a decision.
    var decisionPair: (lastfm: LovedStatusAuditEngine.Entry, apple: LovedStatusAuditEngine.Entry)? {
        guard let uncertainty else { return nil }
        let own = LovedStatusAuditEngine.Entry(artist: artist, track: track)
        let other = LovedStatusAuditEngine.Entry(artist: uncertainty.artist, track: uncertainty.track)
        return uncertainty.side == .appleMusic ? (lastfm: own, apple: other) : (lastfm: other, apple: own)
    }

    /// Loved on Last.fm under a name that no scrobble uses.
    var isLovedWithoutScrobbles: Bool { lastfm == .loved && !lastfmHasScrobbles }

    /// Loved on both, and sure of it.
    var agrees: Bool { lastfm == .loved && appleMusic == .loved && uncertainty == nil }
}

struct LovedAudit: Sendable {
    let rows: [LovedAuditRow]
    let lastfmLovedCount: Int
    let appleFavoritesCount: Int

    var agreeCount: Int { rows.filter(\.agrees).count }
    var uncertainCount: Int { rows.filter { $0.uncertainty != nil }.count }
    /// Loved on Last.fm under a name no scrobble uses.
    var lovedWithoutScrobblesCount: Int { rows.filter(\.isLovedWithoutScrobbles).count }
    /// Rows whose Apple Music favorite is not in the library.
    var notInLibraryCount: Int { rows.filter { $0.appleNotInLibrary != nil }.count }
    /// Confirmed: loved on Last.fm, and Apple Music has it either not loved or not at all.
    var lastfmOnlyCount: Int { rows.filter { $0.uncertainty == nil && $0.lastfm == .loved && $0.appleMusic != .loved }.count }
    var appleOnlyCount: Int { rows.filter { $0.uncertainty == nil && $0.appleMusic == .loved && $0.lastfm != .loved }.count }
    var discrepancies: [LovedAuditRow] { rows.filter { !$0.agrees } }
}

/// Joins the Last.fm loved set (already synced locally) with Music.app's favorites and library, entirely in
/// memory. Matching uses the key the rest of the app already matches Apple Music tracks by
/// (`AppleMusicMatcher.durationMatchKey`: artist identity + normalized title); a near-match on the OTHER side that
/// the key can't confirm — different spelling or credit — is "uncertain", not a discrepancy.
enum LovedStatusAuditEngine {
    struct Entry: Sendable, Equatable, Hashable {
        let artist: String
        let track: String
    }

    /// Candidate lookup for near-matches. Indexed by title word AND by artist word, so a different spelling of the
    /// title ("Limehouse" / "Lime House") is still found through the artist, and a different credit
    /// ("Smith" / "Smith & Jones") through the title — a search touches a handful of entries, not the library.
    struct NearIndex {
        let entries: [Entry]
        /// `normalizeTrackTitle` is regex-heavy; each entry's is computed once here, not per lookup.
        private let normalizedTitles: [String]
        private let artistKeys: [String]
        private let titleTokens: [Set<String>]
        private var byTitleToken: [String: [Int]] = [:]
        private var byArtistToken: [String: [Int]] = [:]

        private static let stopWords: Set<String> = ["the", "and", "of", "a", "an", "feat", "featuring", "with", "&"]
        private static let maxPosting = 800

        private static func words(_ s: String) -> [String] {
            s.lowercased().folding(options: .diacriticInsensitive, locale: nil).split { !$0.isLetter && !$0.isNumber }.map(String.init)
        }

        /// Letters and digits only, accents folded: "I'm Lonely (But I Ain't…)" and "I'm Lonely (But I aint…)" agree.
        static func squash(_ s: String) -> String { words(s).joined() }

        /// Equal once punctuation/spacing/accents are ignored, or at most one edit in ten characters apart. Stricter
        /// than `albumNamesSimilar` (0.72), which is fine for grouping editions but too loose to call two song titles
        /// the same track.
        static func closeSpelling(_ a: String, _ b: String) -> Bool {
            let sa = Array(squash(a)), sb = Array(squash(b))
            guard !sa.isEmpty, !sb.isEmpty else { return false }
            if sa == sb { return true }
            let longest = max(sa.count, sb.count)
            guard longest >= 6, abs(sa.count - sb.count) <= longest / 10 else { return false }
            var previous = Array(0...sb.count)
            for i in 1...sa.count {
                var current = [i] + Array(repeating: 0, count: sb.count)
                for j in 1...sb.count {
                    current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (sa[i - 1] == sb[j - 1] ? 0 : 1))
                }
                previous = current
            }
            return previous[sb.count] <= longest / 10
        }

        init(_ entries: [Entry]) {
            self.entries = entries
            let normalized = entries.map { TextNormalization.normalizeTrackTitle($0.track) }
            normalizedTitles = normalized
            artistKeys = entries.map { TextNormalization.artistIdentityKey($0.artist) }
            var tokenSets: [Set<String>] = []
            tokenSets.reserveCapacity(entries.count)
            for (index, entry) in entries.enumerated() {
                let tokens = Set(Self.words(normalized[index]))
                tokenSets.append(tokens)
                for token in tokens { byTitleToken[token, default: []].append(index) }
                for token in Set(Self.words(entry.artist)).subtracting(Self.stopWords) { byArtistToken[token, default: []].append(index) }
            }
            titleTokens = tokenSets
        }

        /// The best artist-compatible, similarly-titled entry, if any. `isExcluded` lets a caller rule candidates out (a
        /// pairing the user has said is two different songs).
        func nearest(artist: String, track: String, isExcluded: ((Entry) -> Bool)? = nil) -> Entry? {
            let target = TextNormalization.normalizeTrackTitle(track)
            var candidates = Set<Int>()
            // The rarest title word, plus every (not over-common) artist word.
            if let rarest = Self.words(target).min(by: { (byTitleToken[$0]?.count ?? 0) < (byTitleToken[$1]?.count ?? 0) }),
               let list = byTitleToken[rarest] { candidates.formUnion(list) }
            for token in Set(Self.words(artist)).subtracting(Self.stopWords) {
                if let list = byArtistToken[token], list.count <= Self.maxPosting { candidates.formUnion(list) }
            }
            let artistKey = TextNormalization.artistIdentityKey(artist)
            let targetWords = Set(Self.words(target))
            var best: (entry: Entry, score: Int)?
            // Sorted so a tie between equally good candidates always resolves the same way (Set order is
            // randomized per instance, which made repeated runs disagree on which near match to name).
            for index in candidates.sorted() {
                let entry = entries[index]
                if let isExcluded, isExcluded(entry) { continue }
                guard StaleRecordReconciler.artistKeysCompatible(artistKey, artistKeys[index]) else { continue }
                let other = normalizedTitles[index]
                // Cheap gate before the expensive comparisons: every way two titles can count as the same needs
                // either a shared word (one contains the other) or similar length (edit-distance similarity, a
                // close spelling) — an artist's hundreds of unrelated titles are skipped here.
                let longest = max(target.count, other.count)
                guard !targetWords.isDisjoint(with: titleTokens[index]) || Double(abs(target.count - other.count)) <= 0.3 * Double(longest) else { continue }
                var score = StaleRecordReconciler.titleScore(target, other)
                if score == 0, Self.closeSpelling(target, other) { score = 2 }
                if score > 0, score > (best?.score ?? 0) { best = (entry, score) }
            }
            return best?.entry
        }
    }

    /// A verdict the user gave on one pairing: the Last.fm spelling and the Apple Music spelling are the same song, or two
    /// different songs.
    struct Decision: Sendable, Equatable {
        let lastfm: Entry
        let apple: Entry
        let sameTrack: Bool
    }

    /// The identity of a pairing, safe to store (the match key joins its parts with a NUL, which SQLite truncates).
    nonisolated static func pairKey(lastfm: Entry, apple: Entry) -> String {
        func safe(_ e: Entry) -> String { AppleMusicMatcher.durationMatchKey(artist: e.artist, track: e.track).replacingOccurrences(of: "\u{0}", with: "\u{241F}") }
        return safe(lastfm) + "\u{241E}" + safe(apple)
    }

    /// Decisions that no longer apply: the Last.fm spelling is gone from your loves and your scrobbles, or the Apple Music
    /// spelling is gone from your Favorites and your library (you fixed it on one side). Such a pair can never be suggested
    /// again, so the decision does nothing and can be dropped. Nothing is reported when the data looks incomplete (no
    /// library read, or no loves and no scrobbles at all), so a partial read can never wipe decisions.
    nonisolated static func obsoleteDecisions(_ decisions: [Decision], lovedOnLastfm: [Entry], history: [Entry], apple: AppleMusicSnapshot) -> [Decision] {
        guard !apple.library.isEmpty, !(lovedOnLastfm.isEmpty && history.isEmpty) else { return [] }
        func key(_ e: Entry) -> String { AppleMusicMatcher.durationMatchKey(artist: e.artist, track: e.track) }
        var lastfmKeys = Set(lovedOnLastfm.map(key))
        lastfmKeys.formUnion(history.map(key))
        var appleKeys = Set<String>()
        for t in apple.library { appleKeys.insert(key(Entry(artist: t.artist, track: t.name))) }
        for t in apple.favorites { appleKeys.insert(key(Entry(artist: t.artist, track: t.name))) }
        return decisions.filter { !lastfmKeys.contains(key($0.lastfm)) || !appleKeys.contains(key($0.apple)) }
    }

    /// `decisions` change what is matched, never what is stored: a **same track** verdict makes the Apple Music spelling
    /// count as the Last.fm one, so ordinary exact matching then pairs them (loved on both agrees; loved on one side only
    /// is a confirmed discrepancy); a **different tracks** verdict stops that pairing being suggested.
    nonisolated static func audit(lovedOnLastfm: [Entry], history: [Entry], apple: AppleMusicSnapshot, decisions: [Decision] = []) -> LovedAudit {
        func key(_ e: Entry) -> String { AppleMusicMatcher.durationMatchKey(artist: e.artist, track: e.track) }
        func appleEntry(_ t: AppleMusicSnapshot.Track) -> Entry { Entry(artist: t.artist, track: t.name) }
        // Apple Music side only: a spelling the user said is the same song as a Last.fm one takes that one's key.
        var alias: [String: String] = [:]
        var rejected = Set<String>()
        for d in decisions {
            if d.sameTrack { alias[key(d.apple)] = key(d.lastfm) } else { rejected.insert(key(d.lastfm) + "\u{1}" + key(d.apple)) }
        }
        func appleKey(_ e: Entry) -> String { alias[key(e)] ?? key(e) }
        // A favorite is "not in the library" when Music gave it an ID that no library track has. Without IDs (an older
        // read, or the favorited-flag fallback, where favorites ARE library tracks) nothing is flagged.
        let libraryIDs = Set(apple.library.compactMap(\.databaseID))
        func notInLibrary(_ t: AppleMusicSnapshot.Track) -> AppleFavoriteNotInLibrary? {
            guard !libraryIDs.isEmpty, let id = t.databaseID, !libraryIDs.contains(id) else { return nil }
            return AppleFavoriteNotInLibrary(origin: t.cloudStatus == "subscription" ? .catalogue : .leftover, databaseID: id, name: t.name, artist: t.artist)
        }

        var lastfmByKey: [String: Entry] = [:]
        for e in lovedOnLastfm { lastfmByKey[key(e)] = lastfmByKey[key(e)] ?? e }
        var favoritesByKey: [String: AppleMusicSnapshot.Track] = [:]
        for t in apple.favorites { favoritesByKey[appleKey(appleEntry(t))] = favoritesByKey[appleKey(appleEntry(t))] ?? t }
        let libraryKeys = Set(apple.library.map { appleKey(appleEntry($0)) })
        let historyKeys = Set(history.map(key))

        var rows: [LovedAuditRow] = []
        var lastfmOnly: [String: Entry] = [:]
        for (k, e) in lastfmByKey {
            if let fav = favoritesByKey[k] {
                rows.append(LovedAuditRow(id: k, artist: e.artist, track: e.track, album: fav.album.isEmpty ? nil : fav.album, lastfm: .loved, appleMusic: .loved, uncertainty: nil, lastfmHasScrobbles: historyKeys.contains(k), appleNotInLibrary: notInLibrary(fav)))
            } else { lastfmOnly[k] = e }
        }
        var appleOnly = favoritesByKey.filter { lastfmByKey[$0.key] == nil }

        // Loved on both, but spelled differently: pair them up, one-to-one, rather than reporting two discrepancies.
        let appleOnlyIndex = NearIndex(appleOnly.values.map(appleEntry))
        var pairedApple = Set<String>()
        for (k, e) in lastfmOnly.sorted(by: { $0.key < $1.key }) {
            guard let near = appleOnlyIndex.nearest(artist: e.artist, track: e.track, isExcluded: { rejected.contains(key(e) + "\u{1}" + key($0)) }) else { continue }
            let nearKey = appleKey(near)
            guard appleOnly[nearKey] != nil, pairedApple.insert(nearKey).inserted else { continue }
            rows.append(LovedAuditRow(
                id: k, artist: e.artist, track: e.track, album: appleOnly[nearKey]?.album, lastfm: .loved, appleMusic: .loved,
                uncertainty: LovedAuditUncertainty(side: .appleMusic, artist: near.artist, track: near.track),
                lastfmHasScrobbles: historyKeys.contains(k), appleNotInLibrary: appleOnly[nearKey].flatMap(notInLibrary)
            ))
            lastfmOnly[k] = nil
            appleOnly[nearKey] = nil
        }

        let libraryIndex = NearIndex(apple.library.map(appleEntry))
        for (k, e) in lastfmOnly {
            if libraryKeys.contains(k) {
                rows.append(LovedAuditRow(id: k, artist: e.artist, track: e.track, album: nil, lastfm: .loved, appleMusic: .notLoved, uncertainty: nil, lastfmHasScrobbles: historyKeys.contains(k)))
            } else {
                let near = libraryIndex.nearest(artist: e.artist, track: e.track, isExcluded: { rejected.contains(key(e) + "\u{1}" + key($0)) })
                rows.append(LovedAuditRow(
                    id: k, artist: e.artist, track: e.track, album: nil, lastfm: .loved, appleMusic: .notPresent,
                    uncertainty: near.map { LovedAuditUncertainty(side: .appleMusic, artist: $0.artist, track: $0.track) },
                    lastfmHasScrobbles: historyKeys.contains(k)
                ))
            }
        }

        let historyIndex = NearIndex(history)
        for (k, t) in appleOnly {
            let e = appleEntry(t)
            if historyKeys.contains(k) {
                rows.append(LovedAuditRow(id: k, artist: t.artist, track: t.name, album: t.album.isEmpty ? nil : t.album, lastfm: .notLoved, appleMusic: .loved, uncertainty: nil, appleNotInLibrary: notInLibrary(t)))
            } else {
                let near = historyIndex.nearest(artist: e.artist, track: e.track, isExcluded: { rejected.contains(key($0) + "\u{1}" + key(e)) })
                rows.append(LovedAuditRow(
                    id: k, artist: t.artist, track: t.name, album: t.album.isEmpty ? nil : t.album, lastfm: .notPresent, appleMusic: .loved,
                    uncertainty: near.map { LovedAuditUncertainty(side: .lastfm, artist: $0.artist, track: $0.track) },
                    appleNotInLibrary: notInLibrary(t)
                ))
            }
        }

        rows.sort { ($0.artist.lowercased(), $0.track.lowercased()) < ($1.artist.lowercased(), $1.track.lowercased()) }
        return LovedAudit(rows: rows, lastfmLovedCount: lastfmByKey.count, appleFavoritesCount: favoritesByKey.count)
    }
}

#if DEBUG
/// Verification hook: `SCROBLYTICS_LOVEDAUDIT_DUMP=/path/out.txt` reads Music.app live, joins it with the store's
/// loved set and scrobble history, writes the counts and every non-agreeing row, and quits.
enum LovedAuditDebugEval {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        guard let path = ProcessInfo.processInfo.environment["SCROBLYTICS_LOVEDAUDIT_DUMP"] else { return }
        Task { @MainActor in
            var out: [String] = []
            do {
                let loved = try container.mainContext.fetch(FetchDescriptor<LovedTrackEntry>()).map { LovedStatusAuditEngine.Entry(artist: $0.artist, track: $0.track) }
                let snapshots = try await ScrobbleHistoryCache.shared.snapshots(container: container)
                var seen = Set<String>()
                var history: [LovedStatusAuditEngine.Entry] = []
                for s in snapshots where seen.insert("\(s.artistName)\u{0}\(s.trackName)").inserted {
                    history.append(.init(artist: s.artistName, track: s.trackName))
                }
                let apple = try await AppleMusicFavoritesReader.read()
                out.append("APPLE read \(String(format: "%.2f", apple.readSeconds))s favorites=\(apple.favorites.count) library=\(apple.library.count) source=\(apple.source)")
                let started = Date()
                let audit = LovedStatusAuditEngine.audit(lovedOnLastfm: loved, history: history, apple: apple)
                out.append("JOIN \(String(format: "%.2f", Date().timeIntervalSince(started)))s lastfmLoved=\(audit.lastfmLovedCount) appleFavorites=\(audit.appleFavoritesCount)")
                out.append("COUNTS agree=\(audit.agreeCount) lastfmOnly=\(audit.lastfmOnlyCount) appleOnly=\(audit.appleOnlyCount) uncertain=\(audit.uncertainCount) rows=\(audit.rows.count)")
                for r in audit.discrepancies {
                    out.append("ROW\t\(r.artist)\t\(r.track)\tLF=\(r.lastfm)\tAM=\(r.appleMusic)\t\(r.uncertainty?.detail ?? "")")
                }
                // Apple favorites that the library read does not contain (by the same key), with what the library does hold for that artist.
                let libraryKeys = Set(apple.library.map { AppleMusicMatcher.durationMatchKey(artist: $0.artist, track: $0.name) })
                let ghosts = apple.favorites.filter { !libraryKeys.contains(AppleMusicMatcher.durationMatchKey(artist: $0.artist, track: $0.name)) }
                out.append("GHOSTFAVORITES \(ghosts.count) of \(apple.favorites.count) (favorites not found in the library read)")
                for g in ghosts { out.append("GHOST\t\(g.artist)\t\(g.name)\t\(g.album)") }
                if let probe = ProcessInfo.processInfo.environment["SCROBLYTICS_LOVEDAUDIT_PROBE"] {
                    for term in probe.split(separator: "|").map(String.init) {
                        for t in apple.library where t.name.localizedCaseInsensitiveContains(term) { out.append("PROBE-LIB[\(term)]\t\(t.artist)\t\(t.name)\t\(t.album)") }
                        for t in apple.favorites where t.name.localizedCaseInsensitiveContains(term) { out.append("PROBE-FAV[\(term)]\t\(t.artist)\t\(t.name)\t\(t.album)") }
                    }
                }
                // For each favorite the library read doesn't contain: what the library and the Favorite Songs playlist each hold for
                // the same artist and album (database ID, favorited flag, cloud status), to see whether they are the same item.
                if ProcessInfo.processInfo.environment["SCROBLYTICS_LOVEDAUDIT_GHOSTDETAIL"] != nil {
                    let script = """
                    on run argv
                      set theArtist to item 1 of argv
                      set theAlbum to item 2 of argv
                      set out to ""
                      tell application "Music"
                        set libs to (every track of library playlist 1 whose artist is theArtist and album is theAlbum)
                        repeat with t in libs
                          set out to out & "  LIB " & (name of t) & " | id " & (database ID of t) & " | favorited " & (favorited of t) & " | cloud " & (cloud status of t) & linefeed
                        end repeat
                        try
                          set favs to (every track of playlist "Favorite Songs" whose artist is theArtist and album is theAlbum)
                          repeat with t in favs
                            set out to out & "  FAV " & (name of t) & " | id " & (database ID of t) & " | favorited " & (favorited of t) & " | cloud " & (cloud status of t) & linefeed
                          end repeat
                        end try
                      end tell
                      return out
                    end run
                    """
                    var seenPairs = Set<String>()
                    for g in ghosts where seenPairs.insert("\(g.artist)\u{0}\(g.album)").inserted {
                        let detail = (try? await AppleMusicMatcher.runAppleScript(script, arguments: [g.artist, g.album])) ?? "(script failed)"
                        out.append("GHOSTDETAIL \(g.artist) — \(g.album)\n\(detail)")
                    }
                }
                out.append("NOTINLIBRARY count=\(audit.notInLibraryCount)")
                var dryTargets: [AppleMusicFavoritesWriter.Target] = []
                for r in audit.rows {
                    guard let g = r.appleNotInLibrary else { continue }
                    out.append("NOTINLIBRARY\t\(g.origin)\tid=\(g.databaseID)\t\(g.name)\t\(g.artist)")
                    dryTargets.append(.init(id: g.databaseID, name: g.name, artist: g.artist))
                }
                // A dry run never changes anything: it only reports whether each entry would be found and matched.
                if ProcessInfo.processInfo.environment["SCROBLYTICS_LOVEDAUDIT_DRYRUN_REMOVE"] != nil {
                    for result in await AppleMusicFavoritesWriter.unfavorite(dryTargets, dryRun: true) {
                        out.append("DRYRUN\t\(result.target.id)\t\(result.target.name)\t\(result.outcome)")
                    }
                    if let first = dryTargets.first {
                        let wrong = AppleMusicFavoritesWriter.Target(id: first.id, name: first.name + " (wrong)", artist: first.artist)
                        for result in await AppleMusicFavoritesWriter.unfavorite([wrong], dryRun: true) {
                            out.append("DRYRUN-WRONGNAME\t\(result.target.id)\t\(result.outcome)")
                        }
                    }
                    let readBack = (try? await AppleMusicFavoritesReader.read())?.favorites.count ?? -1
                    out.append("DRYRUN favorites before=\(apple.favorites.count) after=\(readBack) (must be equal: nothing changed)")
                }
                out.append("LOVEDNOSCROBBLES count=\(audit.lovedWithoutScrobblesCount)")
                for r in audit.rows.filter(\.isLovedWithoutScrobbles) {
                    out.append("NOSCROBBLES\t\(r.artist)\t\(r.track)\tAM=\(r.appleMusic)")
                }
                // `SCROBLYTICS_LOVEDAUDIT_DECISIONS="same|lfArtist|lfTrack|apArtist|apTrack;different|…"`: the same audit with those
                // decisions applied (in memory only), to see what they change.
                if let spec = ProcessInfo.processInfo.environment["SCROBLYTICS_LOVEDAUDIT_DECISIONS"] {
                    let decisions: [LovedStatusAuditEngine.Decision] = spec.split(separator: ";").compactMap { item in
                        let f = item.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                        guard f.count == 5, f[0] == "same" || f[0] == "different" else { return nil }
                        return .init(lastfm: .init(artist: f[1], track: f[2]), apple: .init(artist: f[3], track: f[4]), sameTrack: f[0] == "same")
                    }
                    let after = LovedStatusAuditEngine.audit(lovedOnLastfm: loved, history: history, apple: apple, decisions: decisions)
                    let stale = LovedStatusAuditEngine.obsoleteDecisions(decisions, lovedOnLastfm: loved, history: history, apple: apple)
                    out.append("OBSOLETE \(stale.count) of \(decisions.count): \(stale.map { "\($0.lastfm.track)/\($0.apple.track)" })")
                    out.append("DECIDED \(decisions.count) -> COUNTS agree=\(after.agreeCount) lastfmOnly=\(after.lastfmOnlyCount) appleOnly=\(after.appleOnlyCount) uncertain=\(after.uncertainCount) lovedNoScrobbles=\(after.lovedWithoutScrobblesCount) rows=\(after.rows.count)")
                    for d in decisions {
                        for r in after.rows where r.artist == d.lastfm.artist || r.artist == d.apple.artist {
                            if r.track == d.lastfm.track || r.track == d.apple.track {
                                out.append("AFTER\t\(r.artist)\t\(r.track)\tLF=\(r.lastfm)\tAM=\(r.appleMusic)\tuncertain=\(r.uncertainty != nil)")
                            }
                        }
                    }
                }
            } catch {
                out.append("ERROR: \(error)")
            }
            try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            exit(0)
        }
    }
}
#endif
