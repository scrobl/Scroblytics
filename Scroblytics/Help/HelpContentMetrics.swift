import Foundation

extension HelpContent {
    static let metricsSection = HelpSection(id: "metrics", title: "Measures & definitions", articles: [
        HelpArticle(
            id: "metrics-plays-time",
            title: "Plays and time listened",
            summary: "The two measures behind the Metric switch, and where track lengths come from.",
            blocks: [
                .paragraph("**Scrobbles** (also called plays) counts listens. **Time listened** adds up how long you listened: for every track, its length multiplied by its plays, summed over whatever is being measured."),
                .heading("Where a track’s length comes from"),
                .steps([
                    "A length you entered yourself (Edit track duration, or imported from Apple Music) always wins.",
                    "Otherwise the length found on Deezer, cached once found. Deezer is the only source looked up automatically; it is searched five ways (exact artist and title, a looser form, with bracketed notes removed, with apostrophes spaced, and finally the album’s tracklist).",
                    "If Deezer has nothing, that “no match” is remembered and not retried. Add a length by hand, or use Missing Data › Import from Apple Music.",
                ]),
                .paragraph("Last.fm itself gives no track lengths, and Apple Music and MusicBrainz are never consulted for them automatically."),
                .heading("While lengths are still being found"),
                .bullets([
                    "**Top Charts and Overview** show a partial total that grows as lookups finish; a track whose length is unknown counts as zero for now.",
                    "**Query** treats **Time listened** as pending until every played track is resolved, so an incomplete total is never compared.",
                    "**Trends** leaves unresolved plays out and tells you how many are pending.",
                ]),
                .paragraph("Aggregate time is written like `2d 4h 12m 9s`; one track’s length like `3:45` or `1:03:45`."),
                .callout(.note, "A track with no length found contributes 0 once it is “resolved as missing”, so a Time-listened total can still be understated. Missing Data lists those tracks so you can fill them in."),
            ]
        ),
        HelpArticle(
            id: "metrics-chart-columns",
            title: "Top Charts columns: This, Prev, Move, Peak",
            summary: "How ranks, previous ranks and movement are worked out.",
            blocks: [
                .paragraph("Top Charts ranks items by the chosen Metric within the selected date range. Ties are broken by artist name, then track name (for albums and artists, remaining ties go to whichever was scrobbled first)."),
                .table(headers: ["Column", "Meaning"], rows: [
                    ["**This**", "Current rank in the selected range."],
                    ["**Prev**", "Its rank in the comparison chart. The comparison ranks the whole comparison range, not just the visible rows. “–” means there is no comparison range."],
                    ["**Move**", "Places gained or lost: Prev minus This. Up and down arrows show the number of places. If the item wasn’t ranked in the comparison chart it shows a purple **Hot Shot Debut** (expanded table) or a green **New** (compact layout)."],
                    ["**Peak**", "The best rank it held at any point inside the selected range, found by re-ranking at checkpoints (below). Never worse than **This**. Computed only for the rows displayed."],
                    ["**Plays / Time**", "The Metric value, with a bar showing its share relative to the top row."],
                ]),
                .heading("How Peak is sampled"),
                .paragraph("The chart is rebuilt cumulatively from the start of the range at checkpoints: daily if the range is up to about 3 months, weekly up to about 2 years, monthly beyond. The spacing is never less than one sixtieth of the range, so there are at most about 60 checkpoints, and the last one is the end of the range. Peak is the best rank across them. A rank that was reached and lost between two checkpoints can be missed."),
                .heading("The comparison range"),
                .paragraph("See [Date range and comparison](help://concepts-metric-compare). The comparison keeps the selected range’s start and moves its end back by the comparison choice; it is not a same-length “previous period”."),
                .heading("Popularity diamond"),
                .paragraph("The diamond beside a row is [Popularity](help://metrics-popularity): teal for popular across your whole library, orange for popular within that artist’s own catalog."),
            ]
        ),
        HelpArticle(
            id: "metrics-hot-shot",
            title: "Hot Shot Debut",
            summary: "A label with three related meanings.",
            blocks: [
                .paragraph("“Hot Shot Debut” always means a track that has just arrived. The exact test depends on where you see it."),
                .table(headers: ["Where", "Test"], rows: [
                    ["Top Charts and Overview’s Most recent table, **Move** column", "The item has no rank in the comparison chart (it wasn’t on that chart at all). Shown as a purple badge."],
                    ["The Climb and the Overview Climbing card", "The track had no rank at the start of the window, and now ranks inside the Top N tier."],
                    ["Query field **Hot Shot Debut**", "No plays on or before the start of the window, and now in the top quarter of all tracks by plays."],
                ]),
            ]
        ),
        HelpArticle(
            id: "metrics-climb",
            title: "The Climb",
            summary: "Tracks that broke into your all-time Top N recently.",
            blocks: [
                .paragraph("The Climb finds tracks that have recently risen into your all-time “Top N” (100 up to 5,000) and were not there before."),
                .steps([
                    "The window is the Compare choice, snapped to the nearest of 30, 60, 90, 180 or 365 days. The Overview card is fixed at 90 days, Top 500, at least 5 plays.",
                    "Ranks are all-time play ranks, computed at 6 evenly spaced checkpoints from the window’s start to now, using only plays up to each checkpoint.",
                    "A track qualifies if its current rank is within Top N, it was outside Top N (or unranked) at the window’s start, and it has at least the **Minimum plays now** in the window.",
                    "Rows are ordered by how fast and how late the climb happened: gains in later segments count more, so accelerating climbs rank above early ones.",
                ]),
                .paragraph("**Just broke out** means most of the climb happened late in the window. A debut with no earlier rank is labelled **Hot Shot Debut**."),
                .paragraph("The **Places climbed**, **Rank N days ago** and **Climb score** fields in [Rank & momentum](help://fields-rank) expose the same numbers to Query."),
                .callout(.note, "The saved Query template “Climbing (Overview card)” uses exactly these conditions (Top 500, 90 days, 5 plays), so it lists the same tracks as the card. Its ranks are over the plays the query counts, so adding a period or a days/hours filter changes them."),
            ]
        ),
        HelpArticle(
            id: "metrics-fading",
            title: "Fading Favorites",
            summary: "Peak plays, fade ratio and rediscovery score.",
            blocks: [
                .paragraph("Fading Favorites finds tracks that were once played heavily and have gone quiet."),
                .definitions([
                    HelpDefinition(term: "Window", detail: "A length in days: 30, 60, 90, 180 or 365."),
                    HelpDefinition(term: "Peak plays", detail: "The most plays the track had in any stretch shorter than the window."),
                    HelpDefinition(term: "Recent plays", detail: "Plays in the trailing window ending now (or at the end of the range, for the Overview card)."),
                    HelpDefinition(term: "Fade ratio", detail: "Recent plays ÷ peak plays. 0 is silent; 1 is still at its peak."),
                    HelpDefinition(term: "Rediscovery score", detail: "Peak plays × (1 − fade ratio). A bigger past favorite that is quieter scores higher."),
                ]),
                .paragraph("A track qualifies when its peak is at least the **Minimum peak** (5 plays unless you change it) and its fade ratio is 25% or lower. The tool uses a 90-day window and the real current time. The **Overview card** is different: it uses your selected date range, snapped to the nearest allowed window, measures “now” as the end of that range, and ignores plays after it. The card shows 3 random picks from the qualifying tracks each time it loads."),
                .paragraph("Sorts: **Biggest peak**, **Steepest fade**, **Rediscovery score** (the card orders by score, then peak, then older last play)."),
            ]
        ),
        HelpArticle(
            id: "metrics-velocity",
            title: "Most Recent, Most Often",
            summary: "New discoveries that you play a lot.",
            blocks: [
                .paragraph("Tracks you first played within a window (30, 60, 90, 180 or 365 days; the Overview card uses 90) and have already played at least a minimum number of times (1, 3, 5, 10 or 20; the card uses 5)."),
                .paragraph("**Velocity** = plays ÷ days since the first play, with a minimum of one day so a track discovered today doesn’t divide by zero. Sort by Velocity or by Plays."),
            ]
        ),
        HelpArticle(
            id: "metrics-milestones",
            title: "Milestones",
            summary: "Play-count thresholds, the ETA and the Almost there list.",
            blocks: [
                .paragraph("A milestone is a play-count threshold for an artist, album, track, or your whole library: **100, 250, 500, 1,000, 2,500, 5,000, 10,000, 25,000, 50,000, 100,000**, then every 100,000."),
                .bullets([
                    "A count exactly on a threshold has reached it; the next milestone is the following threshold.",
                    "An achieved milestone is dated by the play that crossed it.",
                    "**ETA** = remaining plays × 30 ÷ plays in the last 30 days, rounded up. No ETA if you haven’t played it in the last 30 days.",
                    "The Milestones page lists Upcoming (up to 60 per category) and Achieved. It covers all of your history and ignores the date range.",
                    "**Almost there** on Overview lists items exactly one play from a milestone. The Overview Milestones card shows 3 random upcoming ones.",
                    "After each sync that adds plays, new milestones are found by comparing before and after; they appear as dismissible banners on Overview (up to 12 per sync).",
                ]),
                .paragraph("Albums and artists count by name as scrobbled (artist plus album, album-less scrobbles skipped), so edition variants are separate here."),
            ]
        ),
        HelpArticle(
            id: "metrics-streaks-heatmap",
            title: "Streaks, heatmaps and On This Day",
            summary: "The Overview listening strips and the date-based cards.",
            blocks: [
                .definitions([
                    HelpDefinition(term: "Current streak", detail: "Consecutive local calendar days with at least one scrobble, counted back from today — or from yesterday if you haven’t played anything yet today (today only breaks the streak when it ends). **Longest** is the longest run in your history. Both ignore the date range."),
                    HelpDefinition(term: "Last 24 hours", detail: "24 hourly cells over a rolling window ending now (not calendar aligned), each showing scrobbles in that hour. Independent of the date range."),
                    HelpDefinition(term: "Heatmap shading", detail: "168 cells (weekday × hour) in local time. Colour intensity has 8 levels spaced logarithmically between the smallest and largest non-zero counts; orange for hours 6 AM to 6 PM, blue otherwise."),
                    HelpDefinition(term: "On This Day", detail: "Tracks you played on today’s calendar date (same month and day) in previous years only, grouped by track, with the years listed. Ordered by plays, then number of years. The card shows 3 random picks; the Time Machine tool offers day, week and month versions and other filters. Plays from today are not shown as a year, but are still counted in the plays figure."),
                ]),
            ]
        ),
        HelpArticle(
            id: "metrics-turnover",
            title: "Album Turnover",
            summary: "What a completed cycle is, and how albums are matched to a tracklist.",
            blocks: [
                .paragraph("A **turnover cycle** is one full listen-through of an album: every track on its tracklist has been scrobbled at least once since the previous completion. The **rate** is the median number of days a cycle took; **N tracks to go** is how many tracks are unheard in the current cycle."),
                .heading("Which tracklist is used"),
                .steps([
                    "A decision you saved with **Fix album match…** always wins (a Last.fm alternate, an Apple Music edition, a pasted list, or “use the tracks I’ve played”).",
                    "An edition you set apart with **Count this edition on its own** has its own decision, and with none it asks Last.fm for its exact title (edition words kept) instead of the plain release, so a 64-track anniversary edition is compared with its own 64-track list.",
                    "Otherwise the Last.fm tracklist for the album is looked up (and cached) and judged. It is **ambiguous** if the tracklist is more than twice or under 70% the length of the distinct tracks you’ve played, if you have scrobbled under 60% of its titles, or if either list is empty. Otherwise it is a confident match.",
                    "With no usable match the tracks you have actually played are used.",
                ]),
                .heading("Details"),
                .bullets([
                    "Albums with fewer than 2 tracks are excluded.",
                    "Editions of one album are grouped (unless you count one on its own): names are normalized (bracketed edition, region and year words removed) and clustered when equal, when one is a whole-word part of the other that adds only edition words, or when they are very similar (about 72% by edit distance).",
                    "Duplicate titles on a tracklist count by occurrence. A deep cut you have never played stalls the cycle.",
                    "The tool evaluates the top 50, 100, 150, 200 or 250 albums by plays, or all. Compilations (Various Artists, Soundtrack…) are excluded unless you include them.",
                    "On Overview, “N turned over” counts albums whose most recent completion falls in the selected range.",
                ]),
            ]
        ),
        HelpArticle(
            id: "metrics-similar",
            title: "Similar Sounds and Reverb",
            summary: "How match scores are worked out and how the Overview card chooses.",
            blocks: [
                .heading("Match score"),
                .bullets([
                    "Seeds are artists, albums or tracks you choose (up to 10 in the tool). Track seeds ask Last.fm for similar tracks; artist and album seeds ask for similar artists, and every track of yours by a similar artist inherits that artist’s match. An album seed uses its artist, because Last.fm has no album-level similarity.",
                    "Only music already in your library is kept, matched by artist and title.",
                    "The **match score** is 0–100 (Last.fm’s match × 100, rounded); when several seeds surface a track, the best score wins, and it is attributed to that seed (“Because you like…”).",
                    "The seed track itself is left out. Results sort by score, then plays.",
                    "With **Include new music**, the tracks Last.fm names that you have never played are scored the same way (an artist seed’s best-known tracks count 15% less than their artist’s match) and placed among the results by that score.",
                ]),
                .heading("The Overview Similar Sounds card (Reverb)"),
                .steps([
                    "Seeds: up to 15 artists, the ones you played most in the last 14 days.",
                    "Candidates: library tracks Last.fm rates as similar, minus anything you played in those 14 days (if that leaves a list empty, the unfiltered list is used).",
                    "Weight: match × (1 + days since last played, up to 365, ÷ 365) × (1 + 0.25 × log₂(plays + 1)). Artist and album rows add up their tracks’ weights.",
                    "Each list keeps its top 10; the card draws one of them at random, weighted. The pool is computed once per sync, so reloading gives a different pick but not new data.",
                ]),
                .paragraph("[Rabbit Hole](help://tool-rabbit-hole) uses Last.fm’s similar tracks too, but adds more sources (similar artists, shared tags, what you play next) and picks three at each step."),
            ]
        ),
        HelpArticle(
            id: "metrics-distribution",
            title: "Long Tail, Loyalty and Discovery",
            summary: "The Trends and Overview charts about how your listening is spread.",
            blocks: [
                .heading("Long tail"),
                .paragraph("A histogram of how plays (or time, days since last played, or track length) are distributed across everything played, with bars on a log scale. **Concentration** is the share of total plays that your top N% of items account for (5, 10, 20, 25 or 50; default 10, rounding the count up). It also shows the mean, median, maximum and (in Trends) mode. The Overview card ranks artists only (using Top Charts grouping); in Trends the chart can also rank albums and tracks, using Query’s exact artist and album names."),
                .heading("Loyalty"),
                .paragraph("Each dot is an item: horizontal position is its plays in the period (log scale), vertical position is how spread out those plays were — first-to-last span, or active days, weeks or months. Only items with at least the **Minimum plays** (default 3) are shown. Dashed median lines split the chart into four groups:"),
                .table(headers: ["Group", "Plays", "Spread"], rows: [
                    ["**Lifers**", "At or above the median", "At or above the median"],
                    ["**Obsessions**", "At or above the median", "Below the median"],
                    ["**Background**", "Below the median", "At or above the median"],
                    ["**Passing interest**", "Below the median", "Below the median"],
                ]),
                .paragraph("With active days, weeks or months as the spread, “Background” is always empty, because those counts can’t exceed plays."),
                .heading("Discovery"),
                .paragraph("A track’s very first play in your whole history is “new”; every other play is a “repeat”. Counts are bucketed by time (days for ranges up to about 3 months, weeks up to about 2 years, otherwise months) and weighted by the Metric. Compare buckets are matched by position."),
            ]
        ),
        HelpArticle(
            id: "metrics-trends-other",
            title: "Rankings, Flow, Eras and Taste",
            summary: "How the remaining Trends charts are built.",
            blocks: [
                .heading("Rankings (bump chart)"),
                .paragraph("The period’s top 5 or 10 are ranked afresh inside each time bucket (weeks for ranges up to about 80 days, months up to about 4 years, otherwise years). An item outside that bucket’s top N, or unplayed, leaves a gap."),
                .heading("Listening flow"),
                .paragraph("A **session** is a run of plays where no gap exceeds the **Session gap** (3, 5, 15, 30, 60, 120 or 360 minutes; default 30). A **hand-off** is two consecutive plays of different artists (or different genres) inside one session; the same artist twice in a row isn’t counted. In genre mode a genre is the artist’s first community tag, and an untagged play breaks the chain. **Minimum hand-offs** hides rare pairs. In comparison mode, edges are shared, new or dropped."),
                .heading("Eras (decade river)"),
                .paragraph("Each play adds its weight to the band of its album’s (or track’s) release year: 1960s & earlier, then each decade through the 2020s. Plays whose release date is still being looked up are counted as pending and plays with no date as “no date”."),
                .heading("Taste"),
                .paragraph("The period’s top tags, each track’s weight added to every tag it has (community tags of the item, or its artist if none, plus your own). The coverage line shows what share of plays have tags looked up. The Overview **Top tags** card is different: it adds each artist’s plays to that artist’s own community tags only, ignores the Metric switch, and shows the top few."),
            ]
        ),
        HelpArticle(
            id: "metrics-popularity",
            title: "Popularity",
            summary: "The diamond, the Popular flag and the popularity score.",
            blocks: [
                .paragraph("Popularity compares an item with the rest of **your own library**, using public numbers from Last.fm and Deezer."),
                .table(headers: ["Kind", "Signals used"], rows: [
                    ["Artist", "Last.fm listeners, Deezer fans"],
                    ["Album", "Last.fm listeners, Last.fm plays, Deezer fans"],
                    ["Track", "Last.fm listeners, Last.fm plays, Deezer rank"],
                ]),
                .steps([
                    "For each signal, the item’s percentile is the fraction of your library’s items of that kind with an equal or smaller value.",
                    "The **popularity score** is the average of the available signals’ percentiles (0 to 1).",
                    "**Popular** means the score is at or above the 75th-percentile score of your library — the top quarter.",
                    "**Popular for this artist** applies the same test among only that artist’s albums or tracks, and needs at least 4 scored items.",
                ]),
                .paragraph("The **diamond** is teal when the item is popular across the library and orange when it is popular only within its artist; teal wins if both apply. Hover for the percentiles and raw numbers."),
                .callout(.note, "Percentiles are relative to what has been looked up so far. While the background lookup is still filling in (a first run can take around an hour for a large library), scores and the quartile cut-off shift. Records refresh when older than 30 days."),
            ]
        ),
        HelpArticle(
            id: "metrics-loved-library",
            title: "Loved tracks and Apple Music library status",
            summary: "What “loved”, “in library”, “removed” and “uncertain” mean.",
            blocks: [
                .heading("Loved"),
                .paragraph("A track is loved if it is on your Last.fm loved list as of the last sync, matched by artist and title (album ignored). Tracks not on the list are “not loved”, never unknown. The Loved Status Audit compares that list with your Apple Music Favorites and flags **only on Last.fm**, **only on Apple Music**, and **uncertain** (a near-spelling match it can’t confirm, never counted as a difference; you can answer “same track” or “different tracks” and the audit remembers). **Loved, no scrobbles** lists loves whose exact name no scrobble uses."),
                .heading("Library Gaps statuses"),
                .definitions([
                    HelpDefinition(term: "Present", detail: "In Music’s library as of the last “Check library”."),
                    HelpDefinition(term: "Unavailable", detail: "In the library, but every copy is greyed out as no longer available."),
                    HelpDefinition(term: "Removed", detail: "Seen in the library at an earlier check, and not now."),
                    HelpDefinition(term: "Never in library", detail: "Never found in the library."),
                    HelpDefinition(term: "Uncertain", detail: "Not found under this title, but a near match exists under a different spelling or credit. If it is really a different recording, **Confirm** it in Library Gaps and it becomes Never in library (or Removed)."),
                ]),
                .paragraph("Tracks are matched by artist plus a normalized title: edition brackets, feat. credits and “remaster / version / edit / mix / mono / stereo” endings are removed, case and punctuation are ignored, and “&” is read as “and”. A remaster and its original therefore count as one track. The “not in your Apple Music library” badge shows for Removed, Never and Unavailable tracks. A track you confirm in Library Gaps (from Uncertain) counts as Never in library or Removed, so it gets the badge too."),
            ]
        ),
        HelpArticle(
            id: "metrics-missing-data",
            title: "Missing Data",
            summary: "What counts as missing for each field, and what “not yet checked” means.",
            blocks: [
                .table(headers: ["Field", "Missing means", "Not yet checked means"], rows: [
                    ["Release date (albums, tracks)", "Looked up and none found", "Not looked up yet"],
                    ["Images (artists, albums, tracks)", "No artwork resolves", "(no pending state)"],
                    ["Duration (tracks)", "Confirmed no match", "Length still being resolved"],
                    ["Tempo (tracks)", "Neither source has one (looked up again after about three months)", "Tempo still being looked up"],
                    ["Album match (albums)", "Uncertain or no match, not fixed by you", "Tracklist not looked up yet"],
                    ["Merged editions (albums)", "An edition name counted with its album that has 3 or more played tracks not on the album’s tracklist, not yet counted on its own or kept merged", "Tracklist not looked up yet"],
                ]),
                .paragraph("**Resolve now** re-looks up only the items not yet checked. Items confirmed missing need a manual edit (or, for durations, **Import from Apple Music**). **Advanced** opens the equivalent Query, which can express only “confirmed missing”, so its count can be smaller."),
            ]
        ),
    ])
}
