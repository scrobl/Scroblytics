import Foundation

extension HelpContent {
    static let toolsSection = HelpSection(id: "tools", title: "Tools", articles: [
        HelpArticle(
            id: "tools-overview",
            title: "Tools at a glance",
            summary: "What each tool is for and what it needs.",
            blocks: [
                .paragraph("The **Tools** tab is a searchable grid of tools grouped as Discover, Analyze, Create and Organize. Most tools have an **Advanced** button that opens the same conditions in [Query](help://query-basics), and an **Export to Apple Music** playlist button. A tool’s options are remembered."),
                .table(headers: ["Tool", "Finds or does", "Needs"], rows: [
                    ["[Most Recent, Most Often](help://tool-most-recent)", "New discoveries you play a lot", "Nothing"],
                    ["[The Climb](help://tool-climb)", "Tracks that broke into your top N", "Nothing"],
                    ["[Fading Favorites](help://tool-fading)", "Former favorites gone quiet", "Nothing"],
                    ["[Time Machine](help://tool-time-machine)", "What you played on this date in past years", "Nothing"],
                    ["[Similar Sounds](help://tool-similar-sounds)", "Music in your library like chosen seeds", "Last.fm credentials"],
                    ["[Rabbit Hole](help://tool-rabbit-hole)", "A path of recommendations from your library", "Last.fm credentials"],
                    ["[Album Turnovers](help://tool-album-turnovers)", "Albums you cycle through, and how fast", "Last.fm credentials"],
                    ["[Chart Toppers](help://tool-chart-toppers)", "The #1 per release period", "Release dates"],
                    ["[Multi-Album Tracks](help://tool-multi-album)", "Songs appearing on several albums", "Nothing"],
                    ["[Missing Data](help://tool-missing-data)", "Items lacking dates, images, lengths or a match", "Optional: Music app"],
                    ["[Flagged Tracks](help://tool-flagged)", "Your hand-picked list", "Nothing"],
                    ["[Loved Status Audit](help://tool-loved-audit)", "Last.fm loves vs Apple Music favorites", "Music app permission"],
                    ["[Library Gaps](help://tool-library-gaps)", "Scrobbled tracks missing from your Music library", "Music app permission"],
                    ["[Tag Management](help://tool-tag-management)", "Bulk add/remove Last.fm tags", "Track Actions (**writes to Last.fm**)"],
                    ["[Collage Generator](help://tool-collage)", "A shareable image of your top items", "Nothing"],
                ]),
            ]
        ),
        HelpArticle(
            id: "tool-most-recent",
            title: "Most Recent, Most Often",
            summary: "New discoveries that you play a lot.",
            blocks: [
                .paragraph("Tracks first played within a window that already have a minimum number of plays, ranked by **velocity** (plays per day since the first play) or plays. See [Most Recent, Most Often](help://metrics-velocity). Each row has a small daily-plays line, and a headline names your #1."),
            ]
        ),
        HelpArticle(
            id: "tool-climb",
            title: "The Climb",
            summary: "Tracks that rose into your all-time Top N.",
            blocks: [
                .paragraph("Choose Top N (100 to 5,000), the **Minimum plays now** guard against long-tail noise, and a limit; the window comes from the Compare control, snapped to 30, 60, 90, 180 or 365 days (a note says what it snapped to). Each row shows a rank trajectory line and “Just broke out” when the rise was recent. Full definition: [The Climb](help://metrics-climb)."),
            ]
        ),
        HelpArticle(
            id: "tool-fading",
            title: "Fading Favorites",
            summary: "Tracks that peaked and went quiet.",
            blocks: [
                .paragraph("Set the **Minimum peak** (5, 10, 20, 30, 40 or 50 plays) and sort by Biggest peak, Steepest fade or Rediscovery score. Hover a row to see the peak dates and the score arithmetic. Unlike the Overview card, the tool uses a 90-day window and the real current time. See [Fading Favorites](help://metrics-fading)."),
            ]
        ),
        HelpArticle(
            id: "tool-time-machine",
            title: "Time Machine",
            summary: "What you played on a given day, week or month across all years.",
            blocks: [
                .paragraph("Pick a **Day / Week / Month** and a date; the tool matches the same calendar day (or the same 7 days, or the same month) in every year. Filters: a Year (or All years), minimum plays, minimum years (only with All years), track set (All, Loved, Flagged), per-artist and per-album caps, and a limit. Sort by Most Played, Most Years, Recently Played, Artist or Track. Week starts on your chosen week-start day. See [On This Day](help://metrics-streaks-heatmap)."),
            ]
        ),
        HelpArticle(
            id: "tool-similar-sounds",
            title: "Similar Sounds",
            summary: "Find music in your library similar to chosen seeds.",
            blocks: [
                .paragraph("Add up to **10 seeds** (artists, albums or tracks) and click **Find Similar**. That’s the only step that contacts Last.fm (it asks for similar artists and tracks); results are limited to music already in your library and scored 0–100 ([how](help://metrics-similar)). Sort by Match score, Shuffled (with Reshuffle), Play count or Last played; cap the number of songs and per artist/album; and refine with conditions that apply only to the found pool. If you change the seeds, the list says “Seeds changed — Refresh to update the results.”"),
                .paragraph("It also opens from Ask’s “find songs similar to…” requests."),
            ]
        ),
        HelpArticle(
            id: "tool-rabbit-hole",
            title: "Rabbit Hole",
            summary: "Follow recommendations from your own library, step by step.",
            blocks: [
                .paragraph("Pick a starting track. At each step you choose one of **3 recommended tracks** from your library, never repeating tracks already on your path. Only tracks you have played are ever suggested. **Back One Step**, **New Suggestions**, **Take Steps for Me…**, **Add Track** and **Start Over** control the path. **Filters** and **Style**, above the path, are closed to save room and show a summary of what is set; click either to change it. Only the current path is exported to an Apple Music playlist."),
                .paragraph("Once the path has two tracks, **Share** (beside Export) makes an image or text of it: the tracks in order with their artists, why each was chosen (turn **Show why each track was chosen** off to leave that out), and their plays or last play ([Sharing](help://screen-sharing)). It can be a list or a **tree** (choose Layout in the preview): the tracks you took down a line, with the other tracks that were on offer at each step, dimmed, hanging beside it. Show lets the list display plays, last play, the match score or nothing, and you can type your own title. Branches you went back from aren’t shown, only the first two other tracks offered at each step."),
                .heading("Where the suggestions come from"),
                .paragraph("Each step gathers candidates from several places, merges them, and then picks three. The reason for each suggestion is shown under **Why these three** and on the card."),
                .bullets([
                    "**Last.fm similar tracks** to the current track, and, with less weight, to the two steps before it, so the choices follow where you have been.",
                    "**Similar artists**, when Last.fm knows few similar tracks for this one (many tracks have none): a few of your most-played tracks by each similar artist.",
                    "**Two steps away**: when the pool is still small, the tracks similar to the best few suggestions.",
                    "**Shared tags**: tracks by artists whose Last.fm tags overlap this track’s, where a rare tag counts for more than a common one such as “indie”. This uses data already on your Mac.",
                    "**You play it next**: tracks you have often played right after this one (within ten minutes, at least twice, not just the next track of an album). This comes only from your own history.",
                    "Small signals: a close tempo (where tempos are known), loved tracks, and favourites you have not played for a year.",
                ]),
                .heading("Starting without searching"),
                .paragraph("**Start from…** beside **Pick Starting Track** offers **What’s playing now**, **A forgotten favourite** (loved or heavily played, not played for a year), **One of my top tracks** and **Surprise me**. It tries up to four tracks and keeps the first that has at least six options to follow, so the first step is never empty."),
                .heading("Take steps for me"),
                .paragraph("Press **Take Steps for Me…** in the **Current step** panel, choose a **Length** (30, 60 or 90 minutes, or 10, 20 or 30 tracks) and press **Take Steps**. Each step follows your **Style** settings exactly as the suggestions do: **Lean toward** and **Variety** shape the three, and the step then takes one of them, favouring the closer matches when Variety is *stay close* and giving weaker ones a real chance when it is *wander*. Your **Filters** still apply. Track lengths come from the lengths the app has found (about 3½ minutes is assumed for any not found yet, and the total then says *about*). A walk stops at the length, after 40 steps, if you press **Stop**, or when it runs out of new suggestions. Every step stays in the tree with the three it chose from, so you can step back to any of them, **Remove Last Walk** (beside the note that appears afterwards) takes the walk off again, and **Create Apple Music Playlist** exports the whole path."),
                .heading("Steering and variety"),
                .paragraph("Under **Style**, **Lean toward** favours tracks you have not played for a long time (forgotten) or the loved and often-played ones (familiar). **Variety** goes from *stay close* (the best matches) to *wander* (weaker matches get a real chance). The three suggestions are chosen to differ in artist and genre, and **Avoid recent repeats** makes tracks you were shown or chose in the last week less likely to return. Your **Filters** (conditions and per-artist/album limits) still apply first, and the page says how many more options are behind the three. **New Suggestions** reuses what Last.fm already said (kept on your Mac for 30 days), so it is quick."),
            ]
        ),
        HelpArticle(
            id: "tool-album-turnovers",
            title: "Album Turnovers",
            summary: "Albums you listen all the way through, and how often.",
            blocks: [
                .paragraph("Ranks albums by completed listen-through cycles ([definition](help://metrics-turnover)). Sort by Fastest, Slowest, Most, Fewest, Most recent or Least recent turnovers. **Albums to evaluate** sets how many of your most-played albums are checked (50 to 250, or all); each needs a Last.fm tracklist lookup, so a big scan takes a while. Toggles include compilations (off by default), albums that haven’t turned over yet, and “only albums close to turnover” (one or two tracks away). An album whose match is uncertain shows a **Fix album match…** badge. An edition you counted on its own is listed as a separate album."),
            ]
        ),
        HelpArticle(
            id: "tool-chart-toppers",
            title: "Chart Toppers",
            summary: "The #1 artist, album or track for each release period.",
            blocks: [
                .paragraph("A release-date retrospective: for each release **week, month, year or decade**, the top artist, album or track by the chosen Metric, based on when the music was **released**, not when you played it. Each period expands to a top 10. Music with no known release date is left out, so resolve dates in [Missing Data](help://tool-missing-data) first. Release dates use UTC."),
            ]
        ),
        HelpArticle(
            id: "tool-multi-album",
            title: "Multi-Album Tracks",
            summary: "Songs that appear under several albums.",
            blocks: [
                .paragraph("Tracks by one artist (spellings combined) that you’ve played under more than one album name — editions, singles, compilations. **Match** is “Exact titles” or “Edition-aware”, which also joins remaster, mono/stereo and similar edition notes. Filters: related album editions only, includes a single, minimum albums. Sort by Most plays, Most albums, Most recently played or Track title. Only plays with an artist, album and track count."),
            ]
        ),
        HelpArticle(
            id: "tool-missing-data",
            title: "Missing Data",
            summary: "Find and fill in missing release dates, images, lengths, tempos and album matches, and spot editions merged by mistake.",
            blocks: [
                .paragraph("Choose a **Field** — Release Date, Images, Duration, Tempo (BPM), Album Match or Merged Editions — and a Type (artist, album, track as applicable). A coverage line reads “N of M (X%) missing”, split into confirmed missing and not yet checked. What each means: [Missing Data](help://metrics-missing-data)."),
                .bullets([
                    "**Resolve Now** re-runs the lookup for items not yet checked.",
                    "**Import from Apple Music** (durations) matches tracks against your Music library and imports only confident matches, skipping ambiguous or unavailable ones. It needs the Music permission.",
                    "Click a row to open the right editor: choose an image, edit the release date or duration, or Fix album match.",
                    "**Advanced** opens the equivalent query (confirmed missing only).",
                ]),
                .paragraph("**Merged Editions** is different: it lists album names that are counted together with other editions of their album although they have tracks of their own. Each row says how many of the tracks you played under that name aren’t on the album’s tracklist (3 or more). Click a row to open **Fix album match…** and turn on **Count this edition on its own**, or press **Keep Merged** if the merge is what you want; the row then leaves the list for good. Rows marked “Not yet checked” need their tracklist looked up (**Resolve Now**)."),
            ]
        ),
        HelpArticle(
            id: "tool-flagged",
            title: "Flagged Tracks",
            summary: "A hand-picked list of tracks.",
            blocks: [
                .paragraph("Right-click a track anywhere and choose **Flag Track**. This tool lists them with a filter, Sort (Recently Flagged, Most Played, Recently Played, Artist, Track), a “Loved only” toggle, **Remove Flag** per row, **Clear All** (asks first, cannot be undone) and export to an Apple Music playlist. Flags live only on your Mac and are included in [backups](help://data-backup). The Query field **Flagged** matches by artist and title regardless of album."),
            ]
        ),
        HelpArticle(
            id: "tool-loved-audit",
            title: "Loved Status Audit",
            summary: "Compare Last.fm loved tracks with Apple Music favorites.",
            blocks: [
                .paragraph("Reads your Music Favorites once (about a second; it needs the Music permission) and compares them with your synced Last.fm loves. It never changes Last.fm, and it changes Apple Music only when you confirm removing a favorite that isn’t in your library (see below). Filter to All, Only on Last.fm, Only on Apple Music, Uncertain, **Loved, no scrobbles**, or **Not in library**; fuzzy near-matches get an “Uncertain match” badge and are never counted as discrepancies. **Show agreement** also lists tracks that match. The confirmed Last.fm-only tracks can be exported to an Apple Music playlist. See [Loved tracks](help://metrics-loved-library)."),
                .heading("Uncertain matches: say what they are"),
                .paragraph("An Uncertain row names two spellings: the track on Last.fm and the one in Apple Music (for example “Limehouse” and “Lime House”). Look at them and choose **Same track** (count the two spellings as one song) or **Different tracks** (stop suggesting this pairing). The audit then recomputes straight away, without reading Music again, and **remembers your answer** across runs. “Same track” turns the row into an agreement, or into a confirmed Only on Last.fm / Only on Apple Music row if the song is loved on just one side. “Different tracks” makes the two a confirmed one-sided difference; if the audit then finds another near match for the same track, it offers that one for you to decide. **Decisions** (top right, once you have made some) lists them with a **Remove** button so you can change your mind. Once you have fixed a mismatch at its source (for example you renamed the track in Apple Music, or unloved the old spelling on Last.fm and loved the right one), the decision has nothing left to apply to, and the audit **removes it by itself** after the next complete run, with a note under the headline. It never removes anything after a failed or partial read, or while your first import is still running. Decisions are included in [backups](help://data-backup). Nothing here changes Last.fm or Apple Music."),
                .heading("Not in library"),
                .paragraph("Music’s Favorite Songs list can hold entries that are not tracks in your library: songs you favorited from the Apple Music catalogue without adding them (labelled “Apple Music catalogue”), and leftover entries for tracks that were later renamed or replaced (labelled “leftover entry”). Music often doesn’t show the leftovers, so you can’t un-favorite them there, and they keep appearing here as favorites with no match. The **Not in library** filter lists them (also counted in the headline). **Remove from Favorites…** on a row, or **Remove all N…** under that filter, un-favorites exactly those entries in Apple Music **after you confirm** the list. Nothing in your library changes. A leftover entry can’t be favorited again (Music doesn’t show it); a catalogue favorite can be favorited again from the song in Music. Each entry is found by Music’s own ID and left alone if its name or artist has changed since the list was read."),
                .heading("Loved, no scrobbles"),
                .paragraph("Last.fm keeps your loves as plain artist-and-title text, apart from your scrobbles. If you later edit a scrobble’s title or artist, or delete its plays, the old love stays under the old name. This filter lists every loved track whose exact artist and title no scrobble uses (editions such as “Remastered” are ignored), whatever Apple Music says about it, so you can find those stale loves. Fix one on Last.fm by unloving the old spelling and loving the right one (Profile › Library › Loved Tracks on last.fm). A “Same track” decision doesn’t change this list, because the Last.fm name still has no plays."),
            ]
        ),
        HelpArticle(
            id: "tool-library-gaps",
            title: "Library Gaps",
            summary: "Scrobbled tracks that aren’t in your Apple Music library.",
            blocks: [
                .paragraph("Lists tracks you’ve scrobbled that aren’t in your Music library, with statuses **Removed, Never in library, Unavailable, Uncertain** ([definitions](help://metrics-loved-library)). The result is saved, so reopening is instant. A track whose scrobbles were all corrected or removed on Last.fm (for example a changed artist credit, which makes it a different track) drops out of the list after the resync, and the next check also deletes its saved status; **Check library** re-reads Music (it must be running) and updates it. Sort by Most played, Last played or Artist, group by artist (each artist starts collapsed; click an artist to open it), and use **Confirm** (the check-circle button on an **Uncertain** row) when you’ve checked that the track really isn’t in your library: the near match Music has is a different recording (for example a live version next to the studio one). The track moves to **Never in library** (or **Removed**, if it was once in your library), gets the “not in your Apple Music library” mark elsewhere in the app, and stays in the list like any other track of that status. Later checks keep it there. The arrow button on a confirmed row undoes it and lists the track as Uncertain again. If a later check finds the track in your library, its confirmation is cleared, so a future removal is flagged as usual. Confirming doesn’t touch your Music library or your scrobbles. **Search in Apple Music** opens the track in Music. A small badge appears next to affected tracks elsewhere in the app. Confirmations are included in backups."),
            ]
        ),
        HelpArticle(
            id: "tool-tag-management",
            title: "Tag Management",
            summary: "Bulk add or remove your Last.fm tags — this writes to your Last.fm profile.",
            blocks: [
                .callout(.warning, "This tool changes your **public Last.fm profile**. It requires [Track Actions](help://track-actions). It always shows a full review before writing anything, and you can cancel while it applies."),
                .steps([
                    "Choose a **source**: an Apple Music playlist or a saved Query condition set (also reachable from Query results via “Tag these…”).",
                    "Choose an **action**: Add tags, Remove tags, or (playlists only) “Make tags match playlist”, which also removes the tags from tracks that left the playlist. Enter tags comma-separated; Last.fm accepts 10 per call and the app batches automatically.",
                    "Click **Review changes**. You see tags to add, tags to remove, items already done, and “N share a title with another album”.",
                    "Click **Apply to Last.fm**. Writes are paced at about three per second.",
                ]),
                .paragraph("**Why some tracks are unchecked:** Last.fm tags a track’s *title*, not an album’s copy, so a tag also lands on other versions with the same title. Those are unchecked by default; **Select likely reissues** and the optional length comparison help you decide. Saving a playlist as a **rule** lets you review and re-apply later; deleting a rule leaves tags already on Last.fm. Rules are included in backups."),
            ]
        ),
        HelpArticle(
            id: "tool-collage",
            title: "Collage Generator",
            summary: "Make a PNG collage of your top artwork.",
            blocks: [
                .paragraph("Choose a layout (3×3 up to 16×9), a source — **Top items** for a listening period, or **One per release period** (week, month, year or decade) — the content (artists, albums or tracks) and the Metric. Toggle titles, stats and period labels, zoom, then **Save PNG**, **Copy Image** (to paste into a post or message) or **Share…** (the macOS Share menu). Three more switches add a strip under the collage: **What and when** (what it shows, the period, how it is ranked and today’s date), **My Last.fm name** and **Scroblytics**. The last two are off until you turn them on and are the same switches as in the Share preview and Settings › General › Sharing. It shows how many tiles have artwork. Release-period collages bucket by release date (UTC); only music with a known release date is included."),
            ]
        ),
    ])
}
