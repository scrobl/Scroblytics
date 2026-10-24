import Foundation

extension HelpContent {
    static let conceptsSection = HelpSection(id: "concepts", title: "Key concepts", articles: [
        HelpArticle(
            id: "concepts-identity",
            title: "Names, albums and artists",
            summary: "How the app decides two things are the same, and why screens can differ.",
            blocks: [
                .paragraph("A **scrobble** (a play) is one row from Last.fm: artist, album (possibly empty), track title and the time it was played. Everything else is built from those."),
                .heading("Artists"),
                .bullets([
                    "Artist names are compared ignoring capitalization and surrounding spaces, so “ARTIST” and “Artist” are one artist on every screen, including Overview, Milestones and the artist, album and track pages. Their plays are combined and the **most-played spelling** is shown (a tie goes to the later name alphabetically).",
                    "Punctuation, accents and “The” are significant: “The Artist” and “Artist” are different artists. (Sorting ignores a leading “The” so it files under A.)",
                    "A collaboration credit such as “A & B” is a different artist from “A”. For an artist’s **album** and **track** counts on a detail page, collaboration credits that name the artist are included.",
                ]),
                .heading("Albums"),
                .paragraph("Album identity depends on the screen:"),
                .table(headers: ["Where", "How albums are identified"], rows: [
                    ["**Top Charts, Library**", "By artist and album name, except that one album name credited to a main artist plus collaborators becomes a single row, and the same name credited to two or more unrelated artists becomes **Various Artists** (a compilation). Which names are merged is decided from the plays in the selected date range. Editions credited to one artist (“Album” and “Album (Deluxe)”) stay separate rows."],
                    ["**Query, Trends, Timeline, Milestones, Overview totals, most Tools**", "By exact artist and album name as scrobbled. “Album” and “Album (Deluxe)” are separate, and a compilation is one row per credited artist."],
                    ["**Global Search**", "By artist and album name with capitalization ignored."],
                    ["**Collage and Chart Toppers**", "By artist and a normalized album name, which combines editions of one album by one artist (Deluxe, Remastered, Anniversary, Mono/Stereo, region tags and years are ignored)."],
                    ["**Album Turnover and Fix album match**", "Edition variants of one album are grouped by similar name, and a decision you save applies to all variants, unless you choose **Count this edition on its own** in Fix album match… (an edition with extra discs or different tracks, such as an anniversary edition): it then has its own plays, tracklist and turnover."],
                ]),
                .callout(.note, "Because of these differences an album’s play count can differ between screens, most often for compilations, collaborations and editions. Scrobbles with no album are skipped wherever albums are counted. Artist totals don’t have this problem: every screen combines an artist’s spellings (below)."),
                .heading("Tracks"),
                .paragraph("A track is an artist plus a title. Loved, flagged and duration data are matched by artist and title **regardless of album**, so every album’s copy of a song shares them. Where the app compares tracks against your Apple Music library or tracklists, edition brackets, “feat.” credits and endings such as “– Remastered” are ignored."),
                .callout(.tip, "If a play counts under the wrong album, use **Fix album match…** (right-click the album art) or correct it on Last.fm and run a [Resync](help://sync-types)."),
            ]
        ),
        HelpArticle(
            id: "concepts-metric-compare",
            title: "Date range, comparison and Metric",
            summary: "The shared controls at the top of Overview, Top Charts and Library.",
            blocks: [
                .heading("Date range"),
                .paragraph("The **Period** menu sets the date range. The choice is remembered and shared by Overview, Top Charts and Library; Milestones and Timeline ignore it. The default is **Last 30 days**."),
                .table(headers: ["Choice", "Covers"], rows: [
                    ["All time", "From your oldest scrobble to now"],
                    ["Year to date / Month to date", "From the start of the year / month (local time) to now"],
                    ["Last 7 / 30 / 90 / 365 days", "The previous N × 24 hours up to now (not whole calendar days)"],
                    ["A calendar year", "January 1 00:00 to December 31 23:59:59, local time"],
                ]),
                .heading("Comparison (Prev and Move)"),
                .paragraph("The **Compare** menu says what to compare the current chart against: Yesterday, 7, 30, 90 or 365 days ago, or a custom date. It is **not** “the previous period of the same length”. The comparison chart keeps the range’s start and ends N days earlier, so it answers “what did the ranking look like N days ago?” A choice is offered only if N is smaller than the range’s length; if your current choice stops being valid after you change the period, the widest valid one is used. A custom date means the same start and an end at 23:59:59 of that day."),
                .paragraph("The percent change on Overview’s totals is (current − previous) ÷ previous × 100, rounded to a whole number. When the previous value is 0 it shows **New**. The change badge is hidden for Time listened."),
                .paragraph("**Trends** has its own, different comparison: previous period (the matching calendar span for a whole year or month-to-date, otherwise an equal-length stretch just before), the same period last year, or a custom period."),
                .heading("Metric"),
                .paragraph("**Scrobbles** counts plays; **Time listened** adds up track lengths. See [Plays and time listened](help://metrics-plays-time)."),
            ]
        ),
        HelpArticle(
            id: "concepts-time",
            title: "Dates, weeks and time zones",
            summary: "What counts as a “day” and when a week starts.",
            blocks: [
                .bullets([
                    "A play belongs to the **local calendar day** it happened in, using your Mac’s current time zone. Streaks, active days, heatmaps and “first/last played” comparisons all use it.",
                    "**Release dates** use UTC and are stored as “2019”, “2019-05” or “2019-05-17”. A year-only date counts as January 1, a month-only date as the 1st. Query’s **Release year** matches the year exactly even then.",
                    "**Weeks** start on the day you choose in **Settings › General › Dates › Week starts on**: Monday (the default), Sunday, or Friday (the day Last.fm’s own weeks start). The one setting applies everywhere: Timeline, Trends buckets and the rank bump chart, Overview sparklines, the **Active weeks** field, “this week” and “last week” in Query and Ask, Time Machine’s Week mode, and the release-week buckets in Collage and Chart Toppers. Changing it never alters your data; screens just regroup.",
                    "Heatmaps number weekdays from Sunday and the Trends grid displays rows Monday to Sunday, whatever the setting; **Day of week** and “certain days” filters name actual weekdays. **Seasons** are whole calendar months: in the northern hemisphere winter is December–February, spring March–May, summer June–August and autumn September–November, and in the southern hemisphere each is six months later. Choose yours in **Settings › General › Dates › Seasons**; it affects the **Season** field and the season chips in Query’s scope, never your data.",
                    "Time buckets in charts are chosen from the range’s length: days up to about 3 months, weeks up to about 2 years, months beyond (the rank bump chart uses weeks up to about 80 days and years beyond about 4).",
                ]),
            ]
        ),
        HelpArticle(
            id: "concepts-missing-pending",
            title: "Missing and pending values",
            summary: "Why some cells are empty, and what “is missing” and “has a value” match.",
            blocks: [
                .paragraph("Every value is one of three things:"),
                .definitions([
                    HelpDefinition(term: "A value", detail: "A number, text, date, yes/no or tag list."),
                    HelpDefinition(term: "No value (missing)", detail: "Known to have none: it has no plays in the range, the lookup found nothing, or the field doesn’t apply."),
                    HelpDefinition(term: "Pending", detail: "A background lookup (tags, track length, release date, popularity, album tracklist) hasn’t finished for it yet."),
                ]),
                .heading("How conditions treat them"),
                .bullets([
                    "**has a value** matches only real values. **is missing** matches only “no value”. A pending cell matches neither.",
                    "Every other operator, including negations like “≠” and “does not contain”, is false for a cell with no value or pending. “Not equal to 5” does not match an empty cell; use “is missing” for that.",
                    "**Tags are the exception**: no tags counts as an empty list, so “is none of [rock]” includes untagged items. A pending tag cell still matches nothing.",
                    "When a result has pending cells the header says “N still resolving”, with a **Resolve** button that starts only the lookups that query needs.",
                    "Sorting always puts rows with no value last, in either direction.",
                ]),
            ]
        ),
    ])
}
