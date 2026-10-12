import Foundation
import SwiftData
import Observation

/// What Ask offers as its example sentence (the text field's prompt). Generated from templates — never by a model — so it
/// costs nothing, works with every engine and offline, and each suggestion is something Ask can be checked on: it carries the
/// reading it expects, which is validated against the registry, run on the person's own data to confirm it finds something,
/// and (per engine) scored against what the engine really returns. A suggestion that can't be vouched for isn't offered.
struct AskSuggestion: Sendable, Identifiable, Equatable {
    static func == (a: AskSuggestion, b: AskSuggestion) -> Bool { a.id == b.id }

    enum Category: String, Sendable, CaseIterable {
        case threshold, gap, ranking, spread, name, byArtist, tag, year, release, similar, library, discovery, daypart, cap
    }

    /// Template id + what filled it, e.g. "byArtist.unloved|Some Artist".
    let id: String
    let templateID: String
    let category: Category
    let personal: Bool
    let sentence: String
    let target: QueryTarget
    /// Acceptable readings of the sentence; the first is what the data check runs.
    let readings: [AskWire.Query]
    /// A "similar to X" suggestion carries what it should resolve to instead of readings.
    let similar: AskSimilarIntent?
    /// For a sentence whose numbers are a judgment call: right when the conditions use exactly one of these sets of fields.
    let fieldSets: [Set<String>]

    /// A suggestion must find at least this many rows to be shown (a similar one: its seed must exist).
    static let minimumRows = 3
}

// MARK: - Facts about the library

/// A few facts about the library, enough to fill templates with real names and years. Computed once in the background.
struct AskSuggestionFacts: Sendable {
    struct ArtistFact: Sendable { let name: String; let plays: Int }
    struct TrackFact: Sendable { let artist: String; let track: String; let plays: Int }

    var artists: [ArtistFact] = []
    var tracks: [TrackFact] = []
    var tags: [String] = []
    var discoveryYears: [Int] = []
    var playYears: [Int] = []
    /// Years (2, 3) for which at least a handful of loved tracks haven't been played that long.
    var idleLovedYears: [Int] = []
    var hasLibraryCheck = false

    static let empty = AskSuggestionFacts()

    nonisolated static func compute(
        scrobbles: [ScrobbleSnapshot], lovedKeys: Set<String>, tagCounts: [(tag: String, items: Int)], libraryChecked: Bool,
        now: Date = Date(), calendar: Calendar = AppCalendars.listening
    ) -> AskSuggestionFacts {
        var facts = AskSuggestionFacts()
        facts.hasLibraryCheck = libraryChecked
        let thisYear = calendar.component(.year, from: now)

        var artistPlays: [String: Int] = [:]
        var artistTracks: [String: Set<String>] = [:]
        var artistFirst: [String: Date] = [:]
        var trackPlays: [String: (artist: String, track: String, plays: Int)] = [:]
        var titleArtists: [String: Set<String>] = [:]
        var yearPlays: [Int: Int] = [:]
        var lastPlayed: [String: Date] = [:]
        for s in scrobbles where !s.artistName.isEmpty && !s.trackName.isEmpty {
            artistPlays[s.artistName, default: 0] += 1
            artistTracks[s.artistName, default: []].insert(s.trackName)
            if artistFirst[s.artistName].map({ s.playedAt < $0 }) ?? true { artistFirst[s.artistName] = s.playedAt }
            let key = "\(s.artistName)\u{0}\(s.trackName)"
            var entry = trackPlays[key] ?? (s.artistName, s.trackName, 0)
            entry.plays += 1
            trackPlays[key] = entry
            titleArtists[s.trackName.lowercased(), default: []].insert(s.artistName)
            yearPlays[calendar.component(.year, from: s.playedAt), default: 0] += 1
            let loved = TextNormalization.lovedKey(artist: s.artistName, track: s.trackName)
            if lovedKeys.contains(loved), lastPlayed[loved].map({ s.playedAt > $0 }) ?? true { lastPlayed[loved] = s.playedAt }
        }

        facts.artists = artistPlays
            .filter { $0.value >= 100 && (artistTracks[$0.key]?.count ?? 0) >= 8 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(15).map { ArtistFact(name: $0.key, plays: $0.value) }

        let artistNames = Set(artistPlays.keys.map { $0.lowercased() })
        facts.tracks = trackPlays.values
            .filter { entry in
                entry.plays >= 40 && (4...40).contains(entry.track.count)
                    && (titleArtists[entry.track.lowercased()]?.count ?? 0) == 1 && !artistNames.contains(entry.track.lowercased())
            }
            .sorted { $0.plays != $1.plays ? $0.plays > $1.plays : $0.track < $1.track }
            .prefix(20).map { TrackFact(artist: $0.artist, track: $0.track, plays: $0.plays) }

        facts.tags = tagCounts.filter { $0.items >= 30 && $0.tag.allSatisfy { $0.isLetter || $0 == " " } }.prefix(20).map(\.tag)

        var discovered: [Int: Int] = [:]
        for first in artistFirst.values { discovered[calendar.component(.year, from: first), default: 0] += 1 }
        facts.discoveryYears = discovered.filter { $0.value >= 8 && $0.key < thisYear }.keys.sorted()
        facts.playYears = yearPlays.filter { $0.value >= 1500 && $0.key < thisYear }.keys.sorted()

        for years in [2, 3] {
            let cutoff = calendar.date(byAdding: .year, value: -years, to: now) ?? now
            if lastPlayed.values.filter({ $0 < cutoff }).count >= 5 { facts.idleLovedYears.append(years) }
        }
        return facts
    }
}

// MARK: - Templates

enum AskSuggestionTemplates {
    // Authoring helpers (same shape as the evaluation set's).
    private static func c(_ field: String, _ op: String, _ value: Double? = nil, _ valueTo: Double? = nil, text: String? = nil,
                          date: String? = nil, dateTo: String? = nil, tags: [String]? = nil, scope: AskWire.Scope? = nil) -> AskWire.Condition {
        AskWire.Condition(field: field, op: op, value: value, valueTo: valueTo, text: text, date: date, dateTo: dateTo, tags: tags, scope: scope)
    }
    private static func q(_ groups: [[AskWire.Condition]], sorts: [AskWire.Sort] = [], limit: Int? = nil,
                          perArtist: Int? = nil, perAlbum: Int? = nil, perReleaseYear: Int? = nil) -> AskWire.Query {
        AskWire.Query(groups: groups, sorts: sorts, limit: limit, unsupported: [], perArtist: perArtist, perAlbum: perAlbum, perReleaseYear: perReleaseYear)
    }
    private static func plays(_ scope: AskWire.Scope? = nil) -> AskWire.Sort { AskWire.Sort(field: "plays", direction: "descending", scope: scope) }
    private static func year(_ y: Int) -> AskWire.Scope { AskWire.Scope(kind: "absolute", from: "\(y)-01-01", to: "\(y)-12-31") }

    private static func suggestion(
        _ templateID: String, _ category: AskSuggestion.Category, personal: Bool, fill: String = "", _ sentence: String, _ target: QueryTarget,
        readings: [AskWire.Query] = [], similar: AskSimilarIntent? = nil, fieldSets: [Set<String>] = []
    ) -> AskSuggestion {
        AskSuggestion(
            id: fill.isEmpty ? templateID : "\(templateID)|\(fill)", templateID: templateID, category: category, personal: personal,
            sentence: sentence, target: target, readings: readings, similar: similar, fieldSets: fieldSets
        )
    }

    /// Sentences that need nothing from the library.
    static func generic(now: Date = Date()) -> [AskSuggestion] {
        let thisYear = AppCalendars.listening.component(.year, from: now)
        // "This year" may end on 31 December or on today (the year so far): the same artists either way.
        let today = AppCalendars.listening.dateComponents([.year, .month, .day], from: now)
        let todayText = String(format: "%04d-%02d-%02d", today.year ?? thisYear, today.month ?? 1, today.day ?? 1)
        let yearScope = AskWire.Scope(kind: "calendar", unit: "year")
        return [
        // New this year: first ever played this year, most played first. A model may order by all plays or by this year's;
        // for an artist that is new this year they are the same.
        suggestion("discovery.newArtists", .discovery, personal: false, "Who are my top 5 new artists this year?", .artist,
                   readings: ["\(thisYear)-12-31", todayText].flatMap { end in
                       [plays(), plays(yearScope)].map { sort in
                           q([[c("firstPlayed", "dateBetween", date: "\(thisYear)-01-01", dateTo: end)]], sorts: [sort], limit: 5)
                       }
                   }),
        // Ask has no hour-of-day filter: "Sunday mornings" reads as the tracks whose most common day is Sunday and whose most
        // common time of day is the morning.
        suggestion("daypart.sundayMornings", .daypart, personal: false, "What are my 10 most played songs Sunday mornings?", .track,
                   readings: [q([[c("dayOfWeek", "textIs", text: "Sunday"), c("peakTimeOfDay", "textIs", text: "Morning")]], sorts: [plays()], limit: 10)]),
        suggestion("threshold.artistPlays", .threshold, personal: false, "artists I've played more than 100 times", .artist, readings: [q([[c("plays", "greaterThan", 100)]])]),
        suggestion("threshold.longTracks", .threshold, personal: false, "tracks longer than 6 minutes", .track, readings: [q([[c("duration", "greaterThan", 6)]])]),
        suggestion("threshold.playedOnce", .threshold, personal: false, "songs I've played exactly once", .track, readings: [q([[c("plays", "equals", 1)]])]),
        suggestion("gap.lovedYear", .gap, personal: false, "loved tracks I haven't played in a year", .track,
                   readings: [q([[c("loved", "isTrue"), c("daysSinceLastPlayed", "greaterThan", 365)]])]),
        suggestion("gap.artistsHalfYear", .gap, personal: false, "artists I haven't listened to in 6 months", .artist,
                   readings: [180, 182, 183].map { q([[c("daysSinceLastPlayed", "greaterThan", Double($0))]]) }),
        suggestion("ranking.albumsThisYear", .ranking, personal: false, "my top 10 albums this year", .album,
                   readings: [q([], sorts: [plays(AskWire.Scope(kind: "calendar", unit: "year"))], limit: 10)]),
        suggestion("spread.fewDays", .spread, personal: false, "albums I played a lot but only over a few days", .album,
                   fieldSets: [["plays", "activeDays"], ["plays", "playSpanDays"]]),
        // Diversity caps: at most N results that share an artist / an album / a release year.
        suggestion("cap.perArtist", .cap, personal: false, "my top 10 songs, 1 per artist", .track,
                   readings: [q([], sorts: [plays()], limit: 10, perArtist: 1)]),
        suggestion("cap.perReleaseYear", .cap, personal: false, "my most played album from each release year", .album,
                   readings: [q([], sorts: [plays()], perReleaseYear: 1)]),
        suggestion("name.love", .name, personal: false, "songs with love in the title", .track,
                   readings: [q([[c("name", "wholeWord", text: "love")]]), q([[c("name", "contains", text: "love")]])]),
        ]
    }

    /// Sentences filled with real names, years and counts. Several fills per template, so each opening can differ.
    static func personal(_ facts: AskSuggestionFacts, perTemplate: Int = 3, using rng: inout some RandomNumberGenerator) -> [AskSuggestion] {
        var out: [AskSuggestion] = []
        let artists = facts.artists.shuffled(using: &rng).prefix(perTemplate)
        for a in artists {
            let name = a.name
            out.append(suggestion("byArtist.unloved", .byArtist, personal: true, fill: name, "songs by \(name) I haven't loved", .track,
                                  readings: [q([[c("artist", "textIs", text: name), c("loved", "isFalse")]]), q([[c("artist", "contains", text: name), c("loved", "isFalse")]])]))
            out.append(suggestion("byArtist.mostPlayed", .byArtist, personal: true, fill: name, "my most played song by \(name)", .track,
                                  readings: [q([[c("artist", "textIs", text: name)]], sorts: [plays()], limit: 1), q([[c("artist", "textIs", text: name)]], sorts: [plays()])]))
            out.append(suggestion("cap.perAlbum", .cap, personal: true, fill: name, "the top song from each album by \(name)", .track,
                                  readings: [q([[c("artist", "textIs", text: name)]], sorts: [plays()], perAlbum: 1), q([[c("artist", "contains", text: name)]], sorts: [plays()], perAlbum: 1)]))
            out.append(suggestion("byArtist.albums", .byArtist, personal: true, fill: name, "albums by \(name)", .album,
                                  readings: [q([[c("artist", "textIs", text: name)]]), q([[c("artist", "contains", text: name)]])]))
            out.append(suggestion("similar.artist", .similar, personal: true, fill: name, "recommend some music like \(name)", .track,
                                  similar: AskSimilarIntent(seedText: name, kind: .artist, artistHint: nil, limit: AskSimilarIntent.defaultLimit)))
        }
        for t in facts.tracks.shuffled(using: &rng).prefix(perTemplate) {
            out.append(suggestion("similar.track", .similar, personal: true, fill: "\(t.artist)|\(t.track)", "find 25 songs similar to \"\(t.track)\"", .track,
                                  similar: AskSimilarIntent(seedText: t.track, kind: .track, artistHint: nil, limit: 25)))
        }
        for tag in facts.tags.shuffled(using: &rng).prefix(perTemplate) {
            out.append(suggestion("tag.unloved", .tag, personal: true, fill: tag, "songs tagged \(tag) that I haven't loved", .track,
                                  readings: [q([[c("tags", "tagsIsAny", tags: [tag]), c("loved", "isFalse")]]), q([[c("myTags", "tagsIsAny", tags: [tag]), c("loved", "isFalse")]])]))
            out.append(suggestion("tag.artists", .tag, personal: true, fill: tag, "artists tagged \(tag)", .artist,
                                  readings: [q([[c("tags", "tagsIsAny", tags: [tag])]]), q([[c("myTags", "tagsIsAny", tags: [tag])]])]))
        }
        for y in facts.discoveryYears.shuffled(using: &rng).prefix(perTemplate) {
            out.append(suggestion("year.discovered", .year, personal: true, fill: String(y), "artists I discovered in \(y)", .artist,
                                  readings: [q([[c("firstPlayed", "dateBetween", date: "\(y)-01-01", dateTo: "\(y)-12-31")]])]))
        }
        for y in facts.playYears.shuffled(using: &rng).prefix(perTemplate) {
            out.append(suggestion("year.topTracks", .year, personal: true, fill: String(y), "my 10 most played tracks in \(y)", .track,
                                  readings: [q([], sorts: [plays(year(y))], limit: 10)]))
        }
        for decade in [1980, 1990, 2000, 2010] {
            let label = decade < 2000 ? "\(decade % 100)s" : "\(decade)s"
            out.append(suggestion("release.decade", .release, personal: true, fill: String(decade), "albums released in the \(label)", .album,
                                  readings: [q([[c("releaseYear", "between", Double(decade), Double(decade + 9))]])]))
        }
        for years in facts.idleLovedYears {
            out.append(suggestion("gap.lovedYears", .gap, personal: true, fill: String(years), "loved tracks I haven't played in \(years) years", .track,
                                  readings: [q([[c("loved", "isTrue"), c("daysSinceLastPlayed", "greaterThan", Double(years * 365))]])]))
        }
        if facts.hasLibraryCheck {
            out.append(suggestion("library.missing", .library, personal: true, "tracks I've played more than 10 times that aren't in my Apple Music library", .track,
                                  readings: [q([[c("plays", "greaterThan", 10), c("inAppleLibrary", "isFalse")]])]))
        }
        return out
    }

    /// Every template filled for every available fact (the check harness uses this; the app picks from a random subset).
    static func everything(_ facts: AskSuggestionFacts) -> [AskSuggestion] {
        var rng = SystemRandomNumberGenerator()
        return generic() + personal(facts, perTemplate: 4, using: &rng)
    }
}

// MARK: - Which templates are vouched for, per engine

/// Templates whose sentences an engine was MEASURED to read as expected (the harness, `SCROBLYTICS_ASK_SUGGEST_CHECK`, on real
/// library fills). The on-device model is right about half the time on free requests, so it is only offered the shapes it was
/// seen to read correctly; the larger models are offered the shapes both reference models read correctly. Empty means nothing is
/// vouched for yet, and the plain default sentence is shown.
enum AskSuggestionVerification {
    /// Template ids verified on the Apple on-device model.
    ///
    /// Measured 2026-10-04 on 4 fills per template of this library (and 2026-10-07 for "daypart.sundayMornings", 3 runs, all correct;
    /// "discovery.newArtists" was misread by this model, as an artist-loved-ratio filter, in all 3 runs, so it is not listed): the on-device model read exactly these correctly every time and
    /// misread the rest (decades off by one, "discovered in" gaining invented filters, similar-to not understood, …).
    ///
    /// Measured 2026-10-10 (3 runs): "cap.perArtist" read correctly every time. "cap.perAlbum" (0 of 4, three runs) and
    /// "cap.perReleaseYear" (0 of 1) get the cap right but add an invented filter (a song or artist "named top", or release-year and
    /// discography filters), so they are not listed.
    static let onDevice: Set<String> = [
        "byArtist.albums", "byArtist.unloved", "cap.perArtist", "daypart.sundayMornings", "gap.artistsHalfYear", "ranking.albumsThisYear", "tag.artists",
        "tag.unloved", "threshold.artistPlays", "threshold.longTracks", "year.topTracks",
    ]
    /// Template ids verified on the larger models (Claude Sonnet 5.5 and OpenAI GPT-6 Luna both read them correctly).
    ///
    /// Measured the same way: Claude Sonnet 5.5 and GPT-6 Luna each read every one of these correctly on every fill. The two added
    /// 2026-10-07 ("daypart.sundayMornings", "discovery.newArtists"): Claude 3 of 3 runs and GPT-6 Luna 5 of 5 each, counting "this
    /// year" ending today as well as 31 December.
    ///
    /// The three "cap." templates (added 2026-10-10) are NOT measured on the two reference models: no key was used. Their cap is read by
    /// code from the sentence whatever the model writes (`AskPatterns.groupLimit(in:)`), and "cap.perAlbum" was confirmed by hand on
    /// OpenAI. Run the harness (`SCROBLYTICS_ASK_SUGGEST_CHECK`) on each model before relying on the others.
    static let models: Set<String> = [
        "byArtist.albums", "byArtist.mostPlayed", "byArtist.unloved", "cap.perAlbum", "cap.perArtist", "cap.perReleaseYear", "daypart.sundayMornings", "discovery.newArtists", "gap.artistsHalfYear",
        "library.missing", "name.love",
        "ranking.albumsThisYear", "release.decade", "similar.artist", "similar.track", "spread.fewDays", "tag.artists", "tag.unloved",
        "threshold.artistPlays", "threshold.longTracks", "threshold.playedOnce", "year.discovered", "year.topTracks",
    ]

    static func allows(_ templateID: String, engine: AskEngineID) -> Bool {
        engine == .onDevice ? onDevice.contains(templateID) : models.contains(templateID)
    }
}

// MARK: - The row check

/// Runs a suggestion's expected reading on the person's own data to confirm it finds something.
enum AskSuggestionCheck {
    static func rows(for suggestion: AskSuggestion, scrobbles: [ScrobbleSnapshot], snapshots: QuerySnapshots, registry: QueryFieldRegistry = .standard, now: Date = Date()) -> Int {
        if let similar = suggestion.similar {
            return AskSimilarResolver.resolve(similar, scrobbles: scrobbles) == nil ? 0 : AskSuggestion.minimumRows
        }
        var best = 0
        for reading in suggestion.readings {
            let interpreted = AskInterpreter.interpret(reading, target: suggestion.target, registry: registry, now: now, count: nil, ordered: reading.limit != nil && (reading.sorts ?? []).isEmpty)
            guard interpreted.dropped.isEmpty, let validated = try? interpreted.spec.validate(against: registry) else { continue }
            let run = QueryRun(target: suggestion.target, asOf: now, scrobbles: validated.spec.countedPlays(scrobbles), allTimeScrobbles: scrobbles, snapshots: snapshots)
            best = max(best, QueryEngine.evaluate(validated, run: run).rows.count)
            if best >= AskSuggestion.minimumRows { break }
        }
        // A fieldSets suggestion has no exact reading to run: the sentence is checked by the harness, not by rows.
        if suggestion.readings.isEmpty && !suggestion.fieldSets.isEmpty { return AskSuggestion.minimumRows }
        return best
    }
}

// MARK: - The store

/// Holds the library facts and picks the suggestion shown when Ask opens. Facts are refreshed in the background (after launch
/// and after a sync); picking never blocks — until a suggestion has been checked the box shows the plain default.
@MainActor
@Observable
final class AskSuggestionStore {
    static let defaultSentence = "tracks I loved but haven’t played in a year"

    /// What the Ask box shows right now; set when Ask opens and left alone while it stays open.
    private(set) var current: AskSuggestion?

    private var facts = AskSuggestionFacts.empty
    private var scrobbles: [ScrobbleSnapshot] = []
    private var snapshots = QuerySnapshots()
    private var rowCache: [String: Int] = [:]
    private var lastCategory: AskSuggestion.Category?
    private var refreshing = false
    /// The suggestions are worked out from the whole library (every scrobble, once per sync), which is a lot of work for a long
    /// history and is only needed when the Ask box opens. So the window only marks them out of date, and the first opening that
    /// needs them does the work. Until then, and for that first opening, the box shows the plain default sentence.
    private var isStale = true
    private var container: ModelContainer?

    private static let recentKey = "ask.suggestions.recent"

    /// Says the library has changed (or the app has just opened): the next opening of Ask recomputes the suggestions.
    func markStale(container: ModelContainer) {
        self.container = container
        isStale = true
    }

    func refresh(container: ModelContainer) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        isStale = false
        guard let canonical = try? await offMain({
            try await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)
        }) else { return }
        let loaded = await QuerySnapshotReader(modelContainer: container).loadAll()
        let tagCounts = loaded.entityTags.vocabulary
        let computed = await Task.detached(priority: .utility) {
            AskSuggestionFacts.compute(scrobbles: canonical, lovedKeys: loaded.lovedKeys, tagCounts: tagCounts, libraryChecked: loaded.libraryPresence.checkedAt != nil)
        }.value
        scrobbles = canonical
        snapshots = QuerySnapshots(
            durations: loaded.durations, releaseDates: loaded.releaseDates, turnover: loaded.turnover, lovedKeys: loaded.lovedKeys,
            flaggedKeys: loaded.flaggedKeys, entityTags: loaded.entityTags, libraryPresence: loaded.libraryPresence, images: loaded.images
        )
        facts = computed
        rowCache = [:]
    }

    /// Picks what to show for this opening: a different kind of suggestion than last time, not one shown recently, checked on the
    /// library's data, and vouched for on the engine in use. Falls back to the plain default.
    func chooseForOpening(engine: AskEngineID) async {
        if isStale, let container {
            // Not awaited: the box shows the default sentence now, and the personal suggestion from the next opening.
            Task { await refresh(container: container) }
        }
        let recent = Set(UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? [])
        var rng = SystemRandomNumberGenerator()
        var candidates = (AskSuggestionTemplates.generic() + AskSuggestionTemplates.personal(facts, using: &rng))
            .filter { AskSuggestionVerification.allows($0.templateID, engine: engine) && !recent.contains($0.id) }
        candidates.shuffle(using: &rng)
        // Mostly the person's own library when there is one, with a different kind of thing than the last pick.
        let wantPersonal = !facts.artists.isEmpty && Double.random(in: 0..<1, using: &rng) < 0.6
        let previous = lastCategory
        candidates.sort { a, b in
            func score(_ s: AskSuggestion) -> Int { (s.personal == wantPersonal ? 2 : 0) + (s.category != previous ? 1 : 0) }
            return score(a) > score(b)
        }
        let scrobbles = scrobbles, snapshots = snapshots
        for candidate in candidates.prefix(6) {
            let rows: Int
            if let cached = rowCache[candidate.id] { rows = cached } else {
                rows = await Task.detached(priority: .userInitiated) { AskSuggestionCheck.rows(for: candidate, scrobbles: scrobbles, snapshots: snapshots) }.value
                rowCache[candidate.id] = rows
            }
            guard rows >= AskSuggestion.minimumRows else { continue }
            current = candidate
            lastCategory = candidate.category
            UserDefaults.standard.set(Array(([candidate.id] + (UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? [])).prefix(8)), forKey: Self.recentKey)
            return
        }
        current = nil
    }

    /// For the check harness: every filled template, with its row count on this library.
    func allCandidates() -> [(suggestion: AskSuggestion, rows: Int)] {
        let scrobbles = scrobbles, snapshots = snapshots
        return AskSuggestionTemplates.everything(facts).map { ($0, AskSuggestionCheck.rows(for: $0, scrobbles: scrobbles, snapshots: snapshots)) }
    }
}
