import Foundation

/// Where artists are from: matching an artist to MusicBrainz, walking a city up to its state and country, and putting a person's own
/// corrections over what was looked up. Everything here is pure or takes its network as `OriginFetching`, so it is checked without a
/// network (`Verification/OriginChecks.swift`); the background sweep and the pages sit on top of it.

enum ArtistOriginStatus: String, Sendable {
    /// One clear artist matched.
    case found
    /// Several artists share the name and none led clearly; the best was used and the person is asked to check.
    case guess
    /// MusicBrainz has no such artist (a recorded miss, rechecked after a while).
    case none
}

enum ArtistOriginKind: String, Sendable {
    case person, group, other

    init(musicBrainzType: String?) {
        switch musicBrainzType {
        case "Person": self = .person
        case "Group", "Orchestra", "Choir": self = .group
        default: self = .other
        }
    }

    /// The tile's label: a person is born somewhere, a group formed somewhere.
    var label: String {
        switch self {
        case .person: "Born in"
        case .group: "Formed in"
        case .other: "From"
        }
    }
}

/// A place at three levels. Any of them can be missing (a country-only origin, a city with no state).
struct OriginPlace: Sendable, Equatable, Codable {
    var city: String?
    var region: String?
    var country: String?
    /// ISO 3166-1 alpha-2, upper case.
    var countryCode: String?

    var isEmpty: Bool { [city, region, country].allSatisfy { ($0 ?? "").isEmpty } }

    /// "Athens, Georgia, United States": the parts that exist, in order, without repeating a name (Singapore, Singapore).
    var text: String {
        var parts: [String] = []
        for part in [city, region, country] {
            guard let part = part?.trimmingCharacters(in: .whitespaces), !part.isEmpty, parts.last != part else { continue }
            parts.append(part)
        }
        return parts.joined(separator: ", ")
    }
}

/// The saved lookup for one artist, as plain values (a SwiftData row can't leave its context).
struct OriginEntrySnapshot: Sendable, Equatable {
    var status: ArtistOriginStatus
    var mbid: String?
    var matchedName: String?
    var kind: ArtistOriginKind?
    var place: OriginPlace
    var candidates: [ArtistOriginCandidate]
    var resolvedAt: Date
}

/// The person's decisions for one artist, as plain values.
struct OriginEditSnapshot: Sendable, Equatable {
    var place: OriginPlace?
    var chosenMBID: String?
    var confirmed: Bool
}

extension OriginEntrySnapshot {
    init(row: ArtistOriginEntry) {
        self.init(
            status: ArtistOriginStatus(rawValue: row.status) ?? .none,
            mbid: row.mbid, matchedName: row.matchedName, kind: row.kind.flatMap(ArtistOriginKind.init(rawValue:)),
            place: OriginPlace(city: row.cityName, region: row.regionName, country: row.countryName, countryCode: row.countryCode),
            candidates: row.candidatesJSON.flatMap { try? JSONDecoder().decode([ArtistOriginCandidate].self, from: $0) } ?? [],
            resolvedAt: row.resolvedAt
        )
    }
}

extension OriginEditSnapshot {
    init(row: ArtistOriginEdit) {
        self.init(
            place: row.hasPlaceOverride
                ? OriginPlace(city: row.overrideCity, region: row.overrideRegion, country: row.overrideCountry, countryCode: row.overrideCountryCode)
                : nil,
            chosenMBID: row.chosenMBID, confirmed: row.confirmed
        )
    }
}

/// What the app shows for one artist, whichever of the lookup and the person's edit it came from.
struct ArtistOriginDisplay: Sendable, Equatable {
    enum State: Sendable, Equatable {
        /// Not looked up yet (or being looked up).
        case pending
        /// Looked up and not found, and the person has not entered a place.
        case unknown
        case known
    }

    var state: State
    var place: OriginPlace
    var kind: ArtistOriginKind?
    /// The place is the person's own.
    var corrected: Bool
    /// A best guess nobody has confirmed.
    var needsReview: Bool

    /// "Born in", "Formed in" or "From".
    var label: String { (kind ?? .other).label }
    var text: String { place.text }
}

enum ArtistOriginMatcher {
    /// A candidate's search score must reach this to count (MusicBrainz scores an exact name 100).
    static let minimumScore = 90
    /// An artist this far ahead of the next one, or more, is taken as the one.
    static let clearLead = 10

    struct Choice: Sendable, Equatable {
        let status: ArtistOriginStatus
        let chosen: ArtistOriginCandidate?
        /// The other artists that matched the name, best first (only for a `guess`).
        let others: [ArtistOriginCandidate]
    }

    /// Picks the artist for a name. Only an artist whose name is the same name (case, accents, "The", "&" and punctuation ignored) and
    /// whose score is high enough counts; one candidate is the artist, several close ones make a best guess to be reviewed.
    static func choose(for artist: String, from candidates: [ArtistOriginCandidate]) -> Choice {
        let key = ArtistMapNames.key(artist)
        let matches = candidates
            .filter { $0.score >= minimumScore && ArtistMapNames.key($0.name) == key }
            .sorted { $0.score > $1.score }
        guard let best = matches.first else { return Choice(status: .none, chosen: nil, others: []) }
        let rest = Array(matches.dropFirst())
        if let next = rest.first, best.score - next.score < clearLead {
            return Choice(status: .guess, chosen: best, others: rest)
        }
        return Choice(status: .found, chosen: best, others: [])
    }
}

/// Where one artist's place comes from: the area it began in, then that area's parents up to the country.
enum OriginPlaceWalker {
    static let maxDepth = 8
    private static let cityTypes: Set<String> = ["City", "Municipality", "District", "Town"]

    /// Walks up from `start` through `area(id)` (cached or fetched by the caller). The city is the start when it is a city-like area, the
    /// region is the highest state, province or nation below the country (Georgia, England), and the country comes from its ISO code.
    static func place(from start: MBAreaInfo, area: @Sendable (String) async throws -> MBAreaInfo?) async throws -> OriginPlace {
        var chain = [start]
        var seen: Set<String> = [start.id]
        var current = start
        while chain.count < maxDepth, !isCountry(current), let parentID = current.parentID, seen.insert(parentID).inserted {
            guard let parent = try await area(parentID) else { break }
            chain.append(parent)
            current = parent
        }
        var place = OriginPlace()
        if let type = start.type, cityTypes.contains(type) { place.city = start.name }
        if let country = chain.first(where: isCountry) {
            place.countryCode = country.iso31661?.uppercased()
            place.country = place.countryCode.flatMap(countryName(forCode:)) ?? country.name
        }
        let below = chain.filter { !isCountry($0) && $0.type == "Subdivision" }
        place.region = below.last?.name
        return place
    }

    private static func isCountry(_ area: MBAreaInfo) -> Bool { area.type == "Country" || area.iso31661 != nil }

    /// "US" → "United States", in English, so the same country is always spelled the same way.
    static func countryName(forCode code: String) -> String? {
        Locale(identifier: "en_US").localizedString(forRegionCode: code)
    }
}

/// A saved area, so a parent shared by many artists is fetched once.
protocol OriginAreaProviding: Sendable {
    func cached(_ id: String) async -> MBAreaInfo?
    func save(_ area: MBAreaInfo) async
}

enum ArtistOriginLookup {
    struct Outcome: Sendable, Equatable {
        var status: ArtistOriginStatus
        var mbid: String?
        var matchedName: String?
        var kind: ArtistOriginKind?
        var place: OriginPlace
        var candidates: [ArtistOriginCandidate]
    }

    /// Looks one artist up. With a `chosenMBID` (the person picked it) that exact artist is used and no search is made. A network or
    /// HTTP failure throws, so nothing is recorded and the next try asks again; only "MusicBrainz has no such artist" is an answer.
    static func resolve(artist: String, chosenMBID: String?, fetcher: OriginFetching, areas: OriginAreaProviding) async throws -> Outcome {
        var status = ArtistOriginStatus.found
        var chosen: ArtistOriginCandidate?
        var others: [ArtistOriginCandidate] = []
        if let chosenMBID, let picked = try await fetcher.fetchArtist(id: chosenMBID) {
            chosen = picked
        } else {
            let choice = ArtistOriginMatcher.choose(for: artist, from: try await fetcher.searchArtists(name: artist))
            status = choice.status
            chosen = choice.chosen
            others = choice.others
        }
        guard let chosen else {
            return Outcome(status: .none, mbid: nil, matchedName: nil, kind: nil, place: OriginPlace(), candidates: [])
        }
        let place = try await place(for: chosen, fetcher: fetcher, areas: areas)
        return Outcome(
            status: status, mbid: chosen.id, matchedName: chosen.name, kind: ArtistOriginKind(musicBrainzType: chosen.type),
            place: place, candidates: status == .guess ? [chosen] + others : []
        )
    }

    /// The place for one artist: where it began, else the wider area it is listed in.
    static func place(for candidate: ArtistOriginCandidate, fetcher: OriginFetching, areas: OriginAreaProviding) async throws -> OriginPlace {
        guard let startID = candidate.beginAreaID ?? candidate.areaID else { return OriginPlace() }
        let load: @Sendable (String) async throws -> MBAreaInfo? = { id in
            if let saved = await areas.cached(id) { return saved }
            guard let fetched = try await fetcher.fetchArea(id: id) else { return nil }
            await areas.save(fetched)
            return fetched
        }
        guard let start = try await load(startID) else { return OriginPlace() }
        return try await OriginPlaceWalker.place(from: start, area: load)
    }
}

enum ArtistOriginResolver {
    /// A recorded miss is asked again after this long (MusicBrainz is edited all the time); a found place after a year.
    static let missRecheck: TimeInterval = 90 * 24 * 60 * 60
    static let foundRecheck: TimeInterval = 365 * 24 * 60 * 60

    /// What to show: the person's own place if they entered one, else the lookup, else "not looked up yet".
    static func display(entry: OriginEntrySnapshot?, edit: OriginEditSnapshot?) -> ArtistOriginDisplay {
        if let own = edit?.place, !own.isEmpty {
            return ArtistOriginDisplay(state: .known, place: own, kind: entry?.kind, corrected: true, needsReview: false)
        }
        guard let entry else { return ArtistOriginDisplay(state: .pending, place: OriginPlace(), kind: nil, corrected: false, needsReview: false) }
        switch entry.status {
        case .none:
            return ArtistOriginDisplay(state: .unknown, place: OriginPlace(), kind: nil, corrected: false, needsReview: false)
        case .found:
            return ArtistOriginDisplay(state: .known, place: entry.place, kind: entry.kind, corrected: false, needsReview: false)
        case .guess:
            return ArtistOriginDisplay(state: .known, place: entry.place, kind: entry.kind, corrected: false, needsReview: !(edit?.confirmed ?? false))
        }
    }

    /// Whether the sweep should ask again: nothing saved yet, the saved answer is old, or the person has since picked a different artist.
    static func needsLookup(entry: OriginEntrySnapshot?, edit: OriginEditSnapshot?, now: Date = Date()) -> Bool {
        guard let entry else { return true }
        if let chosen = edit?.chosenMBID, chosen != entry.mbid { return true }
        let age = now.timeIntervalSince(entry.resolvedAt)
        return age > (entry.status == .none ? missRecheck : foundRecheck)
    }
}
