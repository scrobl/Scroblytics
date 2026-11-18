import Foundation

/// Which tracks a goal is about: all of your loved tracks (the default), or loved / not loved / any track you've played, narrowed to some
/// artists, some tags and / or some countries (where the artist is from). Every part that is set must match.
struct GoalCriteria: Codable, Equatable, Sendable {
    enum LovedStatus: String, Codable, CaseIterable, Identifiable, Sendable {
        case loved, notLoved, any

        var id: String { rawValue }
        var label: String {
            switch self {
            case .loved: "Loved"
            case .notLoved: "Not loved"
            case .any: "All tracks"
            }
        }
    }

    var loved: LovedStatus = .loved
    /// Artist names; a track matches when it is by any of them.
    var artists: [String] = []
    /// Tags (lowercased); a track matches when it has any of them.
    var tags: [String] = []
    /// Country names (English, as the person chose them; compared by country code); a track matches when its artist is from any of them,
    /// by where Artist origin says the artist is from.
    var countries: [String] = []

    init(loved: LovedStatus = .loved, artists: [String] = [], tags: [String] = [], countries: [String] = []) {
        self.loved = loved
        self.artists = artists
        self.tags = tags
        self.countries = countries
    }

    private enum CodingKeys: String, CodingKey { case loved, artists, tags, countries }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        loved = (try? c.decodeIfPresent(LovedStatus.self, forKey: .loved)) ?? .loved
        artists = try c.decodeIfPresent([String].self, forKey: .artists) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        countries = try c.decodeIfPresent([String].self, forKey: .countries) ?? []
    }

    /// Every loved track, nothing narrowed: what a goal was before criteria existed.
    var isLovedOnly: Bool { loved == .loved && artists.isEmpty && tags.isEmpty && countries.isEmpty }

    /// A goal that isn't about loved tracks is about the tracks in your history, and a track joins it the day you first play it.
    var usesHistory: Bool { loved != .loved }

    /// What the goal's tracks are called on the page.
    var noun: String {
        switch loved {
        case .loved: "loved tracks"
        case .notLoved: "tracks you haven't loved"
        case .any: "tracks"
        }
    }

    private static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }

    /// "Loved tracks by A and B tagged shoegaze".
    var summary: String {
        var text = noun.prefix(1).uppercased() + noun.dropFirst()
        if !artists.isEmpty { text += " by \(Self.list(artists))" }
        if !tags.isEmpty { text += " tagged \(Self.list(tags))" }
        if !countries.isEmpty { text += " from \(Self.list(countries))" }
        return text
    }

    var suggestedTitle: String {
        var text = "Hear all my \(noun)"
        if !artists.isEmpty { text += " by \(Self.list(artists))" }
        if !tags.isEmpty { text += " tagged \(Self.list(tags))" }
        if !countries.isEmpty { text += " from \(Self.list(countries))" }
        return text
    }
}

/// A track in the listening history: what a goal about played tracks is made of.
struct GoalHistoryTrack: Sendable, Equatable {
    let key: String
    let artist: String
    let track: String
    /// The album of its newest play that had one (personal tags can sit on the album).
    var album: String?
    let firstPlayed: Date
}

/// The tracks a goal counts, and what had to be said about how they were found.
struct GoalMembers: Sendable {
    var loves: [GoalLove]
    /// The tracks come from the play history, so each joins the goal the day it was first played and is never owed: `lovedAt` holds
    /// that first play. False for loved tracks, which join on the day they were loved.
    var joinsOnPlay = false
    /// Tracks that would have been counted but have no tags looked up yet (not even their artist's), so a tag test can't say.
    var pendingTags = 0
    /// Tracks that would have been counted but whose artist has not been looked up for where they are from yet, so a country test can't say.
    var pendingOrigins = 0
}

enum GoalMembership {
    /// One entry per distinct track in the history, with its first play. `plays` must be oldest first.
    static func historyTracks(plays: [ScrobbleSnapshot]) -> [GoalHistoryTrack] {
        var index: [String: Int] = [:]
        var tracks: [GoalHistoryTrack] = []
        for play in plays {
            let key = TextNormalization.lovedKey(artist: play.artistName, track: play.trackName)
            if let i = index[key] {
                if !play.albumName.isEmpty { tracks[i].album = play.albumName }
            } else {
                index[key] = tracks.count
                tracks.append(GoalHistoryTrack(
                    key: key, artist: play.artistName, track: play.trackName, album: play.albumName.isEmpty ? nil : play.albumName,
                    firstPlayed: play.playedAt
                ))
            }
        }
        return tracks
    }

    /// The tracks each goal counts; the play history is gone through once however many goals need it.
    static func members(
        for goals: [ListeningGoal], loved: [GoalLove], plays: [ScrobbleSnapshot], tags: EntityTagsSnapshot, origins: QueryOriginSnapshot = .empty
    ) -> [UUID: GoalMembers] {
        let history = goals.contains { $0.criteria.usesHistory } ? historyTracks(plays: plays) : []
        return Dictionary(uniqueKeysWithValues: goals.map { ($0.id, members(goal: $0, loved: loved, history: history, tags: tags, origins: origins)) })
    }

    /// The tracks a goal counts. `loved` is the loved list (with love dates), `history` the played tracks, `tags` what is known of tags.
    static func members(
        goal: ListeningGoal, loved: [GoalLove], history: [GoalHistoryTrack], tags: EntityTagsSnapshot, origins: QueryOriginSnapshot = .empty
    ) -> GoalMembers {
        let criteria = goal.criteria
        let artistKeys = Set(criteria.artists.map(TextNormalization.artistIdentityKey))
        let wanted = Set(LastfmTagNormalization.normalizeList(criteria.tags))
        let wantedCountries = Set(criteria.countries.compactMap { CountryNames.code(for: $0) })
        var pending = 0
        var pendingOrigins = 0

        func artistMatches(_ artist: String) -> Bool {
            artistKeys.isEmpty || artistKeys.contains(TextNormalization.artistIdentityKey(artist))
        }
        /// nil = can't tell yet (the artist hasn't been looked up). An artist MusicBrainz doesn't know, or whose place has no country, is not
        /// from any country; with looking up switched off nothing is waited for.
        func countryMatches(_ artist: String) -> Bool? {
            guard !criteria.countries.isEmpty else { return true }
            let display = origins.display(artist: artist)
            switch display.state {
            case .pending: return origins.lookupsOn ? nil : false
            case .unknown: return false
            case .known: return OriginHome.countryCode(of: display.place).map(wantedCountries.contains) ?? false
            }
        }
        /// nil = can't tell yet.
        func tagMatches(artist: String, track: String, album: String?) -> Bool? {
            guard !wanted.isEmpty else { return true }
            let own = tags.entityCommunity[EntityTagKey.make(kind: .track, artist: artist, name: track)]
            // A track's own community tags when it has any, else its artist's (the rule the Tags field in Query uses).
            guard let community = (own?.isEmpty == false ? own : tags.tags(forArtist: artist)) else { return nil }
            let personal = tags.personalTags(kind: .track, artist: artist, name: track, album: album) ?? []
            return !Set(LastfmTagNormalization.normalizeList(community + personal)).isDisjoint(with: wanted)
        }

        switch criteria.loved {
        case .loved:
            let kept = loved.filter { love in
                guard artistMatches(love.artist) else { return false }
                switch countryMatches(love.artist) {
                case true?: break
                case false?: return false
                case nil: pendingOrigins += 1; return false
                }
                switch tagMatches(artist: love.artist, track: love.track, album: nil) {
                case true?: return true
                case false?: return false
                case nil: pending += 1; return false
                }
            }
            return GoalMembers(loves: kept, joinsOnPlay: false, pendingTags: pending, pendingOrigins: pendingOrigins)
        case .notLoved, .any:
            let lovedKeys = criteria.loved == .notLoved ? Set(loved.map(\.key)) : []
            var kept: [GoalLove] = []
            for track in history {
                if criteria.loved == .notLoved, lovedKeys.contains(track.key) { continue }
                guard artistMatches(track.artist) else { continue }
                switch countryMatches(track.artist) {
                case true?: break
                case false?: continue
                case nil: pendingOrigins += 1; continue
                }
                switch tagMatches(artist: track.artist, track: track.track, album: track.album) {
                case true?: kept.append(GoalLove(key: track.key, artist: track.artist, track: track.track, lovedAt: track.firstPlayed))
                case false?: break
                case nil: pending += 1
                }
            }
            return GoalMembers(loves: kept, joinsOnPlay: true, pendingTags: pending, pendingOrigins: pendingOrigins)
        }
    }
}
