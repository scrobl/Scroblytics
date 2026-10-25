import Foundation

extension HelpContent {
    static let dataSection = HelpSection(id: "data", title: "Your data", articles: [
        HelpArticle(
            id: "data-storage",
            title: "Where your data lives",
            summary: "What is stored on your Mac, and what is and isn’t removed.",
            blocks: [
                .paragraph("Scroblytics is not sandboxed, so these are ordinary folders in your home Library (the **Library** folder is hidden in Finder; use Go › Go to Folder…)."),
                .table(headers: ["What", "Where"], rows: [
                    ["Your history and everything the app computes or caches (scrobbles, loved tracks, tags, popularity, durations, tempos, release dates, your edits, saved queries)", "`~/Library/Application Support/default.store` (with its `-shm` and `-wal` companion files)"],
                    ["Your own images and downloaded artwork", "`~/Library/Application Support/Scroblytics/CustomImages` and `…/CachedImages`"],
                    ["Hourly weather for your home place and your trips (not for a trip you only typed a name for), only if you turned on **Settings › Weather** (never in a backup: it can be downloaded again)", "`~/Library/Application Support/Scroblytics/Weather`"],
                    ["Your trips (where you were and when; they work with or without weather), only if you added any; they are in backups", "`~/Library/Application Support/Scroblytics/WeatherTrips.json`"],
                    ["Your Last.fm profile picture, only if you turned on **Include my profile picture** for shared cards", "`~/Library/Application Support/Scroblytics/ProfilePicture`"],
                    ["A small log of what the app did, for [Report a Problem](help://report-a-problem) (no music, account name or keys; the newest few hundred lines)", "`~/Library/Application Support/Scroblytics/activity.log`"],
                    ["Preferences and screen settings (date range, Ask engine choice and model names, and so on)", "The app’s preferences file"],
                    ["Last.fm credentials, Ask API keys and the GetSongBPM key", "The macOS Keychain, never in the database"],
                ]),
                .bullets([
                    "Nothing in the app **deletes your history**. Disconnecting Track Actions only removes the secret and session key from the Keychain.",
                    "Everything in the database that came from Last.fm can be rebuilt by syncing again. Things **you** created (corrections, overrides, custom images, flagged tracks, saved queries, tag rules, Library Gaps confirmations, Loved Status Audit decisions) are the part worth backing up: see [Backup and restore](help://data-backup).",
                    "To start completely fresh, quit the app and delete the database files and image folders above, and the Keychain items if you also want the credentials gone.",
                ]),
            ]
        ),
        HelpArticle(
            id: "data-backup",
            title: "Backup, restore and CSV export",
            summary: "What a backup contains, what a restore replaces, and the history export.",
            blocks: [
                .paragraph("Use the **File** menu to back up or restore Scroblytics data, or export your listening history. The command opens the Data Management window and starts the selected operation."),
                .heading("Scroblytics backup"),
                .paragraph("**File › Back Up Scroblytics Data…** writes one file (`.scroblyticsbackup`, named with the date) containing what **you created**. **File › Restore Backup…** reads one back."),
                .table(headers: ["Included", "Not included"], rows: [
                    ["Album edits (release-date overrides, custom images, match decisions and manual tracklists); track edits (duration, BPM and release-date overrides, custom images); artist and album images, as the actual image files; flagged tracks; saved queries and condition sets; liner notes; tool filter settings; Library Gaps confirmations; Loved Status Audit decisions; your weather home place and trips; Tag Management rules; the light/dark theme; the creation date, app version and Last.fm username", "Your scrobbles and the album/track/artist records themselves; loved tracks; tag, popularity, duration and release-date caches; automatically found artwork; your Last.fm credentials, shared secret, session key and Ask keys and settings; other preferences (date range, layout choices); pending milestone banners"],
                ]),
                .callout(.warning, "**Restore replaces** the covered data on this Mac: existing overrides, custom images, flagged tracks, saved queries, liner notes and tool filters are cleared before the backup is applied. Library Gaps confirmations, Loved Status Audit decisions and Tag rules are replaced only if the backup contains them. A summary is shown and you must confirm. Your listening history and Last.fm connection aren’t changed."),
                .paragraph("Listening history isn’t in a backup because it comes back by syncing from Last.fm; restore, then sync."),
                .heading("Export history as CSV"),
                .paragraph("**Export History as CSV…** writes every synced play, oldest first, as a UTF-8 file with Windows-style line endings. Columns: `artist, album, track, played_at_utc, unix_timestamp, image_url`. The time is given both as an ISO-8601 UTC timestamp and as Unix seconds so spreadsheets don’t misread it. It contains no loved status, tags, durations, play counts, or any of your edits."),
            ]
        ),
        HelpArticle(
            id: "updating",
            title: "Updating Scroblytics",
            summary: "How the app tells you a newer version exists, and how to update.",
            blocks: [
                .paragraph("Scroblytics does not update itself. Once a day, when it starts, it asks GitHub (where new versions are published) whether a newer release exists. If one does, a strip under the toolbar says so: **Scroblytics 0.9.1 is available (you have 0.9.0).**"),
                .heading("What you can do"),
                .bullets([
                    "**View Release** opens the release page in your browser. Download the new disk image there, open it and drag Scroblytics to Applications, replacing the old copy. Your data stays where it is (see [Where your data lives](help://data-storage)); nothing is lost by replacing the app.",
                    "**Skip This Version** stops announcing that version. A newer one is still announced.",
                    "The **✕** hides the strip until the next launch.",
                    "**Scroblytics › Check for Updates…** (or **Settings › General › Updates › Check Now**) asks right away and always answers: up to date, a newer version, or why it couldn’t check.",
                ]),
                .heading("Turning it off"),
                .paragraph("Switch off **Check for updates automatically** in Settings › General › Updates. The app then never asks unless you choose Check for Updates…. [Offline mode](help://offline-mode) also stops the check."),
                .heading("What is sent"),
                .paragraph("The request goes to GitHub, like opening a web page: GitHub sees your IP address and the app’s name and version. Nothing about you or your listening is sent, and nothing is downloaded or installed by the app. See [What leaves your Mac](help://what-leaves-your-mac)."),
                .callout(.tip, "To check a download, compare its SHA-256 with the checksum file attached to the release: `shasum -a 256 Scroblytics-<version>.dmg`. The app is also signed and notarized by Apple, so macOS verifies it when you open it."),
            ]
        ),
    ])
}
