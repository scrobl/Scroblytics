import Foundation

extension HelpContent {
    static let syncSection = HelpSection(id: "sync", title: "How syncing works", articles: [
        HelpArticle(
            id: "first-sync",
            title: "Your first import",
            summary: "What happens when you add your account, how long it takes, and what to do if it stops.",
            blocks: [
                .paragraph("The first time you add your Last.fm account, Scroblytics reads your whole listening history from Last.fm and keeps a private copy on your Mac. Importing only **reads** from Last.fm: it never changes your account or your scrobbles."),
                .heading("What happens"),
                .steps([
                    "**Test & Save** asks Last.fm whether your username and API key work together, and shows how many scrobbles it found. Only a working pair is saved ([Your Last.fm account and API key](help://lastfm-account)).",
                    "The import starts by itself. The bar at the top says “Importing your history…” with how many scrobbles are in so far and, after a few seconds, roughly how long is left.",
                    "You can use the app straight away. Overview, Top Charts and the other screens fill in as history arrives (about every 30 seconds), and a note on Overview, Top Charts and Trends says the numbers are partial until it finishes.",
                    "When it ends, a strip says how many scrobbles were imported and from which year.",
                    "Over the following hours, artwork, tags, popularity and release dates fill in quietly in the background ([What happens after a sync](help://sync-after)).",
                ]),
                .heading("How long it takes"),
                .paragraph("Last.fm hands over 200 scrobbles per request, so a history of 50,000 scrobbles is about 250 requests; the estimate in the bar firms up once the first few hundred are in. A very long history can take a good while, and Last.fm sometimes slows requests down. Nothing is lost if you wait, stop or quit."),
                .heading("If it stops"),
                .bullets([
                    "**You pressed Stop, or you quit.** Everything imported so far is kept. A strip says “Import paused”; press **Resume**, or just open the app again and it carries on where it stopped.",
                    "**“Import stopped: …” in red.** The sentence says why. **Retry** tries again from where it stopped. For a rejected or suspended API key, or a private profile, the button is **Open Settings** instead: fix the account there and the import continues.",
                    "**“Can’t reach Last.fm.”** Check your internet connection, then Retry. With no internet at all, turn on [Offline mode](help://offline-mode).",
                    "**“Last.fm is limiting requests from this connection, even after waiting several minutes.”** Last.fm kept refusing for ten minutes, so the app stopped. Wait a few minutes (longer on a shared or busy network) and press Retry; everything imported so far is kept. While it is still waiting, the top bar says “Last.fm asked the app to slow down” and carries on by itself.",
                    "**“No scrobbles on this Last.fm account yet.”** The account exists but has nothing recorded. Once you’ve listened to something and Last.fm has scrobbled it, press Sync.",
                ]),
                .callout(.tip, "Already have a Scroblytics backup? Restore it from File › Data Management. It brings back your edits, flags and saved queries; the scrobbles themselves always come from Last.fm."),
                .paragraph("Every message and strip is listed in [Sync messages and what to do](help://sync-messages). Later updates are much quicker: see [Sync, Full Resync, and Targeted Resync](help://sync-types)."),
            ]
        ),
        HelpArticle(
            id: "sync-types",
            title: "Sync, Full Resync, and Targeted Resync",
            summary: "The different ways data is brought up to date, and which ones touch Last.fm.",
            blocks: [
                .paragraph("These terms mean different things. Only some of them contact Last.fm."),
                .table(headers: ["Action", "Where", "Contacts Last.fm?", "What it does"], rows: [
                    ["**Sync**", "Toolbar button (arrows icon), or Library › Sync Now", "Yes", "Fetches plays newer than the ones you have. On the very first run, or after an interrupted full walk, it does the whole history. Also checks for backdated plays and deletions."],
                    ["**Full Resync**", "Toolbar Sync menu; Library › Full Resync", "Yes", "Re-reads your entire history from Last.fm and reconciles. Slow. It doesn’t wipe anything first."],
                    ["**Resync This Artist / Album / Track**", "Right-click an item", "Yes", "Re-checks only the times around that one item’s existing plays, to pick up edits and deletions made on Last.fm."],
                    ["**Launch sync**", "Automatic", "Yes", "A normal Sync when the app opens, if credentials are saved."],
                    ["**Now Playing**", "Automatic", "Yes (one small request)", "Checks your current track about every 15 seconds while a window is active. Never saved as a scrobble."],
                ]),
                .callout(.tip, "On a plane or without internet, turn on [Offline mode](help://offline-mode): none of the actions below contact Last.fm while it is on."),
                .callout(.note, "The app does **not** sync on a timer or when your Mac wakes. It syncs when you open it and when you click Sync. If you leave it open for days, press Sync."),
                .heading("The first sync"),
                .paragraph("With no plays stored, Sync walks your history from newest to oldest. Last.fm limits how deeply one request can page, so the walk is done in windows: each window is read until it runs out, then the next starts just before the oldest play seen. The banner at the top reads “Importing your history…” with “N of M scrobbles” and, once the pace has settled, roughly how long is left. Overview fills in as the data arrives (updated about every 30 seconds). For a later Full Resync the banner says “Full resync in progress…” and “N of M checked”."),
                .paragraph("**Stop** in the banner ends the import after the page in flight and keeps everything imported so far. A strip then says “Import paused after N scrobbles” with a **Resume** button. Progress is saved as it goes (every 10 pages and at each window), so if you quit or hit an error, the next **Sync** (or the next time you open the app) resumes where it left off (“Resuming full resync…”) instead of starting over. When the first import finishes, a strip says how many scrobbles were imported and from which year; it goes away by itself or when you dismiss it. A history so long that it needs more than 500 windows stops at that safety limit without a message; run **Sync** again to continue."),
                .heading("Normal sync"),
                .bullets([
                    "It fetches everything from one second after your newest stored play, in pages of 200.",
                    "A play is identified by its **time, artist and track** together, so two different tracks scrobbled in the same second are both kept, and a repeat of a play you already have is not added twice.",
                    "For a play you already have, an album name that changed on Last.fm is updated, and missing artwork is filled in.",
                    "The track playing right now is never stored.",
                    "The app spaces its requests to Last.fm at least a quarter of a second apart, which keeps it under Last.fm’s limit of about five requests a second.",
                    "Failed requests are retried up to 5 times, waiting 1, 2, 4 then 8 seconds, when the failure looks temporary (network trouble, or Last.fm reporting a temporary error).",
                    "If Last.fm says you are over its request limit anyway (this can happen on a shared or busy network connection), the app waits 30 seconds, then a minute at a time, for up to ten minutes, and the top bar says so. It then carries on by itself. **Stop** ends the wait at once.",
                ]),
                .heading("Change detection"),
                .paragraph("Plays added to Last.fm **in the past** (for example by another scrobbler importing old data) and plays **deleted** on Last.fm can’t be seen by “newer than my newest play”. So after each normal sync the app compares Last.fm’s total play count with what it expected. If they disagree, it automatically escalates to a full reconciliation of your history (“Change detected · Reconciling full history…”). Local plays that Last.fm no longer returns are removed."),
                .heading("Full Resync"),
                .paragraph("Use it if something looks wrong that a normal sync doesn’t fix, for example after you bulk-edited or deleted scrobbles on Last.fm. It re-reads everything, adds anything missing, refreshes album names, and deletes local plays Last.fm no longer has. Your own edits and overrides are not touched."),
                .heading("Resync This Artist / Album / Track"),
                .paragraph("A quicker, narrower fix for one item. It looks only at the time windows around that item’s existing local plays (plays more than 6 hours apart are separate windows; each is padded by a minute), re-reads them from Last.fm, adds anything missing, updates changed album names, and deletes that item’s plays that Last.fm no longer returns. It can’t find plays of the item that have no local record, so use a normal Sync for those. At most the 200 most recent windows (2,000 pages) are checked, and it says if the scan was limited. It also refreshes that item’s popularity numbers."),
            ]
        ),
        HelpArticle(
            id: "sync-after",
            title: "What happens after a sync",
            summary: "Loved tracks, banners and the background work shown in the status strip.",
            blocks: [
                .paragraph("When a sync finishes, the toolbar button does more than save plays."),
                .steps([
                    "**Loved tracks** are brought up to date. If a full check was done within the last 7 days, a quick check of the newest page is enough when it accounts for exactly the new loves. Otherwise up to 50 pages (10,000 loves) are read. Only a **complete** read can remove loves, so unloves on Last.fm appear after a full read; a failed read never removes anything.",
                    "If plays were added and this isn’t your first sync, **new milestones** and **completed album turnovers** are worked out by comparing before and after, and shown as banners on Overview until you dismiss them.",
                    "Every screen reloads from the new data.",
                    "A few seconds later the **background jobs** restart.",
                ]),
                .heading("Background jobs"),
                .paragraph("These fill in extra information one item at a time and never block the app. The strip along the top reads like “Resolving artwork and tags · 120 left”; hover for each job’s counts."),
                .table(headers: ["Job", "What it looks up", "Pace"], rows: [
                    ["**Artwork**", "Images from Deezer, falling back to the art Last.fm attached to your scrobbles", "Batches of 25"],
                    ["**Popularity**", "Last.fm and Deezer popularity for the whole library; refreshed when 30 days old", "A few items at a time, about one second apart"],
                    ["**Tags**", "Community tags per artist, album and track; your own tags (up to 500 distinct)", "A few at a time; a first pass over a big library is slow"],
                    ["**Release dates**", "MusicBrainz first, Deezer only if MusicBrainz has nothing", "One request at a time, about a second apart (MusicBrainz’s limit)"],
                    ["**Track lengths**", "Deezer, only when a screen needs them", "8 at a time"],
                    ["**Loved tracks**", "As above", ""],
                ]),
                .paragraph("A lookup that fails for a temporary reason is never remembered as “no data”; it is retried at the next launch or sync, and the strip says “N lookups couldn’t be resolved — they’ll be retried next launch”. A lookup that genuinely finds nothing is remembered, so it isn’t repeated."),
                .callout(.tip, "Because these run in the background, the first days with a large library show fewer tags, popularity marks and release dates than later. Fields that depend on them are “pending” until they arrive; see [Missing and pending](help://concepts-missing-pending)."),
            ]
        ),
        HelpArticle(
            id: "offline-mode",
            title: "Offline mode",
            summary: "Stop all network activity, for flights and bad connections, and keep working with what is on your Mac.",
            blocks: [
                .paragraph("**Offline mode** makes Scroblytics stop using the internet entirely. Nothing syncs, nothing is looked up in the background, and nothing is sent anywhere. Everything already on your Mac keeps working. It is meant for a plane, a train, or a connection that keeps dropping."),
                .heading("Switching it on and off"),
                .bullets([
                    "The **wifi button** in the toolbar (slashed and orange while offline).",
                    "**Library › Offline Mode** (⇧⌘O).",
                    "**Settings › General › Network**.",
                ]),
                .paragraph("It is **remembered when you quit**, so reopening on a plane doesn’t start a burst of failed lookups. While it is on, a strip under the toolbar says so. When your Mac looks connected again the strip says “You’re back online”; Scroblytics never switches back by itself. **Go Online** resumes the background lookups and runs a normal Sync to catch up."),
                .heading("If a connection fails"),
                .paragraph("When several lookups fail to connect in a short burst (what losing Wi-Fi looks like), Scroblytics shows **one** question, “Can’t reach the internet”, instead of many error messages. You can **Switch to Offline Mode**, choose **Not Now** (it asks again after 15 minutes if it keeps failing), or **Don’t Ask Again This Session**. A single failed request doesn’t trigger it, and a server error such as a rejected API key isn’t a connection failure."),
                .heading("What stops"),
                .bullets([
                    "Sync, Full Resync, Resync This…, the launch sync and the catch-up after loving or tagging.",
                    "Now Playing, and every background lookup: artwork, popularity, tags, release dates, track lengths and tempos.",
                    "Loving and unloving tracks, adding or removing tags, Tag Management’s Apply, and Connect Track Actions.",
                    "Similar Sounds’ Find Similar, Rabbit Hole suggestions, Missing Data’s Resolve Now, Refresh Image, and the Last.fm candidates in Fix Album Match.",
                    "Ask with Claude, OpenAI or Gemini. Ask with **Apple on-device**, **Ollama** or a **server on this Mac** keeps working (see [Ask engines](help://ask-keys)).",
                    "The daily check for a newer version of Scroblytics (see [Updating Scroblytics](help://updating)).",
                ]),
                .heading("What keeps working"),
                .paragraph("Everything that reads your Mac: Overview, Top Charts, Library, Timeline, Trends, Milestones, Search, Query, saved queries, the Tools that don’t need Last.fm, Library Gaps, Loved Status Audit and everything that uses the Music app, backup and restore, and CSV export."),
                .heading("Good to know"),
                .bullets([
                    "**Nothing is lost or wrongly marked.** Lookups paused by Offline mode stay queued and start again when you go online, and a lookup that couldn’t connect is never recorded as “nothing found”.",
                    "**Artwork:** pictures already saved on your Mac show as usual. Pictures that were only ever shown from Last.fm’s or Deezer’s servers appear as placeholders until you’re online.",
                    "**Time listened** uses the track lengths already found; tracks without one count as zero until you’re online.",
                    "**Overview cards** that rely on Last.fm (album turnovers, similar music, top tags) show what was cached, or stay empty.",
                ]),
            ],
            keywords: ["offline", "airplane", "flight", "network", "internet", "wifi", "connection"]
        ),
        HelpArticle(
            id: "stale-records",
            title: "Stale records",
            summary: "What they are and what the review sheet does.",
            blocks: [
                .paragraph("Sync only ever adds albums and tracks to your library; it never removes one when its plays go away. If a scrobble is corrected on Last.fm (a retitled album, a changed artist credit, a renamed track), the corrected plays create new entries, and anything you saved on the old entry — a match decision, a release-date, duration or BPM override, a custom image — is left stranded on it."),
                .paragraph("A **stale record** is an album or track entry that no current scrobble produces. After each sync the app looks for them. The review sheet opens by itself when there are new proposals, and you can open it any time from the toolbar Sync menu or **Library › Review Stale Records…**."),
                .heading("What it proposes"),
                .bullets([
                    "**Move** saved data from a stale entry to a likely replacement: same artist (or one credit containing the other as whole words) and a matching or contained title. Up to 5 candidates are offered when there is more than one.",
                    "Stale entries that hold saved data but have no plausible replacement are listed and left as they are.",
                    "Stale entries that hold nothing can be **removed** (the option is on by default).",
                ]),
                .paragraph("Nothing changes until you press **Apply**. Applying copies only fields the new entry doesn’t already have, drops the old values for fields it does, and deletes the old entry. Your scrobbles are never touched. **Cancel** dismisses the current set of proposals so the sheet doesn’t reopen for them."),
            ]
        ),
        HelpArticle(
            id: "sync-messages",
            title: "Sync messages and what to do",
            summary: "Common alerts and banner text.",
            blocks: [
                .table(headers: ["You see", "Meaning / what to do"], rows: [
                    ["“Set up your Last.fm account in Settings before syncing.”", "No credentials saved. See [Your Last.fm account](help://lastfm-account)."],
                    ["“Syncing scrobbles…”, “Full resync in progress…”", "Normal progress. “X total · Y new” for a normal sync; “N of M checked” for a full one."],
                    ["“Change detected · Reconciling full history…”", "Last.fm’s total differed from expected; the app is re-checking your whole history."],
                    ["“Resuming full resync…”", "A previous full walk was interrupted; it continues where it stopped."],
                    ["“Importing your history…” (top bar)", "The first import. It shows how many scrobbles are in, roughly how long is left, and a **Stop** button. You can keep using the app."],
                    ["“Import paused after N scrobbles”", "You pressed Stop, or the import was interrupted. Everything imported is kept. Press **Resume**, or just reopen the app: it carries on where it stopped."],
                    ["“Import stopped: …” (red strip)", "The first import hit a problem; the sentence says which. **Retry** tries again from where it stopped. If the key or account needs fixing (an unrecognised or suspended key, a private profile) the button is **Open Settings** instead. What was imported is kept."],
                    ["“Import complete: N scrobbles from YYYY to today”", "The first import finished. Artwork, tags and popularity fill in over the following hours (see [What happens after a sync](help://sync-after))."],
                    ["“Your history isn’t fully imported yet … these numbers are partial”", "A note at the top of Overview, Top Charts and Trends while the first import is unfinished. The figures settle when it completes."],
                    ["“Add your Last.fm account” / “Importing your history…” / “No scrobbles on this Last.fm account yet” (instead of a page’s content)", "A page has nothing to show because there is no account yet, the import hasn’t brought anything in yet, or your Last.fm account has no scrobbles. The button on the page does the next step (Open Settings, Resume or Retry, Sync)."],
                    ["“Can’t reach the internet”", "Several lookups couldn’t connect at once. Choose Switch to Offline Mode, or Not Now to keep trying. See [Offline mode](help://offline-mode)."],
                    ["“Offline mode is on. Go online to …”", "That action needs the internet. Click Go Online in the strip or toolbar."],
                    ["“Can’t read your Last.fm account from the Keychain” (a screen or a strip)", "The saved account couldn’t be read: your login keychain is locked, or access was refused. Your imported history is not affected. Unlock the keychain or choose Allow, then press Try Again. See [Your Last.fm account and API key](help://lastfm-account)."],
                    ["“Scroblytics couldn’t read your Last.fm account from the Keychain”", "A sync you asked for found the account unreadable, as above. It is not the same as “Set up your Last.fm account in Settings”, which means none is saved."],
                    ["“Sync Failed”, with a sentence", "The reason, in plain words: for example “Last.fm doesn’t recognise this API key”, “Last.fm is limiting requests from this connection…” or “Network error…”. Fix the key, wait a few minutes, or retry; progress is saved. Codes with no special wording show as “Last.fm error N: message”."],
                    ["“Resync Complete: This item is already up to date.”", "Nothing differed for that item. “N added, N updated, N removed” lists changes."],
                    ["“Couldn’t check for new milestones/album turnovers…”", "The sync worked; the follow-up check failed (often a Last.fm tracklist lookup). It is retried next time."],
                    ["“N lookups couldn’t be resolved — they’ll be retried next launch”", "Background lookups hit temporary errors; nothing to do."],
                    ["“Image Resolution Stopped”", "Artwork lookup stopped with a reason in the message; for example custom artwork must be reset before a refresh."],
                ]),
                .paragraph("Still stuck, or the app quit on you? **Help › Report a Problem…** gathers a summary, including the latest sync messages, and the crash report for you to send. See [Reporting a problem](help://report-a-problem)."),
            ]
        ),
    ])
}
