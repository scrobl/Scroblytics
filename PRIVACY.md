# Scroblytics Privacy Policy

*Last updated: 11 October 2026 (version 0.9.0, beta)*

Scroblytics is a Mac app for exploring your own listening history. It runs on your Mac and keeps your data there.
**The developer of Scroblytics does not run any server for the app, does not collect your data, and has no analytics, advertising,
tracking or crash-reporting code in it.** There is no Scroblytics account.

This page explains what the app stores on your Mac and which outside services it talks to, so you can decide whether you are
comfortable with that. The same information is available inside the app under **Help › What leaves your Mac**.

## What stays on your Mac

- **Your listening history and everything the app computes from it** (scrobbles, loved tracks, tags, popularity, durations,
  tempos, release dates, your own corrections, saved queries, decisions you make in the tools) live in a database in
  `~/Library/Application Support/`. Downloaded and custom images live in folders beside it.
- **Preferences** (for example your chosen date range and which Ask engine you use) are stored in the app's macOS preferences.
- **Credentials** (your Last.fm username and API key, any Ask API key, an optional GetSongBPM key, and, if you turn on Track
  Actions, a Last.fm session key) are stored in your **macOS Keychain**, never in the database, in backups or in logs.
- **Your Music library.** With your permission the app reads your Music app through macOS's scripting interface for features
  such as matching albums, auditing loved tracks, finding gaps and exporting playlists. That information is not sent anywhere.
  The app changes Music only when you ask it to: *Create Apple Music Playlist* (which creates a playlist, or adds tracks to one
  you pick, from tracks already in your library) and the Loved Status Audit's *Remove from Favorites…* (after you confirm).
- **Shared images and text.** The Share button makes an image or text on your Mac. It contains your name only if you turn that
  on, nothing is sent anywhere by the app, and what you copy, save or send from the Share menu is your choice.
- **Backups and exports** you create are files you choose the location of. They contain your listening history and are not
  encrypted, so store them as carefully as you would any personal file. They never contain your keys.

The developer has no access to any of this.

## Outside services the app contacts

The app only contacts these services, and only the ones for features you use. Turning on **Offline mode** stops every one of them.

| Service | Why | What it receives |
| --- | --- | --- |
| **Last.fm** | Importing and updating your history, loved tracks, tags, popularity, similar music, now playing. With **Track Actions** connected: loving or unloving tracks and editing your tags (this changes your public Last.fm profile). | Your Last.fm username and the API key you registered; artist, album, track and tag names in the requests. Writes also send a session key and a signature (your shared secret is used on your Mac to sign and is never sent). |
| **Deezer** (no sign-in) | Track lengths, tempos and release dates as a fallback, artwork, popularity | Artist, album and track names as search text |
| **GetSongBPM** | Tempo, time signature and musical key | Artist and track names as search text, with a GetSongBPM key |
| **MusicBrainz** | Album release dates | Artist and album names. As MusicBrainz asks, requests identify the app and a project contact address. |
| **Image servers** (Last.fm, Deezer) | Downloading artwork | An ordinary image request (your IP address is visible to the server, as with any download) |
| **Apple's public catalogue** (`itunes.apple.com`) | *View in Apple Music*, only when you choose it | Artist, album or track name as search text |
| **GitHub** (no sign-in) | Once a day, checking whether a newer version of Scroblytics has been released. You can turn this off in Settings. | An ordinary web request: your IP address and the app's name and version (for example "Scroblytics/0.9.0"). Nothing about you or your library. The app never downloads or installs anything by itself. |
| **The Ask provider you choose** (optional) | Turning a sentence into a query | See below |

Links such as *View in Last.fm* and *View Lyrics on Genius* open in your web browser only when you click them; the browser,
not the app, then talks to that site under its own policy.

### Ask

Ask turns a sentence into filters using a language model that **you choose** in Settings.

- **Apple on-device** (the default where available) runs on your Mac and sends nothing anywhere.
- **Ollama or another server you run** receives requests at the address you set. If that is your own Mac, nothing leaves it.
- **Claude (Anthropic), OpenAI or Google Gemini** are used with **your own account and API key**. When you ask a question, that
  provider receives: your sentence, a description of the query fields, today's date and your time-zone offset, the date your history
  begins, and up to 60 of your tag names. **Your scrobbles and your results are not sent**; the query itself runs on your Mac.
  What the provider does with that is governed by its own terms and privacy policy and by your agreement with it. Scroblytics
  does not see or store your sentences anywhere except your own Mac.

## What the developer receives

Nothing, unless you send it. The app has no telemetry, no usage statistics and no crash reporter. If you choose to share
diagnostic information with Apple through macOS settings, that is between you and Apple.

To help with problems, the app keeps a small **activity log** on your Mac (the newest few hundred lines, in
`~/Library/Application Support/Scroblytics/activity.log`): when a sync started, finished or failed and why, rate-limit waits, Offline
mode changes and similar events. It records no artist, album, track, tag or question text, no Last.fm username and no keys. Nothing
reads it except you: **Help › Report a Problem…** shows it, with a summary of the app's state, and you can copy it, save it, or start an
email or a GitHub issue with it. The app never sends it by itself, and **Clear Activity Log** deletes it. A crash report macOS
writes is yours to attach or not; it names your Mac account in its file paths. If you contact the developer (below), the developer
receives what you choose to send.

## Your choices and control

- Use **Offline mode** to stop all network use.
- Remove a saved key at any time in Settings (the Keychain item is deleted). Revoke Last.fm access in your Last.fm account settings.
- To delete everything the app stores, quit it and delete its database and image folders (see **Help › Where your data lives**)
  and its Keychain items. Because the developer holds none of your data, there is nothing for the developer to delete.
- Your rights over data held by Last.fm, Deezer, GetSongBPM, MusicBrainz, Apple or your Ask provider are exercised with those
  services directly.

## Children

Scroblytics is a general-purpose tool and is not directed at children.

## Changes to this policy

If the app starts using a new outside service or collecting anything, this page will be updated first and the date above changed.
Earlier versions are available in this repository's history.

## Contact

Questions about this policy: Scroblytics@proton.me

*Scroblytics is an independent project. It is not affiliated with, endorsed by or sponsored by Apple, Last.fm, Deezer, GetSongBPM,
MusicBrainz, Anthropic, OpenAI or Google. Product and service names belong to their owners.*
