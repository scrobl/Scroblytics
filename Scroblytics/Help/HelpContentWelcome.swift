import Foundation

extension HelpContent {
    static let welcomeSection = HelpSection(id: "welcome", title: "Welcome", articles: [
        HelpArticle(
            id: "welcome",
            title: "Welcome to Scroblytics",
            summary: "What the app does, and the first steps.",
            blocks: [
                .paragraph("Scroblytics keeps a private copy of your Last.fm listening history on your Mac and lets you explore it: charts and trends, milestones, a library view, a condition builder (**Query**), a plain-English **Ask** box, and a set of tools for finding, fixing and organizing music. Because the history is stored locally, almost everything works instantly and offline once it has synced."),
                .heading("Getting started"),
                .paragraph("The first time you open Scroblytics, a welcome screen walks you through these steps. You can also do them later in Settings › Sync."),
                .steps([
                    "Get your free Last.fm API key and save it with your username: [Your Last.fm account and API key](help://lastfm-account).",
                    "The first import starts by itself once your account checks out. It reads your whole history and can take a while; see [Your first import](help://first-sync). You can browse while it runs, and use the toolbar’s Sync button for later updates.",
                    "Extra details (artwork, tags, popularity, release dates) fill in over the following hours in the background; see [What happens after a sync](help://sync-after).",
                    "Optional: connect [Track Actions](help://track-actions) to love tracks and edit tags from the app, and choose an [Ask engine](help://ask-keys).",
                ]),
                .heading("Where to find things"),
                .bullets([
                    "**Help topics** are listed on the left; use the search box to find a word anywhere in Help.",
                    "The most important reference is the [Field reference](help://fields-overview): precise definitions of every value you can see, filter or sort by. [Measures & definitions](help://metrics-plays-time) explains rank, movement, milestones, turnover and the rest.",
                    "If you wonder why a number looks different on two screens, read [Names, albums and artists](help://concepts-identity) and [Dates, weeks and time zones](help://concepts-time).",
                    "No internet? Turn on [Offline mode](help://offline-mode) and everything on your Mac keeps working.",
                    "Hovering over most column headers, controls and badges shows a short explanation.",
                ]),
                .callout(.note, "Your Last.fm account stays the source of truth for your plays. The app only ever changes Last.fm when you connect Track Actions and choose to love a track or edit tags, and it tells you before it does. Everything else you create (corrections, saved queries, custom images) is stored only on your Mac; see [Backup and restore](help://data-backup)."),
            ]
        ),
    ])
}
