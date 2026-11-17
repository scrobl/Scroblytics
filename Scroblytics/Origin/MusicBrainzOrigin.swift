import Foundation

/// One shared pace for every MusicBrainz request in the app. MusicBrainz allows about one request a second per address and answers 503
/// when it is asked faster; the release-date lookups and the artist origin lookups both use it, so neither can push the other over.
/// Each request waits until the previous one's own "gap" has passed; after a 503 the whole app slows down for a couple of minutes.
struct MusicBrainzPacer: Sendable {
    /// Seconds the next request must wait after a throttling answer, and how long the slower pace lasts.
    static let throttledPause = 10.0
    static let throttledWindow = 120.0
    static let throttledMinimum = 4.0

    private var nextAllowed = 0.0
    private var slowUntil = 0.0

    /// Reserves the next slot and returns how many seconds to wait before using it. `minimum` is the gap this caller wants kept after
    /// its own request; a slower pace after a 503 overrides it.
    mutating func reserve(now: Double, minimum: Double) -> Double {
        let gap = now < slowUntil ? max(minimum, Self.throttledMinimum) : minimum
        let slot = max(now, nextAllowed)
        nextAllowed = slot + gap
        return slot - now
    }

    mutating func noteThrottled(now: Double) {
        nextAllowed = max(nextAllowed, now + Self.throttledPause)
        slowUntil = max(slowUntil, now + Self.throttledWindow)
    }
}

actor MusicBrainzGate {
    static let shared = MusicBrainzGate()
    private var pacer = MusicBrainzPacer()
    private let clock = ContinuousClock()
    private let origin = ContinuousClock.now

    private func now() -> Double {
        let elapsed = origin.duration(to: clock.now)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    /// Waits for this request's turn. Cancelling the task ends the wait early.
    func wait(minimum: Double) async {
        let delay = pacer.reserve(now: now(), minimum: minimum)
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
    }

    func noteThrottled() { pacer.noteThrottled(now: now()) }
}

// MARK: - What MusicBrainz knows about an artist and a place

/// One artist MusicBrainz offered for a name, with where it says the artist is from. `beginAreaID` is where a person was born or a group
/// formed; `areaID` is the wider area. Kept as JSON on a `guess` so the person can pick another one.
struct ArtistOriginCandidate: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let score: Int
    let type: String?
    let disambiguation: String?
    let areaID: String?
    let areaName: String?
    let beginAreaID: String?
    let beginAreaName: String?
}

/// One area (a city, county, state, country…) and the area it is part of.
struct MBAreaInfo: Sendable, Equatable {
    let id: String
    let name: String
    let type: String?
    let iso31661: String?
    let iso31662: String?
    let parentID: String?
}

/// What the origin lookups need from MusicBrainz, so the logic can be checked against a stand-in with no network.
protocol OriginFetching: Sendable {
    func searchArtists(name: String) async throws -> [ArtistOriginCandidate]
    func fetchArtist(id: String) async throws -> ArtistOriginCandidate?
    func fetchArea(id: String) async throws -> MBAreaInfo?
}

enum MusicBrainzOriginParsing {
    private struct AreaRef: Decodable { let id: String?; let name: String? }
    private struct ArtistItem: Decodable {
        let id: String
        let name: String
        let score: Int?
        let type: String?
        let disambiguation: String?
        let area: AreaRef?
        let beginArea: AreaRef?
        enum CodingKeys: String, CodingKey { case id, name, score, type, disambiguation, area; case beginArea = "begin-area" }

        var candidate: ArtistOriginCandidate {
            ArtistOriginCandidate(
                id: id, name: name, score: score ?? 100, type: type, disambiguation: disambiguation.flatMap { $0.isEmpty ? nil : $0 },
                areaID: area?.id, areaName: area?.name, beginAreaID: beginArea?.id, beginAreaName: beginArea?.name
            )
        }
    }
    private struct SearchResponse: Decodable { let artists: [ArtistItem]? }
    private struct Relation: Decodable {
        let type: String?
        let direction: String?
        let area: AreaRef?
    }
    private struct AreaItem: Decodable {
        let id: String
        let name: String
        let type: String?
        let iso31661: [String]?
        let iso31662: [String]?
        let relations: [Relation]?
        enum CodingKeys: String, CodingKey {
            case id, name, type, relations
            case iso31661 = "iso-3166-1-codes"
            case iso31662 = "iso-3166-2-codes"
        }
    }

    static func parseArtistSearch(_ data: Data) throws -> [ArtistOriginCandidate] {
        do { return try JSONDecoder().decode(SearchResponse.self, from: data).artists?.map(\.candidate) ?? [] } catch { throw MusicBrainzAPIError.invalidResponse }
    }

    static func parseArtist(_ data: Data) throws -> ArtistOriginCandidate {
        do { return try JSONDecoder().decode(ArtistItem.self, from: data).candidate } catch { throw MusicBrainzAPIError.invalidResponse }
    }

    /// An area and the area it is "part of" (the relation that points backward). An area can list the areas inside it too; those are ignored.
    static func parseArea(_ data: Data) throws -> MBAreaInfo {
        let item: AreaItem
        do { item = try JSONDecoder().decode(AreaItem.self, from: data) } catch { throw MusicBrainzAPIError.invalidResponse }
        let parent = item.relations?.first { $0.type == "part of" && $0.direction == "backward" }?.area?.id
        return MBAreaInfo(
            id: item.id, name: item.name, type: item.type,
            iso31661: item.iso31661?.first, iso31662: item.iso31662?.first, parentID: parent
        )
    }
}

extension MusicBrainzAPIClient: OriginFetching {
    /// Artists MusicBrainz offers for a name, best first. Network and HTTP failures throw (never "nothing found").
    func searchArtists(name: String) async throws -> [ArtistOriginCandidate] {
        var components = URLComponents(url: baseURL.appendingPathComponent("artist/"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "query", value: "artist:\"\(Self.escapeLucene(name))\""),
            .init(name: "fmt", value: "json"),
            .init(name: "limit", value: "5"),
        ]
        return try MusicBrainzOriginParsing.parseArtistSearch(try await get(components.url!))
    }

    /// One artist by its MusicBrainz id (the one a person picked). `nil` when MusicBrainz no longer has it.
    func fetchArtist(id: String) async throws -> ArtistOriginCandidate? {
        guard Self.isMBID(id) else { return nil }
        var components = URLComponents(url: baseURL.appendingPathComponent("artist/\(id)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "fmt", value: "json")]
        do { return try MusicBrainzOriginParsing.parseArtist(try await get(components.url!)) } catch MusicBrainzAPIError.http(404) { return nil }
    }

    /// An area and the area it is part of. `nil` when MusicBrainz no longer has it.
    func fetchArea(id: String) async throws -> MBAreaInfo? {
        guard Self.isMBID(id) else { return nil }
        var components = URLComponents(url: baseURL.appendingPathComponent("area/\(id)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "fmt", value: "json"), .init(name: "inc", value: "area-rels")]
        do { return try MusicBrainzOriginParsing.parseArea(try await get(components.url!)) } catch MusicBrainzAPIError.http(404) { return nil }
    }

    /// An id from MusicBrainz is a UUID; anything else is never put in a URL.
    static func isMBID(_ value: String) -> Bool { UUID(uuidString: value) != nil }

    static func escapeLucene(_ value: String) -> String {
        var result = ""
        for ch in value {
            if ch == "\\" || ch == "\"" { result.append("\\") }
            result.append(ch)
        }
        return result
    }

    /// One paced, identified, connectivity-gated GET. Offline mode throws before anything is sent.
    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        try ConnectivityGate.check(host: url.host)
        await MusicBrainzGate.shared.wait(minimum: ArtistOriginPacing.gap)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
            ConnectivityHub.reportSuccess()
        } catch {
            ConnectivityHub.report(error, host: url.host, source: "MusicBrainz")
            throw MusicBrainzAPIError.network(error)
        }
        guard let http = response as? HTTPURLResponse else { throw MusicBrainzAPIError.invalidResponse }
        if http.statusCode == 503 || http.statusCode == 429 { await MusicBrainzGate.shared.noteThrottled() }
        guard (200..<300).contains(http.statusCode) else { throw MusicBrainzAPIError.http(http.statusCode) }
        return data
    }
}

enum ArtistOriginPacing {
    /// Seconds kept between origin requests. 1.1 s drew 503s in a trial; 2.5 s did not.
    static let gap = 2.5
}
