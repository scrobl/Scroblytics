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
                    ["Album edits (release-date overrides, custom images, match decisions and manual tracklists); track edits (duration, BPM and release-date overrides, custom images); artist and album images, as the actual image files; flagged tracks; saved queries and condition sets; liner notes; tool filter settings; Library Gaps confirmations; Loved Status Audit decisions; Tag Management rules; the light/dark theme; the creation date, app version and Last.fm username", "Your scrobbles and the album/track/artist records themselves; loved tracks; tag, popularity, duration and release-date caches; automatically found artwork; your Last.fm credentials, shared secret, session key and Ask keys and settings; other preferences (date range, layout choices); pending milestone banners"],
                ]),
                .callout(.warning, "**Restore replaces** the covered data on this Mac: existing overrides, custom images, flagged tracks, saved queries, liner notes and tool filters are cleared before the backup is applied. Library Gaps confirmations, Loved Status Audit decisions and Tag rules are replaced only if the backup contains them. A summary is shown and you must confirm. Your listening history and Last.fm connection aren’t changed."),
                .paragraph("Listening history isn’t in a backup because it comes back by syncing from Last.fm; restore, then sync."),
                .heading("Export history as CSV"),
                .paragraph("**Export History as CSV…** writes every synced play, oldest first, as a UTF-8 file with Windows-style line endings. Columns: `artist, album, track, played_at_utc, unix_timestamp, image_url`. The time is given both as an ISO-8601 UTC timestamp and as Unix seconds so spreadsheets don’t misread it. It contains no loved status, tags, durations, play counts, or any of your edits."),
            ]
        ),
    ])
}
