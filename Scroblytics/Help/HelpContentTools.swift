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
                    ["[Trips](help://tool-trips)", "What you listened to while you were away", "Nothing (weather is optional)"],
                    ["[Goals](help://tool-goals)", "A deadline to hear every loved track, with a burn-down chart and forecasts", "Loved tracks from a sync"],
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
            id: "tool-trips",
            title: "Trips",
            summary: "Record where you were and when, and see what you listened to on each trip.",
            blocks: [
                .paragraph("**Trips** keeps every trip in one place and shows what you listened to on each. You don’t need weather for it: a trip is just a place and the days you were there. The headline compares your listening away with your listening at home (plays a day), and each trip row shows its plays, plays a day against your home rate, the artists you first heard there, the weather there (when [weather](help://screen-weather) is on and downloaded) and your top artists. Click a row to open exactly those plays in [Query](help://query-basics), one row for each play, where you can also filter plays by city, state or region, or country (“in Germany”, “in Illinois”), here or in [Ask](help://ask)."),
                .bullets([
                    "**I’m Away Now…** starts a trip today that stays open until you press **Back Home**. **Add a Trip…** records one for days in the past or ahead. **Edit** and **Remove** are in the menu at the end of each row; removing a trip never touches your scrobbles.",
                    "**The place.** With weather on, search for a city (the name you type goes to Open-Meteo’s search and nothing else) or pick one of the places you used before, listed A to Z. With weather off there is no search: type a name (“Grandma’s house”) and it stays on this Mac. A typed name has no coordinates, so no weather is looked up for it even when weather is on.",
                    "**Home** is optional. Without a home place chosen in Settings › Weather, the days you weren’t on a trip are simply called **Home**.",
                    "**Find a place** filters the list; the menu next to it sorts by newest, oldest, most plays, longest or place. Each place keeps one colour, the same one used in the **Where you listened** card in [Trends](help://screen-trends).",
                    "Trips that share days are highlighted in orange. For the days they share, the trip that began later is used. A day counts as a trip day when the trip covers its middle.",
                ]),
                .paragraph("Trips are stored in a small file in the Scroblytics folder and included in backups. See [Weather](help://screen-weather) for what turning weather on adds, and [What leaves your Mac](help://what-leaves-your-mac)."),
            ]
        ),
        HelpArticle(
            id: "tool-goals",
            title: "Goals",
            summary: "Set a date to hear every loved track at least once, and see what’s left and how likely you are to make it.",
            blocks: [
                .paragraph("**Goals** is for a plan such as “hear every track I’ve loved at least once by the end of the year”. The Goals page lists every goal as a card: how many of its loved tracks you’ve heard (a bar with a tick where a steady pace to the deadline would have you today), whether you’re ahead of or behind that plan, the tracks left, the days left and the pace needed, and the shape of the burn-down so far. The cards are in two lists, **Active** (running, or not started yet) and **Completed** (achieved, or past the deadline with tracks left), each with the most recently started goal first. Every card is the same size and takes the colour of where the goal stands: green when you are ahead of the plan, orange when behind, red once the deadline has passed with tracks left, grey before it starts, and **gold** with the date it was finished and how many days early once it is achieved. Click a card to open the goal’s chart and forecasts (**‹ Goals** returns to the list), use the **…** menu on a card, or right-click it, to open, edit or delete the goal, and press **New Goal…** to add one: name it and choose the first day and the deadline. By default the goal counts the tracks you have loved on Last.fm (see **Which tracks** below to count others); a track is **heard** when it has at least one play on or after the start day (plays before it don’t count, so choose **Start of year** to count from January 1). The start can also be in the future (**Next year** sets a goal for the whole of next year): until it begins nothing counts, the page says how many days remain, and the forecasts start from the first day with the tracks you’ve loved by then, including the ones you’re expected to love before it (see **Expect more loves** below). The numbers are worked out from your history each time, so they are never out of date and a goal needs no upkeep; only the goal itself (name, dates and your assumptions) is saved, in your [backups](help://data-backup). Changing an assumption recalculates the page after a moment (the cards fade and **Recalculating…** shows beside Assumptions while it works), the page recalculates after every sync, and **Refresh** does it on request."),
                .paragraph("The page shows how many you have heard and how many are left, the days left (today counts), and the **Needed** pace, which is the number of new tracks a day that finishes in a straight line if none of them repeat. The chart plots **Tracks still to hear** at the end of each day: **Actual** (a track leaves the line the day of its first play in the goal, and one you love later joins it that day, unless you had just played it), **On target** (a straight line from the loved tracks there were on the first day to none at the end of the deadline day) and the forecasts below. Hover for the numbers on a day; the buttons above the chart show or hide a line. **Still to hear** lists the tracks that remain, most recently loved first; click one to open it."),
                .paragraph("**Forecasts.** Each forecast is run 300 times with chance in it, and the chart shows the middle result as a line and the range that holds four runs in five as a band. **Your habits**: you keep listening as you have lately. Each loved track not yet heard comes up at the rate it has been coming up for you in the last 30, 60, 90 or 180 days (**Learn from the last**); a track with no plays in that time gets the rate at which tracks like it (none the window before) came back during the window. **Shuffle your favorites**: you play only the goal’s tracks, at the rate you have been playing them, each pick random, so a pick can land on one you’ve already heard. Both of these learn from how you play the tracks **in the goal**, so a goal about one artist is projected from how often you have been playing that artist, not from your listening in general. The plays a day set aside for unheard tracks (**Unplayed first** and the share you choose) are the exception: they are a share of your total plays a day. **Unplayed first**: the extreme case, where everything you play goes to a loved track you haven’t heard, each played once, before anything else, so it shows the fastest the goal could be done at your usual number of plays a day."),
                .paragraph("**Why the end is slow.** Every loved track you hear is one fewer left to find, so random picks hit a new track less and less often. With a few hundred favorites, shuffling takes about as many plays as the list is long times the natural logarithm of its length, and the last tenth alone takes roughly as long as the first nine; the page spells this out with your own numbers (“half of what’s left in about 24 days, nine tenths in about 85”). Playing the ones you haven’t heard first is the way to beat it, which is what the third forecast shows."),
                .bullets([
                    "**The table** gives, for each forecast, the day it is likely to finish (the middle run, or “not within N months”), the **chance** of finishing by the deadline, and the days by which half and nine tenths of what is left today will have been heard (they can fall after the deadline, which is how you see how far short a forecast comes up). The **chance** is the share of the 300 simulated runs that have nothing left at the end of the deadline day, so it is 0% when even the best of them still has tracks to hear.",
                    "**How much to give it.** The page works out the fewest plays a day, on top of your habits, to give to loved tracks you haven’t heard to be 90% sure of finishing by the deadline, and what share of your listening that is; it says so when even all of your listening wouldn’t do it. Tick **Choose how much…** to set the share yourself: that many plays a day then go to unheard tracks in both **Your habits** and **Shuffle your favorites** (the table notes the amount beside them), so you can see what a given effort does to each. **Unplayed first** doesn’t change, because it already puts every play there.",
                    "**New loves.** Tracks you love before the deadline join the goal. Unless you had just played one (in the week before loving it), it is a track to hear. **Expect more loves** uses how many you have been loving lately (or the number a month you type) in all three forecasts. Last.fm dates every love, and Scroblytics keeps those dates from a sync on; until the first sync after updating has saved them, every loved track counts from the first day and new loves can’t be estimated.",
                    "**Which tracks.** In the goal editor, choose **Loved** (the default), **Not loved** or **All tracks**, and narrow them to some **artists** and / or some **tags**; a track must match everything that is set. Loved goals count every track you’ve loved on Last.fm, including ones you’ve never played, and expect new loves. **Not loved** and **All tracks** count the tracks in your play history (played at least once, ever; the app can’t know songs you have never played): a track you play for the first time after the start counts as heard at once, so nothing new is ever owed, and the page leaves out the loves controls. A tag test uses the Last.fm community tags already looked up (a track’s own, or its artist’s when it has none) plus your own tags; a track with no tags looked up yet isn’t counted, and the page says how many, so Refresh once the background lookups have caught up. Big sets (thousands of tracks) take a moment longer to work out.",
                    "**Sharing.** **Share** on a goal’s page (and the share icon on its card in the list) makes an image or text of it: the chart, a sentence on where it stands, and, from the goal’s page, the forecasts. See [Sharing](help://screen-sharing).",
                    "**Set aside.** The **−** button on a row of Still to hear (or right-click › **Set Aside from This Goal**, which sits with the usual track menu: Open, Love or Flag, Resync, the artwork choices, Genius lyrics, Apple Music and Last.fm) takes that track out of the goal: it stops counting, heard or not, and the numbers, chart and forecasts follow. Use it for a duplicate, another recording of a song you’ve already heard, or anything you don’t want to chase. Set-aside tracks are listed in a **Set aside** card above the list, where **Put Back** returns one to the goal. Last.fm keeps a love as artist and title only, so the app can’t tell which release a love meant; setting aside is how you decide that yourself.",
                    "**Still to hear.** The list at the bottom shows each track still to hear with its artwork (from the track’s latest plays, or its artist when it has never been played), when you loved it, and how often you’ve played it before. **Search** finds a track or artist; **All / Played before / Never played** narrows it; and the sort menu orders it by recently or oldest loved, most played before, heard longest ago, artist or track name. Click a track to open it.",
                "**Only tracks in your Apple Music library.** Tick **Only count loved tracks that are in my Apple Music library** (when setting the goal, or under Assumptions) to leave out loved tracks that can’t be played from your library, such as ones no longer available to stream. It uses the status saved by **Check library** in [Library Gaps](help://tool-library-gaps), counting a track with a near-identical title there as in the library; a track that was never checked stays in, and a left-out track is left out whether or not you have heard it. If the library has never been checked, the page says so and nothing is left out.",
                    "**Zoom.** The menu beside the chart title shows the whole goal, the last 90, 30 or 7 days with the days ahead, or only from today to the deadline, and the scale follows what is shown.",
                    "**Loves added in bulk.** A day with 50 or more loves dated on it is an import or a sync of favorites, not someone loving tracks one at a time, and would show up as a sudden jump in what is left. Those tracks count as loved from the first day instead; the page says how many and on which days, and **Count loves added in bulk as loved from the start** turns this off. They are also left out of the rate of new loves.",
                    "A forecast is a guess from your recent habits, not a promise: it assumes you keep listening the same way, and all runs use the same random numbers, so it doesn’t jump around when you reopen the page.",
                ]),
                .paragraph("A loved track under a different spelling in your scrobbles than on Last.fm counts as not heard (the same spelling comparison [Loved Status Audit](help://tool-loved-audit) shows). Nothing here is sent anywhere."),
            ]
        ),
        HelpArticle(
            id: "tool-similar-sounds",
            title: "Similar Sounds",
            summary: "Find music in your library similar to chosen seeds.",
            blocks: [
                .paragraph("Add up to **10 seeds** (artists, albums or tracks) and click **Find Similar**. That’s the only step that contacts Last.fm (it asks for similar artists and tracks); results are music already in your library, scored 0–100 ([how](help://metrics-similar)), unless you also tick **Include new music** (below). Sort by Match score, Shuffled (with Reshuffle), Play count or Last played; cap the number of songs and per artist/album; and refine with conditions that apply only to the found pool. If you change the seeds, the list says “Seeds changed — Refresh to update the results.”"),
                .paragraph("It also opens from Ask’s “find songs similar to…” requests."),
                .heading("Include new music"),
                .paragraph("Tick **Include new music**, then **Find Similar** (or **Refresh**), to also see tracks Last.fm calls similar that you have never played. They sit in the same table, marked **New**, placed by match score among your own tracks (under Shuffled they land at random places; under Play count and Last played, which they have no value for, they come after yours). For a track seed they are the similar tracks you haven’t played; for an artist or album seed they are the best-known tracks of its closest similar artists, which means a few more Last.fm lookups. The Plays and Last played columns show a dash for them, and clicking one opens its Last.fm page in your browser. A track you have played under a slightly different title is not counted as new."),
                .paragraph("Conditions describe your own listening, so while any condition is set the new tracks are left out and the summary says how many were hidden. Songs and Per artist limits count them; Per album can’t, because a new track has no album here. **Create Apple Music Playlist** adds a new track only if it is already in your Music library."),
            ]
        ),
        HelpArticle(
            id: "tool-rabbit-hole",
            title: "Rabbit Hole",
            summary: "Follow recommendations from your own library, step by step.",
            blocks: [
                .paragraph("Pick a starting track. At each step you choose one of **3 recommended tracks** from your library, never repeating tracks already on your path. Only tracks you have played are suggested unless you turn on **New music** under Style. **Back One Step**, **New Suggestions**, **Take Steps for Me…**, **Add Track** and **Start Over** control the path. **Filters** and **Style**, above the path, are closed to save room and show a summary of what is set; click either to change it. Only the current path is exported to an Apple Music playlist."),
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
                .heading("New music"),
                .paragraph("Under **Style**, **New music** (None, A little or Half) mixes in tracks Last.fm calls similar to the current step that you have never played. **A little** makes about one pick in four new and **Half** about one in two, whatever their match scores; the rest are your own tracks, chosen as usual. New tracks are marked **New** and carry a “New to you” reason. They come from the same Last.fm answers as the other suggestions, so they cost no extra lookups, and a path can continue from one (its next suggestions then come from Last.fm alone, since you have no history with it). Your **Filters** describe your own listening, so while any condition is set new music is paused; the per-artist limit still applies (a new track has no album here, so the per-album limit can’t). A new track has no plays to show, and **Open** in its right-click menu takes you to its Last.fm page. The playlist export adds a new track only if it is already in your Music library."),
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
                .paragraph("**Editions.** For albums, editions of one album by one artist (Deluxe, Remastered, Anniversary…) count as one album, with all their plays, and are named by the plain name when you played it, otherwise by the edition you played most. An edition you chose to **Count this edition on its own** (in Fix album match…) is respected: it is its own row, with only its own plays. Its release date is still the album’s, because release dates are kept per album, so both rows appear in the same period. The same applies to the [Collage Generator](help://tool-collage)’s release-period source."),
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
                .paragraph("**From a Query.** The **Collage** button in Query’s results header (for Artists, Albums and Tracks queries) makes a collage of exactly those results: the rows in the order the query put them, each tile showing the value of the column the results are sorted by (plays, last played, release year…), in a square grid just big enough for them (change the Layout if you like; a grid holds at most 12 × 12 = 144 tiles). The caption names the query. A query broken down by year shows each row’s year as its period label. **Use Top Items Instead** leaves the query’s results and returns to the choices below, and the Back button returns to the query as you left it. A collage made this way is a snapshot of the results at that moment."),
                .paragraph("**From a saved query.** Choose the source **A saved query** and pick one of the queries you saved in Query (the **Sets** menu): the collage is made of its rows, in the order the query puts them, each tile showing the value of the column the query sorts by, with the saved query’s name in the caption. Only saved queries of Artists, Albums or Tracks are listed (a query of single plays or sessions has no picture to make); the Content and Rank by choices don’t apply, because the query decides them. Picking one sizes the grid to its rows (change the Layout if you like; a grid holds at most 12 × 12 = 144 tiles, or 144 of a longer list), and the tool remembers your choice. It runs the query afresh each time you open the tool, press **Refresh** or finish a sync, so a collage follows the query as your listening changes, and if the query reads values that are still being looked up the tool says some rows may be missing (open it in Query and press Resolve). To change what the collage shows, edit and re-save the query in Query. A query that can’t run, or has no results, is said plainly instead of showing an empty collage."),
                .paragraph("Choose a layout (3×3 up to 16×9), a source — **Top items** for a listening period, **One per release period** (week, month, year or decade), or **A saved query** — the content (artists, albums or tracks) and the Metric. Toggle titles, stats and period labels, zoom, then **Save PNG**, **Copy Image** (to paste into a post or message) or **Share…** (the macOS Share menu). Three more switches add a strip under the collage: **What and when** (what it shows, the period, how it is ranked and today’s date), **My Last.fm name** and **Scroblytics**. The **Caption** box beside them is for your own line there: type something and it appears in the strip in place of the “What and when” line (clear it to go back to that line, if it is on); like a title typed in the Share preview, it is for this collage and is not remembered, and it is kept to 200 characters, shrunk to fit on one line. The last two are off until you turn them on and are the same switches as in the Share preview and Settings › General › Sharing. It shows how many tiles have artwork. Release-period collages bucket by release date (UTC); only music with a known release date is included."),
            ]
        ),
    ])
}
