import Foundation

/// Every country you have heard an artist from, over your whole history: when you first heard one from there, which artist it was, how
/// many artists and plays since, and how many countries you had reached by when.
struct CountryPassportResult: Sendable, Equatable {
    struct Stamp: Identifiable, Sendable, Equatable {
        let code: String
        let name: String
        /// The first play ever of any artist from this country, and that artist.
        let firstHeard: Date
        let firstArtist: String
        var artists: Int
        var plays: Int
        var id: String { code }
    }

    /// A count of countries you had reached, and the day you reached it (the day of the first play of the artist that made it so).
    struct Step: Identifiable, Sendable, Equatable {
        let count: Int
        let reachedAt: Date
        let country: String
        var id: Int { count }
    }

    /// Oldest first.
    let stamps: [Stamp]
    /// Every step of the ladder you have reached (see `ladder`), oldest first.
    let steps: [Step]
    /// Artists you have played whose origin is not known (not looked up yet, or unknown to MusicBrainz): more countries may follow.
    let unknownArtists: Int
    let knownArtists: Int

    static let ladder = [1, 5, 10, 15, 20, 25, 30, 40, 50, 75, 100]

    var countryCount: Int { stamps.count }
    /// The next step of the ladder not yet reached.
    var nextStep: Int? { Self.ladder.first { $0 > countryCount } }
}

enum CountryPassportEngine {
    /// `scrobbles` carry canonical artist names and are sorted by time; the whole history is used.
    static func compute(scrobbles: [ScrobbleSnapshot], origins: QueryOriginSnapshot) -> CountryPassportResult {
        struct Info { var first: Date; var plays: Int }
        var perArtist: [String: Info] = [:]
        var order: [String] = []
        for play in scrobbles {
            if perArtist[play.artistName] == nil {
                perArtist[play.artistName] = Info(first: play.playedAt, plays: 0)
                order.append(play.artistName)
            }
            perArtist[play.artistName]?.plays += 1
        }
        var stamps: [String: CountryPassportResult.Stamp] = [:]
        var known = 0, unknown = 0
        for artist in order {
            guard let info = perArtist[artist] else { continue }
            let display = origins.display(artist: artist)
            guard display.state == .known, let code = OriginHome.countryCode(of: display.place) else { unknown += 1; continue }
            known += 1
            if var stamp = stamps[code] {
                stamp.artists += 1
                stamp.plays += info.plays
                stamps[code] = stamp
            } else {
                stamps[code] = CountryPassportResult.Stamp(
                    code: code, name: CountryNames.name(forCode: code) ?? code, firstHeard: info.first, firstArtist: artist, artists: 1, plays: info.plays
                )
            }
        }
        // `order` is by first play, so the first artist met from a country is the one that opened it.
        let sorted = stamps.values.sorted { ($0.firstHeard, $0.name) < ($1.firstHeard, $1.name) }
        var steps: [CountryPassportResult.Step] = []
        for threshold in CountryPassportResult.ladder where threshold <= sorted.count {
            let stamp = sorted[threshold - 1]
            steps.append(CountryPassportResult.Step(count: threshold, reachedAt: stamp.firstHeard, country: stamp.name))
        }
        return CountryPassportResult(stamps: sorted, steps: steps, unknownArtists: unknown, knownArtists: known)
    }
}
