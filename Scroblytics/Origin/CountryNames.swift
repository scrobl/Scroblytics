import Foundation

/// One way to say which country: an ISO 3166-1 code, its English name, or any of the other names people and services use for it
/// ("United States of America", "USA", "UK", "Czech Republic"). MusicBrainz gives a code, the weather place search gives a name, and a
/// person types whatever they like, so everything that compares countries goes through this.
enum CountryNames {
    /// Names other than the one `Locale` gives, by the form `ArtistMapNames.key` folds them to (lower case, no accents, no punctuation).
    private static let aliases: [String: String] = [
        "usa": "US", "u s": "US", "u s a": "US", "us": "US", "united states of america": "US", "america": "US",
        "uk": "GB", "u k": "GB", "great britain": "GB", "britain": "GB", "england": "GB", "scotland": "GB", "wales": "GB", "northern ireland": "GB",
        "czech republic": "CZ", "turkey": "TR", "russian federation": "RU", "south korea": "KR", "republic of korea": "KR", "korea republic of": "KR",
        "north korea": "KP", "ivory coast": "CI", "cote d ivoire": "CI", "burma": "MM", "cape verde": "CV", "swaziland": "SZ", "east timor": "TL",
        "macedonia": "MK", "north macedonia": "MK", "holland": "NL", "uae": "AE", "vatican": "VA", "vatican city": "VA", "palestine": "PS",
        "state of palestine": "PS", "kosovo": "XK", "democratic republic of the congo": "CD", "dr congo": "CD", "republic of the congo": "CG",
        "hong kong sar china": "HK", "macau": "MO", "taiwan province of china": "TW", "syrian arab republic": "SY", "viet nam": "VN",
    ]

    /// The two-letter codes that are countries (plus Kosovo's, which ISO has not assigned).
    private static let validCodes: Set<String> = Set(Locale.Region.isoRegions.map(\.identifier).filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }).union(["XK"])

    private static let index: [String: String] = {
        var byName: [String: String] = [:]
        let english = Locale(identifier: "en_US")
        for region in Locale.Region.isoRegions {
            let code = region.identifier
            guard code.count == 2, code.allSatisfy(\.isLetter), let name = english.localizedString(forRegionCode: code) else { continue }
            byName[ArtistMapNames.key(name)] = code
        }
        for (name, code) in aliases { byName[name] = code }
        return byName
    }()

    /// The ISO code for a code or a name in any of the usual spellings; nil when it isn't a country this knows.
    static func code(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count == 2, validCodes.contains(trimmed.uppercased()) { return trimmed.uppercased() }
        return index[ArtistMapNames.key(trimmed)]
    }

    /// The English name for an ISO code ("US" is "United States"); nil for a code that isn't a country.
    static func name(forCode code: String) -> String? {
        let upper = code.uppercased()
        guard validCodes.contains(upper) else { return nil }
        if upper == "XK" { return "Kosovo" }
        return Locale(identifier: "en_US").localizedString(forRegionCode: upper)
    }

    /// Names that read with "the" in front ("from the United Kingdom").
    private static let withThe: Set<String> = ["United States", "United Kingdom", "Netherlands", "Philippines", "Bahamas", "Gambia", "United Arab Emirates", "Czech Republic", "Dominican Republic", "Central African Republic", "Maldives", "Comoros", "Seychelles", "Marshall Islands", "Solomon Islands", "Cayman Islands", "Faroe Islands"]

    /// A country as it reads after "from": "the United Kingdom", "Canada".
    static func phrase(forCode code: String) -> String {
        let name = name(forCode: code) ?? code
        return withThe.contains(name) ? "the \(name)" : name
    }

    /// The flag for a country, drawn from its code: two regional-indicator letters ("US" is the American flag).
    static func flag(forCode code: String) -> String {
        let upper = code.uppercased()
        guard upper.count == 2, upper.allSatisfy(\.isLetter) else { return "" }
        return String(upper.unicodeScalars.compactMap { UnicodeScalar(0x1F1E6 + $0.value - 0x41) }.map(Character.init))
    }
}
