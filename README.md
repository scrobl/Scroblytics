# Scroblytics

A native Mac app for exploring and managing your [Last.fm](https://www.last.fm) listening history.

Scroblytics copies your scrobbles to your Mac and keeps them there. You can browse them, chart them over time, ask questions about
them in plain English, and tidy up the details that Last.fm itself can't. It has no account and no server of its own.

> **Beta (0.9.0).** It is usable every day but still young. Please report anything that looks wrong.

## What it does

- **Overview, Top Charts and Library.** Your most-played artists, albums and tracks for any date range, with how each moved against
  the previous period, plus the full library with artwork, tags, lengths, tempos and release dates.
- **Trends, Timeline and Milestones.** Listening over time, streaks, heatmaps, "on this day", round-number milestones, and how your taste
  has shifted.
- **Ask.** Type a request such as "my most played album from each release year" or "loved tracks I haven't played in two years". Ask shows
  how it understood the sentence, as filters you can adjust, before anything runs. It can use Apple's on-device model, or a larger model
  through your own API key (Claude, OpenAI, Gemini) or one you run yourself (for example Ollama).
- **Query.** The same engine by hand: combine about 70 fields (plays, rank movement, release year, tempo, loved status and more)
  with conditions, sorting, per-artist, per-album and per-release-year caps, and date scopes.
- **Tools.** Time Machine, Similar Sounds, Fading Favorites, The Climb, Rabbit Hole, Album Turnovers, Chart Toppers, Missing Data,
  Library Gaps, Loved Status Audit, Tag Management, a Collage Generator, and more.
- **Your own corrections.** Fix spellings, release dates, tempos and artwork on your Mac. Back them up and restore them.

Everything is explained in the app under **Help**.

## Requirements

- macOS 15 or later (Apple silicon or Intel).
- A free Last.fm API key. Last.fm gives one to each account; the app walks you through getting it on first launch. Your key and username
  stay on your Mac, in the Keychain.
- Optional: the Music app, for the features that look at your Music library. The on-device Ask model needs macOS 26 or later.

## Install

1. Download the latest `Scroblytics-<version>.dmg` from the [Releases](../../releases) page.
2. Open it and drag **Scroblytics** to **Applications**.
3. Open the app and follow the Welcome screen.

Scroblytics tells you when a newer release exists (once a day, and you can turn that off); it never updates itself, so you download
the new disk image from the Releases page the same way.

Releases are signed and notarized by Apple's process, so macOS will only ask the usual "downloaded from the internet" question the
first time. Each release also includes a SHA-256 checksum file if you want to verify the download.

## Privacy

Your history lives in a database on your Mac. The app contacts only the services it needs (Last.fm, Deezer, GetSongBPM, MusicBrainz and
the Ask provider you choose), and **Offline mode** stops all of it. There is no telemetry. Read the full policy in
[PRIVACY.md](PRIVACY.md).

## Feedback

Found a bug or have an idea? [Open an issue](../../issues), or write to Scroblytics@proton.me. Please don't paste your API keys.

## License and acknowledgements

Scroblytics is free to use but is proprietary software: see [LICENSE](LICENSE). The source is visible for reading and for reporting
problems, not for reuse.

Scroblytics is an independent project. It is not affiliated with or endorsed by Last.fm, Apple, Deezer, GetSongBPM, MusicBrainz,
Anthropic, OpenAI or Google. Listening data comes from your own Last.fm account; supplementary data comes from Deezer, MusicBrainz and
[GetSongBPM.com](https://getsongbpm.com) (tempo data).
