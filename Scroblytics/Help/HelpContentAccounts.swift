import Foundation

extension HelpContent {
    static let accountsSection = HelpSection(id: "accounts", title: "Accounts, keys & privacy", articles: [
        HelpArticle(
            id: "lastfm-account",
            title: "Your Last.fm account and API key",
            summary: "What to enter, where it is kept, and what it lets the app do.",
            blocks: [
                .paragraph("Scroblytics reads your listening history from Last.fm. It needs your **Last.fm username** and a **Last.fm API key**. There is no password. The app doesn’t ship with a key, so you create your own; that is free."),
                .heading("Set it up"),
                .steps([
                    "Register an API application at **last.fm/api/account/create** (any name and description). Last.fm shows you an **API key** and a **Shared secret**.",
                    "In Scroblytics open **Settings (⌘,) › Sync**, enter your username and the API key, and click **Test & Save**. The app first asks Last.fm whether the pair works. If it does, you see how many scrobbles it found, the account is saved, and the first import starts by itself. If not, nothing is saved and the message says what to fix (an unrecognised key, a misspelled username, a private profile, no connection).",
                    "Watch the import in the banner at the top. A large history takes a while (see [Sync, Full Resync, and Targeted Resync](help://sync-types)), but you can use the app while it runs.",
                ]),
                .heading("What this allows"),
                .paragraph("With just the username and API key the app can **read**: your scrobbles, loved tracks, tags, now-playing track, similar-music data, album tracklists and popularity numbers. It cannot change anything on Last.fm until you also connect [Track Actions](help://track-actions)."),
                .callout(.note, "If you have hidden your recent listening in Last.fm’s privacy settings, Last.fm may refuse to return it to the app. Check your Last.fm privacy settings if a sync reports an error."),
                .heading("Where it is stored"),
                .bullets([
                    "Your username, API key and, if you add them, the shared secret and session key are saved together as one item in the **macOS Keychain** (service `app.scroblytics.Scroblytics.lastfm`, account `credentials`). They are not stored in the app’s database, preferences or logs.",
                    "Your **username** is also recorded in the local database (with your sync progress) and in the metadata of a backup file. A [backup](help://data-backup) never contains your API key, secret or session key.",
                    "Each request to Last.fm carries your username and API key in the web address, over HTTPS. Treat the key as yours: don’t share it. Last.fm can limit or revoke a key that is misused.",
                ]),
                .heading("Things to know"),
                .bullets([
                    "**Saving a different username or API key clears write access.** The shared secret and session key are reset, so you’d need to re-enter the secret and reconnect Track Actions. Saving the same pair again keeps it.",
                    "**Remove Account…** (in the same Settings › Sync section) makes the app forget your username, API key and write access. Your synced history, loved tracks, edits and everything else stay on your Mac (see [Where your data lives](help://data-storage)), and the authorization you gave Last.fm is not revoked. You can add the account again later.",
                    "**Switching to a different Last.fm username isn’t supported.** Synced history isn’t kept separately per account, so a second account’s plays would be merged into the first’s.",
                ]),
            ]
        ),
        HelpArticle(
            id: "track-actions",
            title: "Track Actions (writing to Last.fm)",
            summary: "The optional connection that lets the app love tracks and edit your tags.",
            blocks: [
                .paragraph("**Track Actions** is the app’s write access to your Last.fm account. It enables:"),
                .bullets([
                    "**Love / Unlove Track** in the right-click menu.",
                    "Adding and removing **your own tags** on artists, albums and tracks, and the [Tag Management](help://tool-tag-management) tool.",
                ]),
                .callout(.warning, "Anything Track Actions writes changes your **public Last.fm profile**. Loves and tags are visible to others on your profile. Tag Management can change many tracks at once; it always shows a review of exactly what it will do first."),
                .heading("Connect"),
                .steps([
                    "First save your username and API key (see [Your Last.fm account](help://lastfm-account)).",
                    "In **Settings › Sync › Track Actions**, click **View my API accounts**. Copy the **Shared secret** for the application you registered (not the API key), and paste it into **API Secret**; click **Save Secret**.",
                    "Click **Connect**. Your browser opens a Last.fm page asking you to approve access.",
                    "Approve it, return to Scroblytics and click **I’ve approved access**. “Track actions are enabled” appears.",
                ]),
                .heading("What is stored and sent"),
                .bullets([
                    "The shared secret and the **session key** Last.fm returns are stored in the same Keychain item as your other credentials.",
                    "The secret is **never sent to Last.fm**. It is used on your Mac to sign each write request; Last.fm receives the signature and the session key.",
                ]),
                .heading("Disconnect"),
                .paragraph("**Disconnect Track Actions** deletes the secret and session key from your Mac. Your username and API key stay, so reading and syncing keep working. It does **not** revoke the authorization at Last.fm: to fully revoke it, remove the application in your Last.fm account settings. To reconnect you re-enter the secret."),
                .heading("If it stops working"),
                .paragraph("“Last.fm rejected the session… Reconnect Track Actions in Settings” means the session key is no longer valid (for example you revoked it, or you saved a different key or username). Connect again."),
            ]
        ),
        HelpArticle(
            id: "ask-keys",
            title: "Ask engines and their API keys",
            summary: "Which engines exist, what each sends, and where keys are kept.",
            blocks: [
                .paragraph("[Ask](help://ask) turns a sentence into filters using a language model. You choose the engine in **Settings › Ask**. In [Offline mode](help://offline-mode) the cloud engines (Claude, OpenAI, Gemini) are unavailable; Apple on-device, Ollama and a server on this Mac keep working."),
                .table(headers: ["Engine", "Where it runs", "Key"], rows: [
                    ["**Apple on-device** (default)", "On this Mac, with Apple’s own model. Needs macOS 26 or later.", "None"],
                    ["**Claude (Anthropic)**", "Anthropic’s servers", "Your Anthropic API key"],
                    ["**OpenAI**", "OpenAI’s servers", "Your OpenAI API key"],
                    ["**Google Gemini**", "Google’s servers", "Your Google API key"],
                    ["**Ollama (local)**", "The server you point at, normally this Mac", "None"],
                    ["**OpenAI-compatible server**", "The server you point at", "Optional"],
                ]),
                .heading("What a cloud engine receives"),
                .paragraph("Your sentence, the list of query fields with their descriptions, today’s date and your UTC offset, the date your history begins, and up to 60 of your **tag names**. **No scrobbles and no results are sent**; the query runs on your Mac. A sentence is capped at 2,000 characters."),
                .paragraph("Apple on-device sends nothing anywhere. Ollama sends to the address you set (private if it is on your Mac). An OpenAI-compatible server receives what a cloud provider would, so use one you trust."),
                .heading("Keys"),
                .bullets([
                    "Paste a key in Settings › Ask and click **Save**. It is stored in the macOS Keychain, one item per provider (service `app.scroblytics.Scroblytics.ask`). It is never written to settings, logs, backups or web addresses. **Remove** deletes it.",
                    "**Fetch models** asks the provider which models it offers; model names change often, so they are editable.",
                    "**Test** sends a real question and shows how long it took and how many tokens it used, and how it was read.",
                ]),
                .heading("Cost, speed and accuracy"),
                .bullets([
                    "You pay your provider for cloud use; the app doesn’t track spending. Each question carries a long instruction prompt (on the order of ten thousand tokens), which providers may cache. An account on a provider’s lowest rate-limit tier can hit its per-minute limit after a few questions; Ask then says it is being rate-limited.",
                    "Larger cloud models read requests much more accurately than the on-device model, which is private and free but often misreads, and can’t do “similar to…” requests. Settings › Ask shows the latest measured results for each provider.",
                    "Requests time out after 90 seconds. Failed requests are never silently retried.",
                ]),
            ]
        ),
        HelpArticle(
            id: "tempo-lookup",
            title: "Tempo (BPM) and its sources",
            summary: "Where a track’s tempo comes from, how to correct it, and the optional GetSongBPM key.",
            blocks: [
                .paragraph("Scroblytics shows a track’s **tempo** in beats per minute on its page, as the **BPM** and **Tempo range** columns in [Query](help://query-basics), and as a field in [Missing Data](help://metrics-missing-data). Tempos are looked up one track at a time and remembered. A track you open, or that a Query or Missing Data list asks for, is looked up first. In between, the app works slowly through your **1,500 most-played tracks** that have no tempo yet, at launch and after each sync; turn that off in **Settings › Tempo › Look up tempos in the background**. The status line shows progress, and the tempos fill in as they arrive."),
                .heading("Where it comes from"),
                .steps([
                    "**Your correction.** A tempo you enter on the track page always wins, and is included in a [backup](help://data-backup).",
                    "**GetSongBPM**, using the key built into the app (or your own, if you save one in Settings › Tempo). It also supplies a **time signature** and **key** (the Time signature and Musical key fields). A result is accepted only if its artist and title match the track, so a different artist’s song of the same name is not used.",
                    "**Deezer**, which needs no sign-in. It is the fallback when GetSongBPM has no match or can’t be used.",
                ]),
                .paragraph("When neither source has a tempo, “no value” is remembered and the track is looked up again after about three months. A lookup that fails for a temporary reason (no connection, a rate limit) is never remembered as “no value”; it is retried. GetSongBPM’s allowance (3,000 lookups an hour) is shared by every copy of the app, so each Mac looks up GetSongBPM slowly, about one track every seven seconds, so working through 1,500 tracks takes a few hours. You can quit at any time; it carries on at the next launch."),
                .heading("Correcting a tempo"),
                .paragraph("Tempo detectors often report half or double the tempo you feel. On the track page, click the pencil beside Tempo and use **÷ 2** or **× 2**, or type a value (a positive number up to 999, kept to two decimals). **Reset to Detected** removes your correction."),
                .heading("The GetSongBPM key"),
                .bullets([
                    "The app includes its own key, so nothing needs setting up. If you have a key of your own (request one at getsongbpm.com/api), paste it in **Settings › Tempo** and click **Save**; it is used instead. **Test** does one real lookup so a wrong key is reported.",
                    "Your own key is stored in the macOS Keychain (service `app.scroblytics.Scroblytics.getsongbpm`), never in settings, logs or backups. **Remove** deletes it and the built-in key is used again.",
                    "GetSongBPM’s free tier requires a credit, shown in Settings › Tempo: tempo data from GetSongBPM.com.",
                    "A key GetSongBPM refuses is skipped for the rest of the session, so tempos keep resolving from Deezer.",
                ]),
                .callout(.note, "Tempo lookups send only artist and track names as search text, and stop in [Offline mode](help://offline-mode)."),
            ]
        ),
        HelpArticle(
            id: "what-leaves-your-mac",
            title: "What leaves your Mac",
            summary: "Every outside service the app talks to, and what it is told.",
            blocks: [
                .paragraph("Everything you build in Scroblytics (history, edits, saved queries) lives on your Mac. These are the only outside services it contacts. There is no analytics or tracking. [Offline mode](help://offline-mode) stops every one of them."),
                .paragraph("The full privacy policy is published online: [Scroblytics Privacy Policy](\(AppIdentity.privacyPolicyURLString))."),
                .table(headers: ["Service", "Used for", "What it receives"], rows: [
                    ["**Last.fm** (`ws.audioscrobbler.com`)", "Sync, loved tracks, tags, now playing, similar music, tracklists, popularity; and writes if Track Actions is connected", "Your username and API key; artist, album, track and tag names in the request. Writes add a session key and signature."],
                    ["**Deezer** (`api.deezer.com`, no sign-in)", "Track lengths, tempos (fallback), release dates (fallback), artwork, popularity", "Artist, album and track names as search text"],
                    ["**GetSongBPM** (`api.getsong.co`)", "Track tempo, time signature and key", "Artist and track names as search text, with the app’s (or your own) GetSongBPM key"],
                    ["**MusicBrainz**", "Album release dates", "Artist and album name, with the project’s contact address in the request header, as MusicBrainz asks"],
                    ["**Image servers** (Last.fm, Deezer)", "Downloading artwork", "An ordinary image request"],
                    ["**Apple Music catalogue** (`itunes.apple.com`, no sign-in)", "**View in Apple Music**, only when you choose it", "Artist, album or track name as search text; the answer is the page to open in the Music app"],
                    ["**GitHub** (`api.github.com`, no sign-in)", "The daily check for a newer version of Scroblytics (turn it off in Settings › General › Updates)", "An ordinary web request: your IP address and the app’s name and version, such as “Scroblytics/0.9.0”. Nothing about you or your library."],
                    ["**Your Ask provider** (if you pick one)", "Ask", "See [Ask engines](help://ask-keys)"],
                ]),
                .heading("Things that stay on your Mac"),
                .bullets([
                    "Your **Apple Music / Music app** library. The app reads it through Music’s own scripting for Fix Album Match, Loved Status Audit, Library Gaps, importing durations, and playlist export. None of it is sent anywhere. Scroblytics changes Music only when you ask it to: **Create Apple Music Playlist** makes a playlist (or adds to one you pick) from tracks already in your library, and the Loved Status Audit’s **Remove from Favorites…** un-favorites entries that aren’t in your library, after you confirm.",
                    "Your **database, images and preferences**. See [Where your data lives](help://data-storage).",
                ]),
                .heading("The Music permission prompt"),
                .paragraph("The first time a feature reads or writes Music, macOS asks whether Scroblytics may control Music. Allow it, or enable it later in **System Settings › Privacy & Security › Automation**. Without it you’ll see “Scroblytics isn’t authorized to control Music.app”. Some features also need Music to be open (“Music isn’t open. Open Music, then try again.”)."),
                .paragraph("Links such as **View in Last.fm**, **View Lyrics on Genius**, and the Last.fm approval page open in your browser only when you choose them. **View in Apple Music** looks the item up in Apple’s public catalogue (see the table above) and opens its page in the Music app; if no page matches, or you are offline, it opens Music’s search instead."),
            ]
        ),
    ])
}
