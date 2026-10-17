import Foundation

extension HelpContent {
    static let screensSection = HelpSection(id: "screens", title: "Screens", articles: [
        HelpArticle(
            id: "screen-overview",
            title: "Overview",
            summary: "What each card shows and which ones follow the date range.",
            blocks: [
                .paragraph("Overview is a dashboard. The **Period**, **Compare** and **Metric** controls at the top (see [Date range, comparison and Metric](help://concepts-metric-compare)) drive the cards marked “range” below; the others always look at fixed windows or all of your history. Press ⌘R to recompute it from local data."),
                .table(headers: ["Card", "Follows the range?", "What it shows"], rows: [
                    ["**Milestone / Album turned over banners**", "No", "Dismissible notices from the last sync(s): [milestones](help://metrics-milestones) crossed and albums that completed a [turnover cycle](help://metrics-turnover)."],
                    ["**Almost there**", "No", "Up to 6 artists, albums or tracks exactly one play from a milestone, soonest expected first, in three columns and two rows. A narrower window shows the first 4 (two columns) or 2 (one column), never a third row."],
                    ["**Listening totals**", "Yes", "Scrobbles (or Time listened), distinct artists, albums and tracks in the range, each with a change badge against the comparison. The Tracks tile’s second line says how many of those tracks are loved right now. “N new” on Artists = artists whose first-ever play is in the range. “N turned over” on Albums = completions in the range."],
                    ["**Top picks**", "Yes", "The top artist, album and track by the Metric, each with a small trend line."],
                    ["**Last 24 hours**", "No", "Hourly plays over a rolling day. Click an hour that has plays to open that hour in [Query](help://query-basics) (the plays of that day in that clock hour, by track). The current hour can include plays from the same hour yesterday in its count, since the strip covers a rolling 24 hours; Query counts only today’s."],
                    ["**Current streak**", "No", "[Streaks](help://metrics-streaks-heatmap) with a 30-day strip. Click a day that has plays to open that day in [Query](help://query-basics)."],
                    ["**On This Day**", "No", "Tracks you played on today’s date in earlier years."],
                    ["**Milestones**", "No", "Three random upcoming milestones."],
                    ["**Album Turnovers**", "No", "Albums a track or two from a completed cycle (needs Last.fm credentials)."],
                    ["**Most Recent, Most Often**", "No", "[New discoveries you play a lot](help://metrics-velocity) (90-day window, at least 5 plays)."],
                    ["**Climbing**", "No", "Tracks that broke into your top 500 in the last 90 days ([The Climb](help://metrics-climb))."],
                    ["**Fading Favorites**", "Yes", "[Tracks that peaked and went quiet](help://metrics-fading)."],
                    ["**Similar Sounds**", "No", "One artist, one album and one track from your library similar to what you played in the last 14 days ([how](help://metrics-similar))."],
                    ["**The Long Tail**", "Yes", "How concentrated your listening is ([Long tail](help://metrics-distribution))."],
                    ["**Top Tags**", "Yes (always plays)", "Your most-played tags, from artists’ community tags, ignoring the Metric switch."],
                    ["**Most recent**", "Yes", "Your last 10 scrobbles in the range with chart rank, previous rank and movement ([columns](help://metrics-chart-columns)). “View all” opens the full scrobble history."],
                ]),
                .paragraph("Cards that pick **3 random** items re-draw each time Overview loads from a fixed pool of qualifying items. Clicking a card opens the related screen or tool."),
            ]
        ),
        HelpArticle(
            id: "screen-top-charts",
            title: "Top Charts",
            summary: "Ranked lists of artists, albums or tracks, with movement against an earlier chart.",
            blocks: [
                .paragraph("Choose **Artists / Albums / Tracks**, the Period, Compare and Metric, and how many **Rows** (10 to 500, remembered per kind). The columns **This, Prev, Move, Peak** are defined in [Top Charts columns](help://metrics-chart-columns). Albums credited to several artists are merged into one row (see [Names, albums and artists](help://concepts-identity))."),
                .bullets([
                    "A **diamond** beside a row is [popularity](help://metrics-popularity); a heart on a track is loved.",
                    "**Right-click** a row for actions: open, love/unlove (needs Track Actions), flag, Fix Album Match, Resync, refresh/copy/paste/set/reset image, View Lyrics, View in Apple Music, View in Last.fm.",
                    "**Create Apple Music Playlist** exports the chart’s tracks that are in your Music library.",
                    "**Chart race** animates cumulative rankings across the range.",
                    "List or grid layout is a toggle.",
                    "**Share** makes an image or text of the chart as it is on screen ([Sharing](help://screen-sharing)).",
                ]),
            ]
        ),
        HelpArticle(
            id: "screen-sharing",
            title: "Sharing",
            summary: "The Share button: an image or text of what you are looking at, for friends or a Reddit post.",
            blocks: [
                .paragraph("A **Share** button appears where something worth showing is: on [Top Charts](help://screen-top-charts), and on the header of an artist, album or track page ([how](help://screen-detail-pages)), on [Milestones](help://screen-milestones) on each month of the [Timeline](help://screen-timeline), on the results of a [Query or Ask](help://query-basics), and on a [Rabbit Hole](help://tool-rabbit-hole) path. The [Collage Generator](help://tool-collage) has **Copy Image** and **Share…** beside Save PNG. More screens will follow. The button opens a preview of a card made from exactly what is on screen, with options that suit that card (size, how many rows, whether to show plays and movement) and four ways to send it on."),
                .bullets([
                    "**Copy Image** puts the card on the clipboard. Paste it into a Reddit post, a message or a document.",
                    "**Save PNG…** saves it as a file (twice the card’s size, so it stays sharp when shrunk).",
                    "**Share…** opens the macOS Share menu (Messages, Mail, AirDrop, Notes and so on).",
                    "**Copy Text** copies the same list as a Markdown table (Reddit shows it as a table), a Markdown list, or plain text.",
                ]),
                .paragraph("A chart makes a ranked list. An artist, album or track page makes a profile card: the picture and name, the page’s own numbers as tiles (the plays or time in the page’s period, first and last scrobble, play frequency, and the page’s facts such as release date and turnover), the yearly rank and milestone badges, and the trend line. The card says the period the page is showing. The text forms give the same numbers as a table or list."),
                .paragraph("A list that isn’t a ranking (the milestones you reached) has no row numbers, and shows each milestone as a coloured pill like the Milestones page. The library’s own total milestones have no picture, so the preview lets you choose a trophy or the Last.fm logo for them. A month of the Timeline makes a recap card: its name, totals, its top artist, album and track with their pictures, and the milestones reached that month. One achieved milestone makes a card with the number reached, the date and how long it took. A query’s results make a list card with one value column (the one it is sorted on, or the one you pick in the preview) and all the columns in the text copies."),
                .paragraph("Cards are square, portrait or wide. The card uses the pictures saved on this Mac; with [Offline mode](help://offline-mode) on, a picture that isn’t saved is left out and the preview says so."),
                .heading("What a card says about you"),
                .paragraph("Nothing by default: no Last.fm name and no “Scroblytics” credit. Turn on **Show my Last.fm name** (from your saved account) or **Show “Scroblytics” on the card** in the preview, or under Settings › General › Sharing; your choice is remembered. In front of your name goes the Last.fm logo (the red circle) by default; Settings › General › Sharing also offers the “last.fm” wordmark, a simple badge, or no mark at all, and the same choice marks the Now Playing bar. A card is made on your Mac. Nothing is sent anywhere unless you paste it or pick a target in the Share menu, and no Reddit or other account is used."),
            ]
        ),
        HelpArticle(
            id: "screen-library",
            title: "Library",
            summary: "An A–Z browser of artists and albums.",
            blocks: [
                .paragraph("Library lists **artists** or **albums** alphabetically (a leading “The” is ignored for sorting) with an A–Z jump strip, in grid or list form. It has no Tracks tab. Selecting an item opens its detail page."),
                .paragraph("It uses the same Period control as Top Charts: the list contains items that have plays in the selected range, so choose **All time** to see everything. It shows no rank or play count; use [Top Charts](help://screen-top-charts) for those."),
            ]
        ),
        HelpArticle(
            id: "screen-detail-pages",
            title: "Artist, album and track pages",
            summary: "The stats and editing controls on a detail page.",
            blocks: [
                .paragraph("Each page is one card with the artwork, name, trend line, the numbers below, and the tags, then the item’s own list: an artist’s albums or tracks, an album’s tracks, or a track’s plays. Facts that are still being looked up show “Checking…” in place, so the layout doesn’t jump."),
                .definitions([
                    HelpDefinition(term: "Stat tiles", detail: "Scrobbles (or Time listened) in the range, First scrobble and Last scrobble, and **Play frequency**: average days between plays across the item’s whole lifetime = (last − first) ÷ (plays − 1), blank with fewer than two plays."),
                    HelpDefinition(term: "Yearly medals", detail: "“#N · YYYY”: the item’s rank among everything of its kind in each past calendar year, for years it placed in the top 25. The current year isn’t included."),
                    HelpDefinition(term: "Milestones", detail: "Upcoming and achieved play-count [milestones](help://metrics-milestones) for this item."),
                    HelpDefinition(term: "Release date and duration", detail: "The pencil opens an editor. A release date accepts `YYYY`, `YYYY-MM` or `YYYY-MM-DD`; a duration accepts `m:ss` or `h:mm:ss`, with an Apple Music prefill. “Reset to Detected” removes your override. A track’s own release date applies to that song only, not its album."),
                    HelpDefinition(term: "Tempo", detail: "A track’s tempo in BPM, with its time signature and key when GetSongBPM knew them; hover for where it came from. The pencil opens an editor with ÷ 2 and × 2 buttons for a tempo a detector reported at half or double speed. “Reset to Detected” removes your correction. See [Tempo](help://tempo-lookup)."),
                    HelpDefinition(term: "Share", detail: "The share icon beside the name makes a card of the page (see [Sharing](help://screen-sharing)): the picture, the numbers in the tiles, the badges and the trend, for the period chosen above. It is disabled until the numbers have loaded."),
                    HelpDefinition(term: "Tags", detail: "Community tags (from Last.fm, read-only) and Your tags. Adding or removing yours needs [Track Actions](help://track-actions) and changes your public Last.fm profile."),
                    HelpDefinition(term: "Album turnover", detail: "Cycles completed, rate and tracks still unheard ([how](help://metrics-turnover)). They show as tiles (**Tracks**, **Turnover**, **Full cycles** and **This cycle**, such as “8 of 11”), and the per-track checklist is the **Cycle** column of the track table."),
                    HelpDefinition(term: "Track table", detail: "An album’s whole tracklist in order, with each track’s plays in the chosen period and when it was last played. The **Cycle** column shows whether the track counts toward the current listen-through, which is all-time, not limited to the period. A track with no plays in the period is dimmed and shows 0, but it still opens its own page (which shows its plays for whatever period you choose). Plays that match no title on the tracklist are listed under “Other tracks played”. **All tracks**, **Played in period** and **Not heard this cycle** filter it. With no Last.fm account, no tracklist or no match, it is just the tracks you played, with no Cycle column. The playlist export includes only tracks you played. **Length** is the track’s saved length (your correction, else the lookup); a track whose length isn’t known shows a dash. A narrow window drops “Last played” first, then “Length”."),
                    HelpDefinition(term: "Sort and direction", detail: "The **Sort** menu orders an album’s tracks or an artist’s albums and tracks, and the arrow beside it reverses the order; its tooltip says which way it runs (“Newest first”, “Z to A”). Track order and A–Z start upward; plays and dates start with the most or newest. Choosing another sort resets the direction. Where a track or album has nothing to date (no release year, no play in the period), it stays last either way."),
                    HelpDefinition(term: "Fix album match…", detail: "Choose which tracklist an album should be compared with. Tapping a candidate only stages it; **Save** commits. Options: a Last.fm alternate, an edition from your Music library, a pasted tracklist, “just use the tracks I’ve played”, or reset to automatic. The decision applies to all name variants of the album and is included in backups. When an album has more than one edition name, the sheet also offers **Count this edition on its own**: use it for an edition with extra discs or different tracks (an anniversary edition, say). Its plays, Last.fm tracklist and turnover are then counted apart from the other editions, and turning it off merges them again. Until then the **Turnover** tile says “Counted with all editions”. The Missing Data field **Merged Editions** finds the names worth doing this for; merging an edition back counts as having reviewed it. Use the pencil on the **Turnover** tile (a warning when the match is uncertain), or right-click the album art."),
                ]),
            ]
        ),
        HelpArticle(
            id: "screen-timeline",
            title: "Timeline",
            summary: "Your top artist, album and track for every month and week.",
            blocks: [
                .paragraph("Newest month first. Each month shows totals (plays, artists, albums, tracks), any milestone badges reached that month, and the top artist, album and track; its weeks (starting on your chosen week-start day) are nested beneath. The only control is the Metric. It ignores the date range. Each month has a **Share** button that makes a recap card of it ([Sharing](help://screen-sharing))."),
                .paragraph("A period’s winner is the highest value; ties go to whichever was first played in that period, then to artist name. Artist spellings are combined; albums are identified by exact artist and album name."),
            ]
        ),
        HelpArticle(
            id: "screen-trends",
            title: "Trends",
            summary: "Charts about how your listening changes and is distributed.",
            blocks: [
                .paragraph("Trends has its own Period and **Compare with** control (see [Date range, comparison and Metric](help://concepts-metric-compare)) and four groups, chosen with **Show**. Each chart has its own Metric switch, and clicking part of a chart opens Query pre-filled. Query’s breadcrumb and Back button return to the Trends screen that opened it."),
                .table(headers: ["Group", "Charts"], rows: [
                    ["**Listening**", "Volume over time; When you listen (weekday × hour heatmap); Discovery (new vs repeat plays) — [Discovery](help://metrics-distribution)"],
                    ["**Taste & eras**", "Eras (share by release decade); Taste (top tags) — [Eras and Taste](help://metrics-trends-other)"],
                    ["**Habits**", "Long tail; Loyalty — [Long tail and Loyalty](help://metrics-distribution)"],
                    ["**Rankings & flow**", "Rankings (bump chart); Listening flow — [Rankings and Flow](help://metrics-trends-other)"],
                ]),
            ]
        ),
        HelpArticle(
            id: "screen-milestones",
            title: "Milestones",
            summary: "Upcoming and achieved play-count milestones.",
            blocks: [
                .paragraph("Pick Total, Artists, Albums or Tracks, then filter by tier (100 up to 10K, and a combined 25K+ chip). **Upcoming** shows progress to the next threshold, “N to go” and an estimated date based on your last 30 days (up to 60 per category); **Achieved** shows when each threshold was crossed. It covers all of your history and ignores the date range. Definitions: [Milestones](help://metrics-milestones). **Share** (top right) makes a list card of the achieved milestones for the category and tier you are looking at; the share icon on an achieved card makes a card for that one milestone ([Sharing](help://screen-sharing))."),
            ]
        ),
        HelpArticle(
            id: "screen-search-now-playing",
            title: "Search and Now Playing",
            summary: "Library search and the Now Playing shelf.",
            blocks: [
                .bullets([
                    "**Search Library… (⌘F or the toolbar magnifier)** searches artists, albums and tracks across your whole history, ranking exact matches first and then by all-time plays. Choosing a result opens it in Library.",
                    "**Now Playing** shows your current Last.fm track in a shelf at the bottom while one is playing, with a Hide button; the Last.fm mark at its right end is the one chosen in Settings › General › Sharing. **View › Show Now Playing** hides or shows it. The app checks about every 15 seconds while a window is active, backing off up to 2 minutes after failures. Hiding the shelf also stops the checking, and showing it again resumes it. [Offline mode](help://offline-mode) stops it too. The playing track is never saved as a scrobble.",
                    "**Back to Overview** appears in the toolbar after you jump from an Overview card, to return you to it.",
                ]),
            ]
        ),
    ])
}
