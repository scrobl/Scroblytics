import Foundation

extension HelpContent {
    static let fieldsSection = HelpSection(id: "fields", title: "Field reference", articles: [
        HelpArticle(
            id: "fields-overview",
            title: "How to read the field reference",
            summary: "What “period”, “date scope”, “now”, “no value” and “pending” mean in every field definition.",
            blocks: [
                .paragraph("Fields are the things you can show as a column, filter on or sort by in [Query](help://query-basics), ask for in [Ask](help://ask), and that the Tools are built from. Each entry below gives what it applies to, its type, and exactly how its value is worked out."),
                .definitions([
                    HelpDefinition(term: "Applies to", detail: "Artist, Album or Track. A field is offered only for the kinds it makes sense for."),
                    HelpDefinition(term: "Period", detail: "The query’s own date range (“Only count plays in a period”). With none set, every play counts. Most volume and recency fields count only plays inside it."),
                    HelpDefinition(term: "Date scope", detail: "A date range one column carries for itself (for example “plays this month” next to “plays last month”). It ignores the query’s period and its “certain days or hours” filter, and reads the whole library inside its own range."),
                    HelpDefinition(term: "Baseline", detail: "The second range a comparison field measures its scope against. The default is the last 30 days against the same 30 days a year earlier."),
                    HelpDefinition(term: "Now", detail: "The query’s “as of” moment, normally the moment you run it. “Days since…” and “last N days” are measured from it."),
                    HelpDefinition(term: "No value / pending", detail: "See [Missing and pending](help://concepts-missing-pending). A field that is “filled in by a background lookup” can be pending."),
                    HelpDefinition(term: "Settings", detail: "Some fields have a setting that changes what they compute (for example the window length for Peak plays). Different settings are different values."),
                ]),
                .callout(.note, "Percentage-style fields (Fade ratio, Popularity, the loved ratios) are shown as percentages but their values are fractions from 0 to 1: type 0.25 for 25%. Duration is typed in minutes and Time listened in hours."),
            ]
        ),
        HelpArticle(id: "fields-name", title: "Name", summary: "The names that identify an item.",
                    blocks: [.fieldGroup(.identity)]),
        HelpArticle(id: "fields-flags", title: "Flags", summary: "Yes/no facts: loved, popular, flagged, in your Apple Music library, missing artwork…",
                    blocks: [.fieldGroup(.flags)]),
        HelpArticle(id: "fields-tags", title: "Tags", summary: "Last.fm community tags and your own tags.",
                    blocks: [.fieldGroup(.tags)]),
        HelpArticle(id: "fields-volume", title: "Volume", summary: "Play counts, active days/weeks/months and milestones.",
                    blocks: [.fieldGroup(.volume)]),
        HelpArticle(id: "fields-rank", title: "Rank & momentum", summary: "Rank by plays, change against another period, and climbing.",
                    blocks: [.fieldGroup(.ranking)]),
        HelpArticle(id: "fields-engagement", title: "Engagement pattern", summary: "How completely and how often you cycle through an album.",
                    blocks: [.fieldGroup(.engagement)]),
        HelpArticle(id: "fields-recency", title: "Recency", summary: "When you first and last played something, and how far apart.",
                    blocks: [.fieldGroup(.recency)]),
        HelpArticle(id: "fields-sentiment", title: "Sentiment", summary: "Fading favorites and loved ratios.",
                    blocks: [.fieldGroup(.sentiment)]),
        HelpArticle(id: "fields-dates", title: "Dates", summary: "First/last played and release dates.",
                    blocks: [.fieldGroup(.dates)]),
        HelpArticle(id: "fields-context", title: "Context", summary: "When in the day and week an item is played; size of an artist’s catalog.",
                    blocks: [.fieldGroup(.context)]),
        HelpArticle(id: "fields-duration", title: "Duration", summary: "Track length and time listened.",
                    blocks: [.fieldGroup(.duration)]),
        HelpArticle(id: "fields-tempo", title: "Tempo", summary: "Beats per minute, tempo range, source, time signature and key.",
                    blocks: [.fieldGroup(.tempo)]),
        HelpArticle(id: "fields-album", title: "Album metadata", summary: "How an album matched Last.fm.",
                    blocks: [.fieldGroup(.metadata)]),
        HelpArticle(id: "fields-similar", title: "Similar sounds", summary: "Match score fields, available only for Similar Sounds results.",
                    blocks: [
                        .paragraph("These two fields only mean something for a generated pool of similar music, so they appear in the [Similar Sounds](help://tool-similar-sounds) refinement conditions and not in the Query tab’s pickers."),
                        .fieldGroup(.similarity),
                    ]),
    ])
}
