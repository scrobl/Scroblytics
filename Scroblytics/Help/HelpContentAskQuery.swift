import Foundation

extension HelpContent {
    static let askQuerySection = HelpSection(id: "ask-query", title: "Ask & Query", articles: [
        HelpArticle(
            id: "ask",
            title: "Ask",
            summary: "Type a request in plain English; the app turns it into filters and shows you before it runs.",
            blocks: [
                .paragraph("Click the sparkles button in the toolbar (or use Ask in Query). Type something like “albums I’ve played more than 20 times but not in the last year”. Ask turns the sentence into the same conditions the [Query](help://query-basics) builder uses."),
                .heading("You always see it first"),
                .paragraph("Nothing runs until you confirm. A review card, “Here’s how I understood that”, shows the filters as chips, any caveats, and any **vague words it turned into numbers** (for example “a lot” became 50 plays) so you can adjust them. Then choose **Run**, **Edit filters instead**, or **Save…**. If the reading is wrong, edit the filters, or rephrase."),
                .heading("What it can do"),
                .bullets([
                    "Threshold, gap and ranking requests over artists, albums or tracks: “top 25 tracks of 2019”, “loved tracks I haven’t played in a year”, “artists I’ve listened to on more than 200 different days”.",
                    "Periods: “this year”, “last month”, “last 90 days”. Decades: “the 90s” means release years 1990–1999. For gaps a month is 30 days and a year 365.",
                    "Tags, loved status, and caps: “N per artist”, “the top song from each album”, “one album per release year”, or “top album by release year” (a singular top, best or most played thing followed by “by release year” means the best one of each year; the plural “top albums by release year” is left to the model). Those results are shown by release year, oldest first, and say so in the chips (“Shown by release year ↑”); add “newest first” to your question to reverse it. For the best of each year you listened (not the year a record came out) say “each year”, “every year” or “per year”: “my top 3 artists each year”, “my most played album every year”. Ask runs it once per calendar year with that many per year (one when you say “my top album”, and ten if you give no number), and the chips say “For each calendar year” and “Top 3 per year”. A cap is not a total: “top 10 songs, 1 per artist” sets both. A bare “each year” isn’t read as a cap, since it could mean the year something was played; say “release year”.",
                    "Ask checks what a model wrote before it runs: a cap the model chose is kept only when your sentence says something about it (per, each, every, different…), blanks a model filled in (a date range on a name, “compared with 0 earlier”) are ignored, and “by <an artist in your library>” always becomes an Artist filter, which the explanation lists.",
                    "**Plays at certain times, in certain weather or in a city**: “top 10 songs when it is cold and raining on a Sunday morning”, “my most played songs in Munich”, “my top artists on Friday nights”, “which albums did I play most in December”, “songs I played at least 5 times when it was snowing”. The larger models (Claude, OpenAI, Gemini, Ollama or a server on this Mac) turn these into **Only count plays at certain times or in certain weather** (a chip reads like “Only plays: Sunday, 5 AM–11 AM, in rain, when cold”), so the plays counted, and the ranking, are the ones made then. A city must be one you have set in [Settings › Weather](help://screen-weather) (your home place or a trip); a city you haven’t is dropped, with a note saying which places are known. Seasons use the hemisphere chosen in Settings › General › Dates. Weather needs [Settings › Weather](help://screen-weather) turned on and downloaded; the chip warns when it isn’t, because then no plays can match. A request about an item’s habit (“songs I mostly play at night”) still uses the Day of week, Peak time of day, Season and Weather fields, which describe an item’s typical plays. The on-device engine uses those fields for both.",
                    "“Find 25 songs similar to X” is sent to [Similar Sounds](help://tool-similar-sounds) (Last.fm lookups), not turned into filters. The on-device engine can’t do these.",
                ]),
                .paragraph("Once Ask’s query has run, **Share** in the results header makes an image of the answer with your question as its title ([Sharing](help://screen-sharing)). It stops being the title as soon as you change a filter, sort or limit."),
                .paragraph("The results grid shows the fields your request sorts on, filters on or groups by (for example **Release year** when you ask for one album from each release year), then Plays and Last played to round it out. Artist and album are already shown under each name."),
                .paragraph("The example sentence shown in the empty box is chosen from things Ask can actually do, and changes each time you open it; press **Tab** or **Try it** to use it. The box clears after a query runs."),
                .heading("Engines and privacy"),
                .paragraph("Which model reads your sentence, what is sent, and how keys are stored are covered in [Ask engines and their API keys](help://ask-keys). Larger cloud models are noticeably more accurate than the on-device model. Always check the chips against what you meant."),
                .paragraph("A small line under the Ask box always names the model that will answer (for example “Claude (Anthropic) · claude-sonnet-5-5”). When it is the on-device model it also warns that capabilities and results are limited. **Change in Settings** on that line opens Settings › Ask, and the line updates as soon as you change the choice."),
            ]
        ),
        HelpArticle(
            id: "query-basics",
            title: "Query: building conditions",
            summary: "Groups, operators, sorting and limits.",
            blocks: [
                .paragraph("Query finds artists, albums or tracks that match conditions, shows chosen columns, and sorts them. Pick **Find** (Artists, Albums or Tracks), add conditions, and run. Every field is defined in the [Field reference](help://fields-overview), and hovering any field name shows a short definition."),
                .heading("Combining conditions"),
                .bullets([
                    "Conditions inside one **group** must **all** be true (AND). A query matches when **any** group matches (OR). With no groups, everything matches.",
                    "Saved sets (Sets menu) store the whole query; the menu also has templates, such as Time Machine comparisons.",
                ]),
                .heading("Operators by type"),
                .table(headers: ["Type", "Operators"], rows: [
                    ["Number", "=, ≠, >, ≥, <, ≤, between (inclusive)"],
                    ["Text", "is, is not, contains, does not contain, starts with, does not start with, ends with, does not end with, contains whole word. Case, accents and width are ignored."],
                    ["Date", "before, after, on, between — by whole local days (release dates by UTC days)"],
                    ["Yes/no", "is yes, is no"],
                    ["Tags", "is any of, is all of, is none of, is not all of"],
                ]),
                .paragraph("Every type also has **has a value** and **is missing**. How empty and pending cells behave is in [Missing and pending values](help://concepts-missing-pending)."),
                .heading("Sorting and limits"),
                .bullets([
                    "Sort by several keys; rows with no value always sort last. Remaining ties fall back to name, then artist. Tag lists can’t be sorted. **Shuffle** randomizes.",
                    "The row **limit** is applied after sorting and after the caps (Scope › **At most N per artist / per album / per release year**, all of which can be used together). Per artist isn’t available when finding artists; per album applies only to tracks, and a track with no album is never capped by album; per release year applies to albums and tracks, and anything whose release year is missing, or still being looked up, is never capped by year (the year is the Release year field’s own value).",
                    "**Break down by calendar year** (under Scope) runs the query separately over each calendar year of the plays it counts and keeps the **Top (per year)** number for each, so “my top 3 artists of every year” is one query. Each row is an artist, album or track in a year, with that year’s own plays (and the year in its own column); an artist in the top 3 of several years appears once for each. Conditions, sorts and caps are applied to each year on its own (“plays ≥ 4” means 4 in that year), the oldest year comes first unless you tick **Newest year first**, and a period you choose limits which years are included. The current year is whatever has been played so far. It is a different thing from a per-release-year cap, which groups by when a record came out.",
                    "**Show results by** (under Sort) sets the order the results appear in, apart from the sorts that pick them. For “the most played album of each release year” the sort is Plays (it decides which album wins each year) and the results are shown by release year, oldest first, which is the automatic order whenever a per-release-year cap is set. Choose **The sort order** to see them ranked by plays instead, or any field (and a direction) to order them another way. It never changes which results are kept, and without a per-release-year cap the automatic order is simply the sort order.",
                    "Number fields have units: Duration is typed in minutes, Time listened in hours, and percentage-style fields as fractions (0.25 is 25%).",
                ]),
                .paragraph("**Share** (in the results header) makes an image of the results as listed, in the order shown and as many rows as you choose (up to 20), and text copies with every column. The image shows one column, the one the query sorts on unless you pick another in the preview; its title is the saved set’s name or a description of the filters (or your question, for an Ask query). It can be made only when the results have finished loading; a value still being looked up shows as “…” ([Sharing](help://screen-sharing))."),
                .paragraph("Choosing which columns to show, and in what order, is separate from the conditions. A column can carry its own date range to show two periods side by side; see [Periods and date scopes](help://query-periods)."),
            ]
        ),
        HelpArticle(
            id: "query-periods",
            title: "Query: periods, date scopes and “as of”",
            summary: "The ways a query can limit which plays count.",
            blocks: [
                .paragraph("A query can limit which plays are counted in four different ways. They do different things."),
                .table(headers: ["Setting", "Where", "Effect"], rows: [
                    ["**Period**", "Scope & limit › Only count plays in a period", "Plays outside From–To are ignored before anything is computed. “From” and “To” are both optional."],
                    ["**Certain times or weather**", "Scope & limit › Only count plays at certain times or in certain weather", "Counts only plays on the chosen weekdays, in the chosen months (in every year), within the hour range (it can wrap past midnight), in local time, and in the chosen weather. The **Winter**, **Spring**, **Summer** and **Autumn** chips pick a season’s three months for the hemisphere chosen in Settings › General › Dates; the month chips pick any months you like, such as just December for the holidays. Under **In this weather**, Rain, Snow, Fog, Storm, Clear and Cloudy keep plays made in any of the kinds you tick, and Cold, Mild and Hot (judged against your own place, see [Weather](help://screen-weather)) keep plays made at any of those; ticking both means both at once, so Snow and Cold is cold, snowy hours. Under **In this city** (once a home place is set) tick your home city or any trip city to keep only the plays made there, whatever the weather data says; a trip counts for its dates, so “my top songs in Munich” is the music from that trip. A play with no weather for its hour (weather off or not downloaded, or before the first year downloaded) never matches a weather choice."],
                    ["**As of**", "Scope & limit › Evaluate as of a date", "Sets “now” for relative fields such as “days since last played” and “last N days”. Normally the moment you run it."],
                    ["**Date scope / baseline** (per column)", "A column’s own date range", "That column is computed over its own range and ignores the Period and the days/hours filter. Comparison columns (Plays change, Rank movement) need a scope **and** a baseline; the default is the last 30 days against the same 30 days a year earlier."],
                ]),
                .heading("Kinds of date scope"),
                .bullets([
                    "All time; up to now; the last N days (N × 24 hours ending at “as of”, not calendar days).",
                    "A calendar unit — the day, week, month, quarter or year containing “as of” — from its start to its last second. The week starts on the day set in Settings › General (Monday by default). A relative scope can be shifted back by whole units.",
                    "An absolute From/To, either end optional.",
                ]),
                .callout(.note, "Fields that need history up to a point (Fading Favorites, Climb, Milestones, Turnover) are computed from the plays up to the **end** of their scope, with “now” moved to that end. That’s how you can ask for “what was fading as of last March”."),
            ]
        ),
    ])
}
