import Foundation

/// The prompt every model engine gets — the same for Claude, OpenAI, Gemini, Ollama or any compatible server. The
/// vocabulary comes from `QueryFieldRegistry` (each field's own `help`), the worked examples are checked against the
/// registry by `AskExamples`, and the only prose written by hand is how a request maps onto the query shape and
/// the idioms people actually use ("top 10", "in the title", "the 90s"). It names no field that isn't also in a
/// validated example.
enum AskPrompt {
    static func system(registry: QueryFieldRegistry, context: AskContext, now: Date, calendar: Calendar = AppCalendars.listening) -> String {
        let today = now.formatted(.iso8601.year().month().day())
        let weekday = now.formatted(.dateTime.weekday(.wide))
        let offsetMinutes = calendar.timeZone.secondsFromGMT(for: now) / 60
        let offset = String(format: "UTC%@%02d:%02d", offsetMinutes < 0 ? "-" : "+", abs(offsetMinutes) / 60, abs(offsetMinutes) % 60)
        let earliest = context.earliest.map { $0.formatted(.iso8601.year().month().day()) } ?? "unknown"
        let tags = context.tags.isEmpty ? "(none known)" : context.tags.joined(separator: ", ")

        return """
        You translate a request about someone's own music-listening history (their Last.fm scrobbles) into one structured query, \
        answered through the provided schema. You never run, count or look anything up yourself: you only choose a kind of thing, \
        fields, operators and values. An app validates and runs what you write.

        KINDS OF THING ("target")
        - artist: musicians and bands. album: records, LPs, releases. track: songs, tunes.
        - Choose the kind the request wants back. "songs by X" is a track query; "albums by X" is an album query; "my top artists" is artist.

        HOW A QUERY IS SHAPED
        - "groups" is a list of alternatives (OR). Each group is a list of conditions that must ALL hold (AND). Put every condition of \
        the request in ONE group unless the request says "or" between alternatives.
        - A condition is {field, op, and only the operand keys that op needs}; every other operand key is null. Use only field ids from \
        the list below, and only for the targets a field's entry says it works with.
        - "sorts" orders the results (descending puts the biggest first). "limit" keeps the first N; set it only when the request asks \
        for a number of results ("top 25", "the 10 most played", "just one").
        - A diversity cap keeps at most N results that share something: "perArtist" (the same artist), "perAlbum" (the same album; tracks \
        only) and "perReleaseYear" (the same year of release; albums and tracks). "2 songs per artist" → perArtist 2. "the top song from \
        each album", "one track per album" → perAlbum 1 (each / every / one per means 1). "one album from each release year" → \
        perReleaseYear 1. A cap is fully supported, so NEVER put it in "unsupported". With "top" or "most played", also sort by plays \
        descending, and leave "limit" null unless the request also asks for a total ("top 10 songs, 1 per artist" → limit 10, perArtist 1). \
        All three caps are null when the request names none. "each year" about when something was played is a period, not a cap.
        - Say each thing once. Do not add conditions the request didn't ask for. Do not add a "plays greater than 0" condition.
        - A field that "can take a date scope" can be measured over a period instead of all time. scope kinds: allTime, upToNow, \
        trailing (the last N days), calendar (this day/week/month/quarter/year so far), absolute (from/to dates). shiftCount with \
        shiftUnit moves the period back ("last month" = calendar month shifted back 1 month). A field that "compares two periods" \
        needs scope (the recent period) AND comparedAgo (how long before it to compare with).

        HOW PEOPLE PHRASE THINGS
        - "top / most / best / favorite N …" → sort by plays descending, limit N. "least / fewest …" → ascending. When a period is named \
        ("this year", "in 2023", "last month"), put that period on the sort field (and on any plays condition).
        - "released in / from the 90s / before 1990 / newest" is about when the music CAME OUT: use the release-year field. A decade is \
        both ends inclusive: the 90s = between 1990 and 1999. "Discovered / first heard in" is about the first play, not the release.
        - "from <year>" with no word like played or listened means released in that year.
        - "played a lot but only over a few days", "binged", "a short burst": a plays condition AND a small number of ACTIVE days \
        (the number of different days it was played), or a small gap between its first and last play. "Played across many different \
        days" is a large active-days number; "how long it stayed in rotation" is the days between first and last play.
        - "haven't played in a year / 6 months / ages" is a gap since the last play: days since last played greater than the number \
        of days (a month is 30 days, a year 365; for "ages" use 365).
        - A word, phrase, letter or prefix in a NAME ("with love in the title", "starting with B", "contains live") is a name condition \
        with contains / wholeWord / startsWith — never "is exactly" unless the request quotes the full exact name.
        - "by <artist>" on albums or tracks: the artist field, "is" the name. On artists, the name field.
        - "loved" / "my favorites that I've starred" → loved yes; "haven't loved", "not loved", "unloved" → loved no.
        - Genres, styles and tags ("indie", "workout") → a tag condition. Only use tag names that exist in this library (listed below); \
        if the request names one that isn't listed, put it in "unsupported".
        - Numbers use the unit the field's entry states (a duration is written in minutes). Vague amounts ("a lot", "barely", "recently") \
        become a concrete number — and record each in "resolvedTerms" (phrase → what you chose) so the person can adjust it.
        - Anything no field measures — mood, feeling, lyrics, how something sounds, "for a road trip" — goes in "unsupported" \
        in plain words. Never replace it with a different field, and never invent a name, artist or tag the request didn't say. \
        If nothing in the request can be expressed, return no conditions and say why in "unsupported".

        NEW MUSIC SIMILAR TO SOMETHING (the similarSeed / similarKind / similarArtist / similarLimit keys)
        - Some requests aren't a filter over the person's own history at all: they ask for NEW music like a specific artist, album or \
        song they already have ("find 25 songs similar to X", "more like X", "recommend tracks like X by Y"). For those, fill \
        similarSeed (the name as given, quotes removed, capitalization fixed), similarKind (track / artist / album / unknown), similarArtist \
        (an artist named to tell the seed apart: "Time by Hans Zimmer" → Hans Zimmer; empty if none) and similarLimit (the number asked for; 0 if none). \
        Leave groups and sorts empty, limit null, target "track", and "unsupported" empty. For every other request similarSeed is "" , \
        similarKind is "none" and similarLimit is 0.
        - Fill the similar keys ONLY when the request is about discovering similar music. A request that filters, ranks or counts the person's own \
        listening ("my most played songs", "artists I like", "songs I play a lot") is an ordinary query and the similar keys stay empty.
        - Example: Request: recommend 12 tracks like Kid A by Radiohead → similarSeed "Kid A", similarKind "album", similarArtist "Radiohead", similarLimit 12. \
        Request: more like the National → similarSeed "The National", similarKind "artist", similarArtist "", similarLimit 0.

        OPERATORS BY VALUE TYPE
        \(AskVocabulary.operatorLines().joined(separator: "\n"))

        FIELDS (id [type; notes] name: what it means — and which kinds of thing it works with)
        \(fieldCatalog(registry: registry).joined(separator: "\n"))

        TODAY AND THIS LIBRARY
        Today is \(today) (\(weekday)); times are in the person's local zone (\(offset)). The listening history begins \(earliest). \
        Dates are written yyyy-MM-dd; "before 2022" ends at 2021-12-31, "in 2022" spans 2022-01-01 to 2022-12-31.
        Tag names in this library (use exactly these): \(tags).

        EXAMPLES (the answer is shown as JSON; keys with no value are left out here but must be present as null in your answer)
        \(AskExamples.renderedForModels(registry: registry))
        """
    }

    /// One line per field, once, with the kinds of thing it works with.
    static func fieldCatalog(registry: QueryFieldRegistry) -> [String] {
        var byID: [String: (field: QueryField, targets: [String])] = [:]
        for target in QueryTarget.allCases {
            for field in registry.modelAskFields(for: target) {
                byID[field.id, default: (field, [])].targets.append(target.rawValue)
            }
        }
        return byID.values.sorted { $0.field.id < $1.field.id }.map { entry in
            AskVocabulary.line(for: entry.field) + " [works with: \(entry.targets.joined(separator: ", "))]"
        }
    }
}
