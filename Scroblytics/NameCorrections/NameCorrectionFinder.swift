import Foundation

/// Finds names whose capitalization or spacing looks off, so the person can fix or dismiss each one (the "Name Corrections" tool). Pure: it
/// reads plays and the keys of corrections already decided, and decides nothing itself.
///
/// What it looks for, in order of how sure it is:
/// - **Variants**: the same name spelled with different capitalization or spacing in different plays ("Song TWO" and "Song two").
/// - **Spacing**: a name with a leading, trailing or doubled space.
/// - **Odd capitals**: a capital in the middle of a word ("MidNight"). Albums and tracks only; an artist's styling is usually deliberate.
/// - **ALL CAPS**: a name of four or more letters written entirely in capitals. Albums and tracks only.
enum NameCorrectionFinder {
    enum Reason: String, Codable, Sendable, CaseIterable {
        case variants, spacing, oddCapitals, allCaps

        var label: String {
            switch self {
            case .variants: "Different spellings"
            case .spacing: "Extra spaces"
            case .oddCapitals: "Odd capitals"
            case .allCaps: "ALL CAPS"
            }
        }

        var explanation: String {
            switch self {
            case .variants: "Last.fm has this name spelled more than one way. Choosing one counts them together."
            case .spacing: "The name has a leading, trailing or doubled space."
            case .oddCapitals: "A capital letter inside a word. Often a typo, sometimes how the name is really styled: use Looks Right then."
            case .allCaps: "Written entirely in capitals. Often just how it was entered; use Looks Right if it is meant."
            }
        }

        /// How likely a suggestion is to be what the person wants, for ordering.
        var rank: Int {
            switch self { case .variants: 0; case .spacing: 1; case .oddCapitals: 2; case .allCaps: 3 }
        }
    }

    struct Spelling: Hashable, Sendable {
        let name: String
        let plays: Int
    }

    struct Finding: Identifiable, Hashable, Sendable {
        let kind: NameCorrectionKind
        /// Last.fm's artist spelling most often used with the name (for an artist, its own name).
        let artist: String
        /// Last.fm's spellings of the name, most played first.
        let spellings: [Spelling]
        /// The spelling to apply, always the same name apart from capitalization and spacing.
        let suggestion: String
        let reason: Reason
        /// The key a correction for this name is stored under.
        let key: String

        var id: String { key }
        var plays: Int { spellings.reduce(0) { $0 + $1.plays } }
        /// The spelling Last.fm uses most; what a correction is filed against.
        var original: String { spellings.first?.name ?? suggestion }
        /// Applying the suggestion merges several spellings (so it must be saved even when it equals the most-used one).
        var mergesSpellings: Bool { spellings.count > 1 }
    }

    // MARK: Finding

    /// Every name in `plays` that looks wrong, most-played first. `handled` holds the keys of names already corrected or marked as right.
    static func find(plays: [ScrobbleSnapshot], handled: Set<String>) -> [Finding] {
        struct Pair: Hashable { let first: String; let second: String }
        var artistPlays: [String: Int] = [:]
        var albumPlays: [Pair: Int] = [:]
        var trackPlays: [Pair: Int] = [:]
        for play in plays {
            artistPlays[play.artistName, default: 0] += 1
            if !play.albumName.isEmpty { albumPlays[Pair(first: play.artistName, second: play.albumName), default: 0] += 1 }
            trackPlays[Pair(first: play.artistName, second: play.trackName), default: 0] += 1
        }

        // Group the distinct spellings that are the same name, per kind.
        struct Group {
            var names: [String: Int] = [:]
            var artists: [String: Int] = [:]
        }
        var artistGroups: [String: Group] = [:]
        for (name, count) in artistPlays where !NameKeys.fold(name).isEmpty {
            artistGroups[NameKeys.artist(name), default: Group()].names[name, default: 0] += count
        }
        var albumGroups: [String: Group] = [:]
        for (pair, count) in albumPlays {
            let key = NameKeys.album(artist: pair.first, album: pair.second)
            albumGroups[key, default: Group()].names[pair.second, default: 0] += count
            albumGroups[key]?.artists[pair.first, default: 0] += count
        }
        var trackGroups: [String: Group] = [:]
        for (pair, count) in trackPlays where !NameKeys.fold(pair.second).isEmpty {
            let key = NameKeys.track(artist: pair.first, title: pair.second)
            trackGroups[key, default: Group()].names[pair.second, default: 0] += count
            trackGroups[key]?.artists[pair.first, default: 0] += count
        }

        var findings: [Finding] = []
        func evaluate(_ groups: [String: Group], kind: NameCorrectionKind) {
            for (key, group) in groups where !handled.contains(key) {
                let spellings = group.names
                    .map { Spelling(name: $0.key, plays: $0.value) }
                    .sorted { $0.plays != $1.plays ? $0.plays > $1.plays : $0.name < $1.name }
                guard let top = spellings.first else { continue }
                let artist = kind == .artist
                    ? top.name
                    : (group.artists.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? "")
                if let found = assess(spellings: spellings, kind: kind) {
                    findings.append(Finding(kind: kind, artist: artist, spellings: spellings, suggestion: found.suggestion, reason: found.reason, key: key))
                }
            }
        }
        evaluate(artistGroups, kind: .artist)
        evaluate(albumGroups, kind: .album)
        evaluate(trackGroups, kind: .track)
        return findings.sorted { a, b in
            if a.reason.rank != b.reason.rank { return a.reason.rank < b.reason.rank }
            if a.plays != b.plays { return a.plays > b.plays }
            return a.key < b.key
        }
    }

    /// What is wrong with one name (given all its spellings), and the spelling to suggest. nil when nothing looks wrong.
    static func assess(spellings: [Spelling], kind: NameCorrectionKind) -> (suggestion: String, reason: Reason)? {
        guard let top = spellings.first else { return nil }
        let checksStyle = kind != .artist
        func problem(_ name: String) -> Bool {
            name != NameKeys.tidy(name) || (checksStyle && (hasOddCapitals(name) || isAllCaps(name)))
        }
        if spellings.count > 1 {
            // The cleanest spelling wins; among equally clean ones, the most played.
            let best = spellings.min { a, b in
                let (pa, pb) = (problem(a.name), problem(b.name))
                if pa != pb { return !pa }
                if a.plays != b.plays { return a.plays > b.plays }
                return a.name < b.name
            } ?? top
            var suggestion = NameKeys.tidy(best.name)
            if checksStyle, hasOddCapitals(suggestion) { suggestion = fixOddCapitals(suggestion) }
            return valid(suggestion, against: top.name) ? (suggestion, .variants) : nil
        }
        if top.name != NameKeys.tidy(top.name) {
            let suggestion = NameKeys.tidy(top.name)
            return valid(suggestion, against: top.name) ? (suggestion, .spacing) : nil
        }
        guard checksStyle else { return nil }
        if hasOddCapitals(top.name) {
            let suggestion = fixOddCapitals(top.name)
            return suggestion != top.name && valid(suggestion, against: top.name) ? (suggestion, .oddCapitals) : nil
        }
        if isAllCaps(top.name) {
            let suggestion = titleCased(top.name)
            return suggestion != top.name && valid(suggestion, against: top.name) ? (suggestion, .allCaps) : nil
        }
        return nil
    }

    private static func valid(_ suggestion: String, against original: String) -> Bool {
        switch NameCorrectionRules.validate(original: original, proposed: suggestion) {
        case .ok, .unchanged: return true
        case .rejected: return false
        }
    }

    // MARK: Style rules

    /// Words that are written with a capital inside on purpose, so they are never flagged or changed.
    private static let styledWords: Set<String> = ["iPhone", "iPad", "iPod", "iTunes", "iMac", "iOS", "macOS", "eBay", "YouTube", "PlayStation", "WiFi", "DJs", "MCs"]

    /// The pieces of a name that are words: split at spaces, hyphens, slashes and brackets, keeping what each piece is made of.
    private static func words(_ name: String) -> [String] {
        name.split(whereSeparator: { " -/()[]{}\u{2013}\u{2014}".contains($0) }).map(String.init)
    }

    /// A word with a lower-case letter directly followed by a capital ("MidNight"), apart from the usual name shapes (McDonald, MacArthur,
    /// O'Brien) and words styled that way on purpose (iPhone).
    private static func isOddCapitalWord(_ word: String) -> Bool {
        if styledWords.contains(word) { return false }
        let chars = Array(word)
        guard chars.count >= 3 else { return false }
        var start = 0
        // Name prefixes whose next letter is a capital: Mc, Mac, O', D', L'.
        if word.hasPrefix("Mc"), chars.count > 2, chars[2].isUppercase { start = 2 }
        else if word.hasPrefix("Mac"), chars.count > 3, chars[3].isUppercase { start = 3 }
        else if let apostrophe = chars.firstIndex(where: { $0 == "'" || $0 == "\u{2019}" }), apostrophe <= 1, apostrophe + 1 < chars.count, chars[apostrophe + 1].isUppercase { start = apostrophe + 1 }
        var index = start
        while index + 1 < chars.count {
            if chars[index].isLowercase, chars[index + 1].isUppercase { return true }
            index += 1
        }
        return false
    }

    static func hasOddCapitals(_ name: String) -> Bool { words(name).contains(where: isOddCapitalWord) }

    /// The name with every odd-capital word lower-cased after its first letter ("MidNight" becomes "Midnight").
    static func fixOddCapitals(_ name: String) -> String {
        var result = ""
        var current = ""
        func flush() {
            if isOddCapitalWord(current) {
                let first = current.prefix(1)
                result += first + current.dropFirst().lowercased()
            } else {
                result += current
            }
            current = ""
        }
        for character in name {
            if " -/()[]{}\u{2013}\u{2014}".contains(character) { flush(); result.append(character) } else { current.append(character) }
        }
        flush()
        return result
    }

    /// Four or more letters, every one of them a capital.
    static func isAllCaps(_ name: String) -> Bool {
        let letters = name.filter { $0.isLetter && ($0.isUppercase || $0.isLowercase) }
        return letters.count >= 4 && letters.allSatisfy(\.isUppercase)
    }

    /// Letters each followed by a full stop: "U.F.O.F.", "A.M." (kept as written).
    static func isDottedAcronym(_ word: String) -> Bool {
        let chars = Array(word)
        guard chars.count >= 4, chars.contains("."), chars.allSatisfy({ $0.isLetter || $0 == "." }) else { return false }
        var index = 0
        while index < chars.count {
            guard chars[index].isLetter else { return false }
            if index + 1 < chars.count { guard chars[index + 1] == "." else { return false } }
            index += 2
        }
        return true
    }

    private static let smallWords: Set<String> = ["a", "an", "the", "and", "but", "or", "nor", "for", "of", "in", "on", "at", "to", "by", "as", "vs", "vs."]
    private static let romanNumerals: Set<String> = ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII", "XIII", "XIV", "XV", "XX"]

    /// Title Case: the first letter of each word capital and the rest lower case, small words (of, the, and…) lower case except at the start,
    /// Roman numerals kept as they are. A suggestion only: the person can edit it before applying.
    static func titleCased(_ name: String) -> String {
        var result = ""
        var word = ""
        var isFirst = true
        func flush() {
            guard !word.isEmpty else { return }
            if romanNumerals.contains(word) || isDottedAcronym(word) {
                result += word
            } else if !isFirst, smallWords.contains(word.lowercased()) {
                result += word.lowercased()
            } else {
                result += word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }
            isFirst = false
            word = ""
        }
        for character in name {
            if character.isWhitespace || "-/()[]{}\u{2013}\u{2014}".contains(character) {
                flush()
                result.append(character)
            } else {
                word.append(character)
            }
        }
        flush()
        return result
    }
}
