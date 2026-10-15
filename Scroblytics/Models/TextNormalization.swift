import Foundation

/// Name normalization shared across the app. These are the identity keys used
/// for album-match resolutions and (via `lovedKey`) for loved tracks, flagged
/// tracks, and track duration/BPM overrides — keeping them stable keeps backups
/// restorable against the same identities this schema uses.
enum TextNormalization {
    // Longest-alternative-first so multi-word phrases match before a shorter
    // alternative would greedily consume part of them (the list is
    // length-sorted before joining).
    private static let editionWordList = [
        "deluxe edition", "super deluxe", "deluxe",
        "expanded edition", "expanded",
        "re-?master(?:ed)?", "remastered version", "remastered", "remaster",
        "anniversary edition", "\\d+th anniversary", "anniversary",
        "bonus track version", "bonus tracks", "bonus track", "bonus",
        "special edition", "special",
        "collector'?s edition", "collector'?s",
        "limited edition", "limited",
        "re-?issue", "reissue",
        "import", "mono", "stereo", "explicit", "clean", "instrumental", "acoustic",
        "edition", "version",
    ].sorted { $0.count > $1.count }

    private static let editionWordRegex = try! NSRegularExpression(
        pattern: "\\b(?:\(editionWordList.joined(separator: "|")))\\b",
        options: [.caseInsensitive]
    )

    private static let regionTagList = [
        "uk", "us", "usa", "eu", "europe", "jp", "japan", "de", "germany", "fr", "france",
        "ca", "canada", "au", "australia", "nl", "it", "italy", "es", "spain", "br", "brazil",
        "mx", "mexico", "kr", "korea", "asia", "row", "ww", "worldwide", "int\\b", "international",
    ]
    private static let regionTagRegex = try! NSRegularExpression(
        pattern: "\\b(?:\(regionTagList.joined(separator: "|")))\\b",
        options: [.caseInsensitive]
    )
    private static let yearRegex = try! NSRegularExpression(pattern: "\\b\\d{4}\\b")

    // NOTE: the natural pattern `/[([]([^()\[\]]*)[)\]]/g` has a character
    // class containing a literal, unescaped `[`. That's valid in JavaScript's
    // regex engine but NOT in ICU (NSRegularExpression's engine): an unescaped
    // `[` inside a character class fails to compile there. This previously
    // used `try?` with a silent "return unchanged" fallback, which hid the
    // compile failure entirely — `stripEditionParens` silently never stripped
    // anything, for every input, and nobody noticed until cross-validating
    // synced Album entities against a real backup export surfaced albums like
    // "Revolver [UK]" normalizing to "revolver uk" instead of "revolver".
    // Fixed by escaping the `[`, and hoisted to `try!` so a future mistake
    // like this fails at launch instead of silently producing wrong data.
    private static let editionParenRegex = try! NSRegularExpression(pattern: "[(\\[]([^()\\[\\]]*)[)\\]]")
    private static let trailingEditionRegex = try! NSRegularExpression(pattern: "^(.*?)[-:]\\s*([^-:]+)$")
    private static let featTagRegex = try! NSRegularExpression(
        pattern: "[(\\[]\\s*feat\\.?[^)\\]]*[)\\]]", options: [.caseInsensitive]
    )

    private static func replacing(_ regex: NSRegularExpression, in s: String, with template: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: template)
    }

    /// True when `text` is entirely edition vocabulary, region tags, and/or bare years.
    private static func isEditionOnlyText(_ text: String) -> Bool {
        var s = replacing(editionWordRegex, in: text, with: " ")
        s = replacing(regionTagRegex, in: s, with: " ")
        s = replacing(yearRegex, in: s, with: " ")
        s = s.replacingOccurrences(of: "[\\s,&]+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Strips "(...)"/"[...]" chunks whose entire contents are edition vocabulary.
    private static func stripEditionParens(_ s: String) -> String {
        let ns = s as NSString
        var result = ""
        var lastEnd = 0
        for match in editionParenRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            let inner = ns.substring(with: match.range(at: 1))
            result += isEditionOnlyText(inner) ? " " : ns.substring(with: match.range)
            lastEnd = match.range.location + match.range.length
        }
        result += ns.substring(from: lastEnd)
        return result
    }

    /// Strips a trailing "... - Remastered 2011" / "... : Deluxe Edition" tail
    /// when everything after the last dash/colon is edition vocabulary and/or a year.
    private static func stripTrailingEdition(_ s: String) -> String {
        let ns = s as NSString
        guard let m = trailingEditionRegex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return s }
        let head = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        let tail = ns.substring(with: m.range(at: 2))
        return isEditionOnlyText(tail) ? head : s
    }

    private static func collapse(_ s: String) -> String {
        var n = s.lowercased()
        n = n.replacingOccurrences(of: "&", with: "and")
        n = n.replacingOccurrences(of: "[’‘]", with: "'", options: .regularExpression)
        n = n.replacingOccurrences(of: "[^a-z0-9']+", with: " ", options: .regularExpression)
        n = n.trimmingCharacters(in: .whitespaces)
        n = n.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return n
    }

    /// Strips edition-suffix parentheticals/trailing tails (e.g. "(25th
    /// Anniversary Edition)", "- Remastered 2011") but KEEPS original casing/
    /// punctuation — for querying external catalogs (album.getInfo), which
    /// index the plain release-group/original-release title, not the
    /// edition-suffixed one.
    static func stripEditionSuffix(_ name: String) -> String {
        var n = name.trimmingCharacters(in: .whitespaces)
        var prev = ""
        while n != prev {
            prev = n
            n = stripEditionParens(n).trimmingCharacters(in: .whitespaces)
        }
        prev = ""
        while n != prev {
            prev = n
            n = stripTrailingEdition(n).trimmingCharacters(in: .whitespaces)
        }
        return n.isEmpty ? name.trimmingCharacters(in: .whitespaces) : n
    }

    /// Strips edition suffixes, then pulls any remaining parenthesized/
    /// bracketed text OUT of the query entirely as a "hint" rather than
    /// leaving it quoted in the search string — e.g. "The Beatles (White
    /// Album)" -> base "The Beatles", hints ["White Album"]. Quoting a
    /// nickname literally in a MusicBrainz query can exact-match an
    /// unrelated release-group whose title happens to contain that text (a
    /// boxset literally titled "The Beatles (White Album)") instead of the
    /// real album (titled plainly "The Beatles", disambiguation "The White
    /// Album").
    static func extractQueryHints(_ name: String) -> (base: String, hints: [String]) {
        let stripped = stripEditionSuffix(name)
        let regex = try! NSRegularExpression(pattern: "[(\\[]([^()\\[\\]]*)[)\\]]")
        let nsStripped = stripped as NSString
        var hints: [String] = []
        var base = ""
        var cursor = 0
        for match in regex.matches(in: stripped, range: NSRange(location: 0, length: nsStripped.length)) {
            base += nsStripped.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            base += " "
            let inner = nsStripped.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty { hints.append(inner) }
            cursor = match.range.location + match.range.length
        }
        base += nsStripped.substring(from: cursor)
        base = base.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return (base.isEmpty ? stripped : base, hints)
    }

    /// Last.fm artist identity: surrounding whitespace is ignored and casing
    /// is folded, while punctuation and diacritics remain significant so
    /// genuinely distinct artist names are not merged.
    static func artistIdentityKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Chooses one stable display spelling for every case-only artist variant.
    /// The most-played raw spelling wins. Ties are
    /// deterministic so a chart does not flicker when input order changes.
    static func canonicalArtistNames(_ names: [String]) -> [String: String] {
        var counts: [String: [String: Int]] = [:]
        for rawName in names {
            let displayName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = artistIdentityKey(displayName)
            guard !key.isEmpty else { continue }
            counts[key, default: [:]][displayName, default: 0] += 1
        }

        return counts.mapValues { variants in
            variants.max { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key.localizedStandardCompare(rhs.key) == .orderedDescending
            }!.key
        }
    }

    /// Strips one leading "the "
    /// (case-insensitive) so "The Beatles" sorts/groups under "B", not "T".
    /// Falls back to the trimmed original when stripping leaves nothing
    /// (e.g. the name is literally "The") — not
    /// just "any leading article" (only "the", not "a"/"an").
    static func sortableName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(of: "^the\\s+", options: [.regularExpression, .caseInsensitive]) else {
            return trimmed
        }
        let stripped = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? trimmed : stripped
    }

    /// First character of the
    /// (already sortable-normalized) name, uppercased; "#" for anything
    /// that isn't A-Z (numbers, symbols, non-Latin scripts).
    static func sectionLetter(_ sortableName: String) -> String {
        guard let first = sortableName.trimmingCharacters(in: .whitespaces).first else { return "#" }
        let upper = String(first).uppercased()
        return upper.range(of: "^[A-Z]$", options: .regularExpression) != nil ? upper : "#"
    }

    /// Normalized album name used for grouping edition variants and cache keys.
    /// Normalizes an album name.
    static func normalizeAlbumName(_ name: String) -> String {
        var n = name.trimmingCharacters(in: .whitespaces)
        var prev = ""
        while n != prev {
            prev = n
            n = stripEditionParens(n).trimmingCharacters(in: .whitespaces)
        }
        prev = ""
        while n != prev {
            prev = n
            n = stripTrailingEdition(n).trimmingCharacters(in: .whitespaces)
        }
        return collapse(n)
    }

    /// Normalized track title for matching a scrobble against a canonical
    /// tracklist entry.
    static func normalizeTrackTitle(_ title: String) -> String {
        var t = title.trimmingCharacters(in: .whitespaces)
        t = stripEditionParens(t)
        t = replacing(featTagRegex, in: t, with: " ")
        t = t.replacingOccurrences(
            of: "\\s+-\\s+.*(remaster|version|edit|mix|mono|stereo).*$",
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        return collapse(t)
    }

    /// Album-agnostic key for matching a loved/flagged/overridden track — the
    /// exact identity used across Loved Tracks, Track Duration Overrides, and
    /// BPM Overrides.
    static func lovedKey(artist: String, track: String) -> String {
        "\(artist.trimmingCharacters(in: .whitespaces).lowercased()) \(track.trimmingCharacters(in: .whitespaces).lowercased())"
    }

    /// Stable per-album-group identity key: `<artist><separator><normalizedAlbum>`
    /// — used for Album Turnover's "Fix album match…" resolutions. An earlier
    /// design joined with a literal NUL byte, which is safe in a JSON string
    /// in a flat file but is NOT safe here: a NUL
    /// embedded in a SwiftData/CoreData string attribute gets silently
    /// truncated when persisted to the underlying SQLite column (confirmed
    /// via a hex dump of an actual synced `Album.identityKey` — every album
    /// for a given artist collapsed onto the same truncated "artist-name-only"
    /// key, so `@Attribute(.unique)` merged them into one row per artist).
    private static let albumKeySeparator = "\u{241F}" // ␟ SYMBOL FOR UNIT SEPARATOR — printable, SQLite-safe, unlikely in real names
    static func albumIdentityKey(artist: String, album: String) -> String {
        "\(artist)\(albumKeySeparator)\(normalizeAlbumName(album))"
    }

    /// One exact album name of one artist, edition words kept (case and spacing ignored): the identity of an
    /// edition that is counted on its own (`AlbumEditionMatch`). Unlike `albumIdentityKey`, "Album" and
    /// "Album (25th Anniversary Edition)" differ.
    static func editionIdentityKey(artist: String, album: String) -> String {
        let name = album.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
        return "\(artistIdentityKey(artist))\(albumKeySeparator)\(name)"
    }

    /// Exact album-variant identity for presentation overrides. Unlike
    /// `albumIdentityKey`, this deliberately preserves edition qualifiers so
    /// “Album” and “Album (25th Anniversary Edition)” can have different
    /// artwork while still sharing grouped statistics and match metadata.
    static func albumArtworkIdentityKey(artist: String, album: String) -> String {
        "\(artistIdentityKey(artist))\(albumKeySeparator)\(album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    // ── Compilation / collab-credit merging ─────────
    // Used by Top Charts' album ranking so a various-artists compilation or a
    // single-artist-plus-features album doesn't fragment into one row per
    // contributing artist credit.

    static let variousArtistsLabel = "Various Artists"

    private static let compilationArtistRegex = try! NSRegularExpression(
        pattern: "^(various(\\s+artists?)?|va|soundtrack|original\\s+(motion\\s+picture\\s+)?soundtrack)$",
        options: [.caseInsensitive]
    )

    static func isCompilationArtist(_ artist: String) -> Bool {
        let trimmed = artist.trimmingCharacters(in: .whitespaces)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return compilationArtistRegex.firstMatch(in: trimmed, range: range) != nil
    }

    private static let collabJoinerRegex = try! NSRegularExpression(
        pattern: "\\s*(?:&|\\+|,|\\bfeat\\.?\\b|\\bfeaturing\\b|\\bft\\.?\\b|\\bwith\\b|\\bx\\b|\\bvs\\.?\\b|\\band\\b)\\s*",
        options: [.caseInsensitive]
    )

    private static func splitCollabCredits(_ artist: String) -> [String] {
        let ns = artist as NSString
        var parts: [String] = []
        var lastEnd = 0
        for m in collabJoinerRegex.matches(in: artist, range: NSRange(location: 0, length: ns.length)) {
            parts.append(ns.substring(with: NSRange(location: lastEnd, length: m.range.location - lastEnd)))
            lastEnd = m.range.location + m.range.length
        }
        parts.append(ns.substring(from: lastEnd))
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// True when `artist` is a compound multi-artist credit line (e.g. "Beck &
    /// St. Vincent") that names `base` as one of its contributors.
    static func isCollabCreditOf(_ artist: String, base: String) -> Bool {
        let baseLower = base.trimmingCharacters(in: .whitespaces).lowercased()
        let parts = splitCollabCredits(artist)
        return parts.count > 1 && parts.contains { $0.lowercased() == baseLower }
    }

    /// True when a scrobbled track's artist tag should count toward `context`'s
    /// album/track scope — the same artist (capitalization ignored), the Various Artists sentinel, or a
    /// compound credit naming `context` as one of its contributors.
    static func trackMatchesArtistContext(trackArtist: String, context: String) -> Bool {
        if artistIdentityKey(trackArtist) == artistIdentityKey(context) { return true }
        if isCompilationArtist(context) { return true }
        return isCollabCreditOf(trackArtist, base: context) || isCollabCreditOf(context, base: trackArtist)
    }

    enum AlbumMergeDecision: Equatable {
        case compilation
        case primaryArtist(artist: String)
    }

    private static let minCompilationUnrelatedArtists = 2

    /// Detects album names (normalized) that should merge into one entity
    /// instead of one row per contributing artist. Ties in the by-plays sort
    /// are broken by artist name for determinism (Swift's Dictionary has no
    /// stable iteration order, so an explicit tiebreak is needed); it only
    /// affects which of two exactly-tied contributors is treated as "primary",
    /// a rare, low-stakes edge case.
    static func detectAlbumMerges(_ scrobbles: [(artist: String, album: String)]) -> [String: AlbumMergeDecision] {
        var byNormAlbum: [String: [String: Int]] = [:]
        for s in scrobbles {
            guard !s.album.isEmpty else { continue }
            let norm = normalizeAlbumName(s.album)
            guard !norm.isEmpty else { continue }
            byNormAlbum[norm, default: [:]][s.artist, default: 0] += 1
        }

        var result: [String: AlbumMergeDecision] = [:]
        for (norm, byArtist) in byNormAlbum {
            guard byArtist.count >= 2 else { continue }
            let sorted = byArtist.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            let primaryArtist = sorted[0].key
            let unrelated = sorted.dropFirst().filter { other in
                !isCollabCreditOf(other.key, base: primaryArtist) && !isCollabCreditOf(primaryArtist, base: other.key)
            }
            if unrelated.isEmpty {
                result[norm] = .primaryArtist(artist: primaryArtist)
            } else if unrelated.count >= minCompilationUnrelatedArtists {
                result[norm] = .compilation
            }
        }
        return result
    }

    // ── Fuzzy album-name similarity — used by
    // buildAlbumGroups to consolidate a user's various raw-scrobbled edition
    // variants for ONE artist into a single working album group, distinct
    // from detectAlbumMerges (which merges the same normalized name ACROSS
    // different artist tags for Top Charts' compilation handling).

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        let aChars = Array(a)
        let bChars = Array(b)
        var prev = Array(0...bChars.count)
        for i in 1...aChars.count {
            var curr = [i]
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr.append(Swift.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost))
            }
            prev = curr
        }
        return prev[bChars.count]
    }

    /// True when `needle`'s words appear as a contiguous run of whole words
    /// inside `haystack` (both already space-collapsed) — returns the
    /// haystack words NOT covered by that run, or nil if there's no such run.
    private static func wordRunLeftover(haystack: String, needle: String) -> [String]? {
        guard !needle.isEmpty else { return nil }
        let hWords = haystack.split(separator: " ").map(String.init)
        let nWords = needle.split(separator: " ").map(String.init)
        guard nWords.count <= hWords.count else { return nil }
        for i in 0...(hWords.count - nWords.count) {
            if (0..<nWords.count).allSatisfy({ hWords[i + $0] == nWords[$0] }) {
                return Array(hWords[0..<i]) + Array(hWords[(i + nWords.count)...])
            }
        }
        return nil
    }

    private static func isEditionOnlyLeftover(_ words: [String]) -> Bool {
        if words.isEmpty { return true }
        var stripped = replacing(editionWordRegex, in: words.joined(separator: " "), with: " ")
        stripped = replacing(regionTagRegex, in: stripped, with: " ")
        stripped = stripped.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return stripped.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static let similarityThreshold = 0.72

    /// True when two already-normalized album names are close enough to be
    /// the same release.
    static func albumNamesSimilar(_ na: String, _ nb: String) -> Bool {
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na == nb { return true }
        if let leftover = wordRunLeftover(haystack: na, needle: nb) ?? wordRunLeftover(haystack: nb, needle: na),
           isEditionOnlyLeftover(leftover) {
            return true
        }
        let maxLen = Swift.max(na.count, nb.count)
        guard maxLen > 0 else { return true }
        return 1 - Double(levenshtein(na, nb)) / Double(maxLen) >= similarityThreshold
    }

    // ── Placeholder-image detection ───────

    private static let lastfmPlaceholderHash = "2a96cbd8b46e442fc41c2b86b821562f"

    static func isLastfmPlaceholderImage(_ url: String?) -> Bool {
        guard let url else { return false }
        return containsBytes(url, lastfmPlaceholderHashBytes)
    }

    private static let lastfmPlaceholderHashBytes = Array(lastfmPlaceholderHash.utf8)

    /// `haystack.contains(needle)` for a byte needle, about forty times faster than `String.contains` (which goes through NSString):
    /// it is asked once per play, for every play in the history, by every screen that reads the artwork.
    static func containsBytes(_ haystack: String, _ needle: [UInt8]) -> Bool {
        guard let first = needle.first else { return true }
        var text = haystack
        return text.withUTF8 { buffer in
            let last = buffer.count - needle.count
            guard last >= 0 else { return false }
            var i = 0
            while i <= last {
                if buffer[i] == first {
                    var j = 1
                    while j < needle.count && buffer[i + j] == needle[j] { j += 1 }
                    if j == needle.count { return true }
                }
                i += 1
            }
            return false
        }
    }

    /// Prefers a real (non-placeholder) image among the given URLs (in order)
    /// over a Last.fm placeholder.
    static func firstNonPlaceholderImage<S: Sequence>(_ urls: S) -> String? where S.Element == String? {
        var placeholder: String? = nil
        for img in urls {
            guard let img, !img.isEmpty else { continue }
            if isLastfmPlaceholderImage(img) {
                if placeholder == nil { placeholder = img }
                continue
            }
            return img
        }
        return placeholder
    }
}
