import Foundation

/// Hand-written definitions for every Query field, keyed by field id. The Field reference articles show these next to
/// the registry's own facts (what it applies to, type, settings). `HelpChecks` fails if a registry field has no entry
/// here, or an entry has no field, so this cannot drift from the registry.
///
/// Words used consistently: **period** is the query's own date range; a **date scope** is a range one column carries
/// for itself; **now** is the query's “as of” moment (normally when it runs); **no value** is a missing cell (see
/// [Missing and pending](help://concepts-missing-pending)).
enum HelpFieldDefinitions {
    static func definition(for id: String) -> String? { text[id] }

    static let text: [String: String] = identity.merging(volume) { a, _ in a }
        .merging(ranking) { a, _ in a }
        .merging(engagement) { a, _ in a }
        .merging(recency) { a, _ in a }
        .merging(sentiment) { a, _ in a }
        .merging(flags) { a, _ in a }
        .merging(dates) { a, _ in a }
        .merging(context) { a, _ in a }
        .merging(duration) { a, _ in a }
        .merging(tempo) { a, _ in a }
        .merging(album) { a, _ in a }
        .merging(similar) { a, _ in a }
        .merging(tagFields) { a, _ in a }

    // MARK: Name

    private static let identity: [String: String] = [
        "name": "The artist, album or track name. Artists appear in one canonical spelling: when your history spells an artist several ways (capitalization), the plays are combined and the most-played spelling is shown. Albums and tracks are identified by artist plus title exactly as scrobbled, so “Album” and “Album (Deluxe)” are separate rows in Query. Text matching ignores case, accents and width.",
        "artist": "The artist credited on an album or track, in the canonical spelling. A collaboration credit such as “A & B” is a different artist from “A”.",
    ]

    // MARK: Volume

    private static let volume: [String: String] = [
        "plays": "Number of scrobbles in the query’s period (all of your history when no period is set). A column with its own date scope counts only plays in that range, and ignores the period. 0 when there are none.",
        "allTimePlays": "Every scrobble of the item in your whole history, whatever the period. Use it next to **Plays** to compare “this period” with “ever”.",
        "playsInLast": "Scrobbles in the N days up to now (plays later than now minus N × 24 hours, with no upper limit). N is a setting. If the query also has a period, only plays inside the period are counted.",
        "activeDays": "Number of different local calendar days on which it was played, in the period (or the column’s date scope). Thirty plays in one evening is 1; one play a week for thirty weeks is 30. No value if it had no plays there.",
        "activeWeeks": "Number of different weeks (starting on your week-start day, Monday by default) in which it was played, in the period (or date scope). No value if it had no plays there.",
        "activeMonths": "Number of different calendar months in which it was played, in the period (or date scope). No value if it had no plays there.",
        "nextMilestone": "The next play-count milestone above its plays in the period: 100, 250, 500, 1,000, 2,500, 5,000, 10,000, 25,000, 50,000, 100,000, then every 100,000. A count exactly on a milestone has already reached it, so the next one is the following threshold. Counts restart inside a period or date scope. See [Milestones](help://metrics-milestones).",
        "toNextMilestone": "Plays still needed to reach **Next milestone** (next milestone minus plays).",
        "milestoneEta": "Estimated days until the next milestone at the pace of the last 30 days: remaining plays × 30 ÷ plays in the last 30 days, rounded up. No value if it wasn’t played in the last 30 days.",
        "milestonesReached": "How many play-count milestones it has passed.",
        "lastMilestone": "The highest milestone it has passed. No value below 100 plays.",
        "lastMilestoneDate": "The date of the play that crossed **Last milestone reached**. No value below 100 plays.",
    ]

    // MARK: Rank & momentum

    private static let ranking: [String: String] = [
        "playRank": "Position by plays among everything with plays in the period (or date scope), where 1 is the most played. It ranks the whole library, not just the rows shown. Ties are broken by artist, then by title, so every rank is unique — the same order Top Charts uses. Set **Ties** to “shared” to give equal plays the same rank (1, 2, 2, 4). No value if it had no plays there.",
        "playsChange": "Plays in the period minus plays in the comparison period. Needs a date scope and a baseline. 0 plays count as 0.",
        "playsChangePercent": "(Plays now − plays before) ÷ plays before × 100, rounded to a whole number. No value when the comparison period had no plays, since there is nothing to take a percent of. Type the number as a percent: 50 means +50%.",
        "rankMovement": "Places gained (positive) or lost (negative): rank in the baseline period minus rank in the period. Same ranking rules as **Play rank**. No value unless it is ranked in both periods.",
        "artistPlayRank": "Rank of the item’s artist among all your artists by plays in the period (or date scope), 1 being the most played. “Artist’s play rank ≤ 25” keeps items by your top 25 artists.",
        "rankWindowAgo": "Its all-time play rank as of N days ago, using only plays up to that moment. No value if it had no plays by then. N is a setting. With a date scope the ranks are computed as of the scope’s end.",
        "rankChange": "Its all-time rank N days ago minus its all-time rank now. Positive means climbing. No value if it had no earlier plays. See [The Climb](help://metrics-climb).",
        "climbScore": "What The Climb orders by. For a track that had a rank before the window, the places it gained; for a track with no earlier plays, how far up the library it debuted (the number of tracks that had plays before, plus one, minus its current rank). Negative if it fell.",
        "hotShotDebut": "Yes when the track had no plays on or before the start of the window and now ranks in the top quarter of all tracks (rank no worse than 25% of the tracks that exist). This is a stricter test than the “Hot Shot Debut” label in Top Charts — see [Hot Shot Debut](help://metrics-hot-shot).",
    ]

    // MARK: Engagement pattern

    private static let engagement: [String: String] = [
        "turnoverCycles": "How many times you have listened all the way through the album: a cycle completes when every track on the album’s tracklist has been played at least once since the last completion. Needs the tracklist to be looked up first. Albums with fewer than two tracks have no value. See [Album Turnover](help://metrics-turnover).",
        "turnoverRate": "The median number of days a completed cycle took, from its first qualifying play to the play that completed it. No value if you haven’t completed one.",
        "turnoverLast": "The date of the play that completed the most recent cycle. No value if none.",
        "turnoverHeard": "How many of the album’s tracks you have heard since the last completed cycle.",
        "turnoverToGo": "Tracks still unheard before the current cycle completes (tracklist size minus tracks heard). This is the “N tracks to go” on the Overview card.",
        "turnoverTracks": "The tracklist size turnover is measured against: the matched real tracklist if there is one, otherwise the distinct tracks you have played.",
    ]

    // MARK: Recency

    private static let recency: [String: String] = [
        "playSpanDays": "Calendar days between the first and last play in the period (or date scope), counted start of day to start of day. 0 if every play was on one day. A track first heard in January and again in November is about 300. No value if it had no plays there.",
        "daysSinceLastPlayed": "Whole days (rounded down) between its latest play in the period (or date scope) and now. No value if it had no plays there. Use this for “haven’t played in a year”.",
        "daysSinceFirstPlayed": "Whole days (rounded down) between its earliest play in the period (or date scope) and now. A play later than “as of” makes it negative. No value if it had no plays there.",
    ]

    // MARK: Sentiment

    private static let sentiment: [String: String] = [
        "fadingPeak": "The most plays the track had in any stretch shorter than the window — how big a favorite it once was. The window is a setting. With a date scope it is computed as of the scope’s end, ignoring later plays. See [Fading Favorites](help://metrics-fading).",
        "fadingPeakStart": "The first play inside the peak stretch.",
        "fadingPeakEnd": "The last play inside the peak stretch.",
        "fadingRecent": "Plays in the window ending now (the trailing N days).",
        "fadingDecay": "Recent plays ÷ peak plays. 0 means gone silent; 1 means still at its peak. Shown as a percentage, but you type it as a fraction: 0.25 means 25%.",
        "rediscoveryScore": "Peak plays × (1 − fade ratio), shown to one decimal. A big past favorite that has gone quiet scores highest.",
        "artistLovedRatio": "Loved distinct tracks ÷ distinct tracks by the artist, over your whole scrobble library (not the period). Shown as a percentage, typed as a fraction (0.5 is 50%). No value if the artist has no tracks.",
        "albumLovedRatio": "The same ratio for one album: loved distinct tracks ÷ distinct tracks on it. Typed as a fraction.",
    ]

    // MARK: Flags

    private static let flags: [String: String] = [
        "loved": "Yes if the track is on your Last.fm loved list, as of the last sync (or your last love/unlove in the app). It matches by artist and title regardless of album. A track not on the list is simply “no”, never unknown.",
        "popular": "Yes if the item is in the top quarter of your library by combined popularity — the same test as the teal diamond. Waits (pending) until the item’s popularity has been looked up. See [Popularity](help://metrics-popularity).",
        "popularForArtist": "Yes if the album or track is in the top quarter of the same artist’s own albums or tracks (the orange diamond). Needs at least four scored items by that artist, otherwise no value.",
        "popularityScore": "Combined popularity: the average of the item’s percentile rank on each available signal (Last.fm listeners and plays, Deezer fans or rank), compared with the rest of your library. 1 is the top. Shown as a percentage, typed as a fraction (0.75 is 75%). No value if no signal was found; pending until looked up.",
        "inAppleLibrary": "Result of the last “Check library” in Library Gaps. Yes if the track is in your Music library — a near match under a different spelling counts. No if it is confirmed absent. No value if never checked.",
        "removedFromAppleLibrary": "The date the track was last seen in your Music library, for tracks that were there at an earlier check and are now gone with no near match. No value otherwise.",
        "flagged": "Yes if the track is in your Flagged Tracks list. Matches by artist and title regardless of album.",
        "missingImage": "Yes when no artwork resolves for it: no custom or downloaded image, nothing inherited from its album, and no usable art on its scrobbles (Last.fm’s grey placeholder doesn’t count). Artists never fall back to scrobble art. Reflects the last time artwork was refreshed.",
        "customImage": "Yes when you picked its image yourself. Artwork it merely shows because its album has one doesn’t count.",
        "needsMatchReview": "Yes when the album’s Last.fm match is uncertain or not found and you haven’t fixed it — the albums worth opening “Fix album match…” on. Pending until the album’s tracklist has been looked up.",
        "mergedEditionReview": "Yes when this album name is counted together with other editions of the album, but at least 3 of the different tracks you played under it aren’t on the album’s matched tracklist — an edition with tracks of its own (an anniversary edition, demos, a live version) that is probably better counted on its own, from “Fix album match…”. No once you counted it on its own or chose to keep it merged; no for an album with one name or no real tracklist. Pending until the album’s tracklist has been looked up.",
    ]

    // MARK: Dates

    private static let dates: [String: String] = [
        "firstPlayed": "The date of the earliest play in the period (or date scope). Compared by whole local days. No value if none.",
        "lastPlayed": "The date of the latest play in the period (or date scope). Compared by whole local days. No value if none.",
        "releaseYear": "The year it was first released. An album uses your override, else the detected date. A track uses its own override, else its main album’s date (the album it is scrobbled under most), and only a track with no album is looked up on its own. No value means none could be found; a lookup still running matches nothing.",
        "releaseDate": "The first day of the period known: a year-only release is January 1, a month-only release is the 1st. Compared in UTC. To filter on the year exactly, use **Release year**.",
    ]

    // MARK: Context

    private static let context: [String: String] = [
        "artistDiscographySize": "Number of different non-empty album names by the item’s artist in your whole library. Editions count separately. Not limited by the period.",
        "peakTimeOfDay": "The time of day with the most plays: Night (9 PM to 5 AM), Morning (5 AM to noon), Afternoon (noon to 5 PM) or Evening (5 PM to 9 PM), in local time. A tie goes to the earliest of those in that order. It describes the item’s most common time, not each play; to keep only plays from certain hours, use “Only count plays on certain days or hours”.",
        "dayOfWeek": "The weekday on which the item was played most often (a tie goes to the earlier day, Sunday first). Describes its most common day, not every play.",
        "weatherCondition": "The kind of weather most of its plays were made in: Clear, Cloudy, Fog, Rain, Snow or Thunderstorm, at your home place, for the hour of each play (a tie goes to the first in that order). Needs weather turned on and downloaded in Settings › Weather; without it, or for plays outside the downloaded years, there is no value. It describes the most common weather, not every play.",
        "weatherTemperatureBand": "Whether it was usually Cold, Mild or Hot when it was played, judged against your own place’s hourly temperatures: by default the coldest 20% of hours are Cold and the warmest 20% Hot (change the percentages in Settings › Weather). A tie goes to Cold, then Mild. It describes the most common band, not every play.",
        "weatherAverageTemperature": "The average outdoor temperature at the hours of its plays, at your home place, in Celsius or Fahrenheit as chosen in Settings › Weather (a condition on it is typed in that unit). Plays without weather are left out of the average. For hot and cold judged against your own climate, use Temperature (relative).",
        "weatherShare": "The share of its plays made in the chosen weather (Rain, Snow, Fog, Thunderstorm, Clear or Cloudy, or Cold, Mild or Hot for your place), among its plays that have weather. A share built on a few plays is noisy, so pair it with a minimum number of plays.",
        "weatherLift": "Its share of plays in the chosen weather divided by the share across all the plays in the same period: 1.00 is typical, 2.00 twice as often as usual, 0.50 half as often. It already allows for how rare that weather is. No value if that weather never occurs in the period. Noisy for items with few plays.",
        "peakSeason": "The season with the most plays: Winter, Spring, Summer or Autumn, as whole calendar months. In the northern hemisphere winter is December to February, spring March to May, summer June to August and autumn September to November; in the southern hemisphere each season is six months later (winter is June to August). Choose your hemisphere in Settings › General › Dates. A tie goes to the first of Winter, Spring, Summer, Autumn. It describes its most common season, not every play: to count only the plays made in a season, use the season chips under “Only count plays at certain times or in certain weather”.",
        "weekdayOrWeekend": "Weekend if more plays fell on Saturday or Sunday than on weekdays; otherwise Weekday (a tie is Weekday). Describes its most common kind of day.",
    ]

    // MARK: Duration

    private static let duration: [String: String] = [
        "duration": "The track’s length. You type it in minutes (it is stored in seconds). A length you entered wins over the one found online (Deezer). “No value” means none could be found and won’t be retried; a lookup still running matches neither a value nor “is missing”. See [Plays and time listened](help://metrics-plays-time).",
        "timeListened": "Σ track length × plays over the tracks played in the period (or date scope). You type it in hours. A track with no length found contributes 0, and while any played track’s length is still being looked up the result is pending, so a partial total is never compared.",
    ]

    // MARK: Tempo

    private static let tempo: [String: String] = [
        "bpm": "The track’s tempo in beats per minute. A tempo you entered wins over the one found online (GetSongBPM, then Deezer). “No value” means none could be found; it is looked up again after about three months. A lookup still running matches neither a value nor “is missing”.",
        "tempoBucket": "The track’s tempo as a preset range: Slow (under 90 BPM), Moderate (90 up to 120), Upbeat (120 up to 140), Fast (140 up to 160) or Very fast (160 and over). Use BPM for an exact span.",
        "bpmSource": "Where the track’s tempo came from: GetSongBPM, Deezer, or Entered by you. A track with no tempo never matches, not even “is not”.",
        "timeSignature": "The track’s time signature, such as 4/4 or 3/4, as GetSongBPM reports it. Tempos found by Deezer or entered by you carry none unless GetSongBPM also knew the track, so those show no value.",
        "musicalKey": "The track’s musical key, such as Cm or F#, as GetSongBPM reports it. Tempos found by Deezer or entered by you carry none unless GetSongBPM also knew the track, so those show no value.",
    ]

    // MARK: Album metadata

    private static let album: [String: String] = [
        "albumEditionNames": "How many edition names of the album (the standard album, a Deluxe or Anniversary edition…) are counted together for turnover and the album match. 1 for an album with a single name, or an edition you counted on its own.",
        "albumOffListTracks": "How many different tracks you played under this album name that aren’t on the album’s matched tracklist, ignoring edition words in titles. No value when the album has no real tracklist (turnover then uses the tracks you played). Pending until the tracklist has been looked up.",
        "albumMatchStatus": "How the album’s tracklist was matched on Last.fm. “Confirmed by you”: you fixed the match, or saved a tracklist. “Using played tracks”: you chose to ignore Last.fm’s tracklist. “Auto-matched”: found and looked consistent. “Uncertain match”: found but the track counts disagree. “No match found”. Pending until the tracklist has been looked up.",
    ]

    // MARK: Tags

    private static let tagFields: [String: String] = [
        "tags": "Last.fm community tags plus your own, as one list (lowercased, duplicates removed). An album or track uses its own community tags, or its artist’s when it has none. Your tags count from the item itself, its album (for a track) and its artist. Needs those tags looked up first: until then the item matches neither a tag test nor “is missing”. An item with no tags at all counts as an empty list, so “is none of” includes it.",
        "myTags": "Only the tags you put on the item, its album or its artist on Last.fm — never community tags. Needs your tags synced first (Tag Management or the background tag sync does this).",
    ]

    // MARK: Similar sounds

    private static let similar: [String: String] = [
        "similarScore": "How closely Last.fm rates the track to your seeds, 0 to 100 — the best match across the seeds that surfaced it. Only meaningful in a Similar Sounds result.",
        "similarBecause": "The seed or seeds that surfaced the track, best match first. Filter on it to keep what one seed found.",
    ]
}
