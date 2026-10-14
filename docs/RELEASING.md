# Releasing Scroblytics

Scroblytics is distributed as a signed, notarized disk image (DMG) for direct download, for example from GitHub Releases. It is not
sandboxed, so it is not for the Mac App Store. One script does the whole build; it never tags, pushes or uploads anything.

## One-time setup (needs your Apple Developer account)

1. **Developer ID Application certificate.** In Xcode: Settings › Accounts › select your team › Manage Certificates › **+** ›
   *Developer ID Application*. Check it with `security find-identity -v -p codesigning` (a line starting
   `Developer ID Application:` should appear).
2. **Notarization profile.** Create an app-specific password at appleid.apple.com (Sign-In and Security › App-Specific Passwords),
   then store it once in your Keychain. Type the password into this command yourself; it is kept by macOS, not by the project:

   ```bash
   xcrun notarytool store-credentials "scroblytics-notary" --apple-id "you@example.com" --team-id "YOURTEAMID"
   ```
3. **Optional, recommended.** `Config/forbidden-terms.local` (git-ignored) holds one regular expression of words that must never ship
   (names, email addresses, library facts). The script searches the repository and the built app for it. Without the file that
   search is skipped, with a warning.
4. **Tempo-lookup key.** Public builds include the key in `Config/Secrets.xcconfig` (git-ignored; see
   `Config/Secrets.example.xcconfig`). It is readable by anyone who opens the app, so treat it as shared and revocable.

## Testing day to day (before any release)

| For | Use |
| --- | --- |
| Everyday development | Run from Xcode (Debug). It uses your real data, preferences and Keychain items. **Don't run it at the same time as an installed copy:** two copies writing to one database can corrupt it. |
| First run, failures, rate limits, anything that must not touch your real data | **Debug › Test Profiles…** (⌥⌘T), or `scripts/first-run-profile.sh`. A separate database, preferences and Keychain items, and a stand-in Last.fm server that produces errors on demand (`scripts/fake-lastfm.py --list`). |
| Quick compile check of the Release build | `xcodebuild -project Scroblytics.xcodeproj -scheme Scroblytics -configuration Release -destination 'platform=macOS' build` |
| Trying the release script and the packaging | `scripts/release.sh --test-package` (never install or publish a `TEST-` file) |

The DMG itself is tested **once per release**, as below, not for every change.

## The release routine

1. Set the version in both places (they must match): `MARKETING_VERSION` in `project.yml` and in the two build configurations of
   `Scroblytics.xcodeproj`. Raise `CURRENT_PROJECT_VERSION` (the build number) too. Write the release notes in
   `docs/release-notes/v<version>.md` (the script copies them next to the DMG). Commit.
2. Run it:

   ```bash
   scripts/release.sh
   ```

   It stops at the first problem. In order it: checks the git tree is clean and the signing identity and notary profile exist,
   runs the app's headless checks against a scratch database, archives and exports with Developer ID, verifies the app
   (signature, hardened runtime, entitlements, version, no debug hooks, no personal strings), has Apple notarize and staple it, builds
   the DMG, notarizes and staples that, and asks Gatekeeper about the finished files. The result is in `build/release/`:
   `Scroblytics-<version>.dmg`, a `.sha256` checksum and the release notes.
3. **Back up your real data before you install the new version over it.** Quit Scroblytics, then use File › Back Up Scroblytics Data…
   and also copy the database somewhere safe:

   ```bash
   mkdir -p ~/Desktop/scroblytics-db-backup && cp ~/Library/Application\ Support/default.store* ~/Desktop/scroblytics-db-backup/
   ```

   A new version opens your real database, and an older version may not be able to open one a newer version has changed. The copy lets you
   go back.
4. **Test a downloaded copy, not the file you just built.** A file downloaded from the internet carries a quarantine marker that makes
   macOS run its full Gatekeeper check; a DMG built on your own Mac does not. The way to get one before the release is public:
   - On GitHub create a **draft** release (Releases › Draft a new release). A draft is invisible to everyone else. Choose the tag name
     `v<version>`, attach the DMG and the `.sha256`, paste the notes, and **save the draft without publishing**.
   - Open the draft, download the DMG from it in your browser, and open that file.
5. **Test the upgrade over your real data** (with the backup from step 3 in place): drag the new app to Applications, replacing the old
   one, and open it. Check that your history is all there, a sync works, the Settings and Help pages open, and the new features do what
   the release notes say. Quit it again afterwards if you also use the Xcode copy.
6. **Test the first run on a clean macOS user account** (System Settings › Users & Groups › Add User), using the downloaded DMG: no
   Gatekeeper warning beyond the usual "downloaded from the internet" prompt, the Welcome screen, adding a Last.fm account, the first
   import (you can press Stop after a few minutes), and the Music permission prompt showing the usage text when you first use a Music
   feature. Once the first release is out, repeat this only when the first-run, permissions or signing changed.
7. **Publish by hand.** Create and push the tag at the commit the DMG was built from (the `git log` hash at the time of step 2, which
   may be older than `main` if only documents changed since), then publish the draft:

   ```bash
   git tag -a v<version> <build-commit> -m "Scroblytics <version> (beta)"
   git push origin v<version>
   ```

   On the draft, make sure the tag is `v<version>`, tick **Set as a pre-release** while the app is in beta, and click **Publish
   release**. Check the published page in a private browser window, and run
   `curl -s https://api.github.com/repos/scrobl/Scroblytics/releases | grep -E '"name"|download_count'` to see it listed.

If a problem turns up after step 4, fix it, raise the version and rebuild: never replace the files on a tag you have already pushed.

## Test on macOS 15 before publishing

The development Mac runs a newer macOS than many users, and a crash that only exists on macOS 15 (Swift's concurrency runtime there
behaves differently) went out in 0.9.1 because of it. Before publishing, run the release candidate on a macOS 15 machine; a virtual
machine on this Mac is enough:

1. Get **Tart** (free, https://github.com/cirruslabs/tart): download the notarized `tart.tar.gz` from its releases page (the Homebrew
   formula is unreliable), check `codesign -dv tart.app` shows Cirrus Labs, and run
   `tart clone ghcr.io/cirruslabs/macos-sequoia-vanilla:latest scroblytics-sequoia` (about 24 GB) then
   `tart run scroblytics-sequoia --no-graphics`. The guest user is `admin` / `admin`, with Remote Login on; `tart ip` gives its address.
   macOS needs **Local Network** permission for the app you run ssh from.
2. Copy the app to the VM (a DMG copied over ssh has no download marker, so Gatekeeper is not tested there) and run it. To exercise a
   real first import safely, run a copy with the test hooks (`xcodebuild -configuration Release OTHER_SWIFT_FLAGS='$(inherited) -DDEBUG'`),
   re-sign it ad hoc with a profile bundle id, and launch it with `open -n --stderr log --env CFFIXED_USER_HOME=… --env
   SCROBLYTICS_PROFILE=<name> --env SCROBLYTICS_PROFILE_SEED_LASTFM=<username>:<api key>`. That seeds a real, read-only account
   into the profile's own Keychain item. Delete the profile's Keychain item before each launch, or macOS shows a permission dialog you
   cannot see. Never put a key in the repository.
3. Pass criteria: a first import of a large library finishes, the app then runs 6 more minutes with the Overview open (artwork, tags and
   popularity all working), three relaunches of 4 minutes each survive, and `~/Library/Logs/DiagnosticReports` has no new Scroblytics
   report. Last time the crash appeared within about 2 minutes. A task group (`withTaskGroup`) started from the Overview's refresh was
   the trigger; don't reintroduce one there without this test.

4. When the test is finished, clear the test data from the VM (the imported database and the Keychain item) and shut it down: `ssh … 'sudo shutdown -h now'`, then check `tart list` shows it as `stopped`. Leave it stopped until the next release needs it.

Crash reports from users are read with `scripts/symbolicate-crash.py` (see above).

## Test with a large library

A history of 300,000+ scrobbles is where cost that grows with the library shows up (an unindexed per-item query once kept the app at
30% CPU for hours after an import). Before a release that touches background work or loads, try a big one without waiting for a big
import:

1. Copy your store (`default.store`, `-shm`, `-wal` from `~/Library/Application Support`) into a scratch folder and run
   `sqlite3 default.store "PRAGMA wal_checkpoint(TRUNCATE);"`.
2. Clone rows with shifted timestamps (`Scrobble` is one flat table, so this keeps everything consistent), for example three copies:
   `INSERT INTO ZSCROBBLE (Z_ENT,Z_OPT,ZLASTCONFIRMEDAT,ZPLAYEDAT,ZALBUMNAME,ZARTISTNAME,ZIMAGEURL,ZTRACKNAME) SELECT Z_ENT,Z_OPT,ZLASTCONFIRMEDAT,ZPLAYEDAT+7,ZALBUMNAME,ZARTISTNAME,ZIMAGEURL,ZTRACKNAME FROM ZSCROBBLE;`
   (repeat with +13, +19), then
   `UPDATE Z_PRIMARYKEY SET Z_MAX=(SELECT max(Z_PK) FROM ZSCROBBLE) WHERE Z_NAME='Scrobble';`.
3. Build "Release + test hooks" (`OTHER_SWIFT_FLAGS='$(inherited) -DDEBUG'`) and open the copy offline, never against the real account (a
   sync would "reconcile" the invented rows away):
   `open -n --env SCROBLYTICS_STORE_PATH=<copy> --env SCROBLYTICS_OFFLINE=1 Scroblytics.app`.
   Watch `ps -o %cpu,rss` and `vmmap -summary <pid> | grep footprint`: with 366k scrobbles the launch takes about 25 s of CPU and peaks
   near 1 GB of footprint, then it should sit at 0% CPU.
4. For work after an import, do a real first import in an isolated test profile (`scripts/first-run-profile.sh <name> --env
   SCROBLYTICS_PROFILE_SEED_LASTFM=<user>:<key>`, with `SCROBLYTICS_APP_PATH` set to the hooks build) and log CPU every 15 s for the
   half hour after it finishes: it should settle to a few percent. `sample <pid> 30` then names what is busy (use a Debug build for
   readable names). `SCROBLYTICS_PERF_CHECK=1` on a scratch copy times the artwork lookup against the old per-album query.

## The detail pages (Artist, Album, Track)

`SCROBLYTICS_DETAIL_CHECK=1` (in `scripts/release.sh`) checks the fact tiles, the album table's join, filters, sorts, directions and
length keys, and the turnover tiles on made-up data. Before a release that changes them:

- On a scratch copy of a library with Offline mode on, `SCROBLYTICS_DETAIL_DUMP=1` loads the three pages' models for the most-played
  track, album and artist and compares them with an independent count, checks the album table's rows and lengths against the
  duration engine, and prints how long each part of the album page takes.
- `SCROBLYTICS_LAYOUT_SNAPSHOT_DETAIL=<folder>` renders the header card and the album table offscreen at several widths, dark and light.
- By eye: open an artist, an album (one with a settled match, an uncertain one, a compilation) and a track from Top Charts, Library,
  Query and Trends; edit a release date, length and tempo; fix an album match; try the filters and the sort direction; narrow the window.

## What the update notice needs

The app's daily "newer version available" notice reads GitHub's release list. For a release to be announced its tag must be named
`vX.Y.Z` (for example `v0.9.1`, matching `MARKETING_VERSION`), and the release must be **published** (not a draft). Pre-releases are
announced too, while the app is in beta.

## When a user sends a crash report

`release.sh` keeps each release's debug symbols in `build/release/dsyms/<version>/` (back that folder up: without the exact build's dSYM a
crash report can't be read). To turn a report (`.ips`, from Console › Crash Reports or `~/Library/Logs/DiagnosticReports/`) into function
names and line numbers:

```bash
python3 -I scripts/symbolicate-crash.py ~/Downloads/Scroblytics-2026-….ips
```

It matches the report's build ID to the saved symbols, and prints the exception, the crashed thread and the first frames of the others.

Users can gather the report themselves: **Help › Report a Problem…** in the app lists their crash reports (Show in Finder), builds a
**diagnostic summary** (versions, Mac model, counts, sync state, no account name, keys or music, plus the last 60 lines of a small local
activity log) and starts a Mail draft to the project address with the report attached, or copies the summary for a GitHub issue. After
a crash the app also shows a one-line notice offering it. A summary's "Recent activity" shows the sync's last events (rate-limit
waits, failures and their reasons), which is what a crash report cannot tell you about a problem that did not crash. Nothing is
sent by the app itself (see PRIVACY.md).

## Trying the script without a certificate

`scripts/release.sh --test-package` does every step except Developer ID signing and notarization, signs with your development
certificate, and names the files `TEST-…`. It is for trying the script and the packaging. A TEST package is not distributable.

## If notarization is rejected

The script prints Apple's log. The usual causes are a missing hardened runtime or secure timestamp (the script checks both
before submitting), an unsigned nested binary, or a signing certificate that is not Developer ID Application.
`xcrun notarytool log <submission-id> --keychain-profile scroblytics-notary` shows the log again.

## Not covered here

Automatic updates (for example Sparkle), hosting `PRIVACY.md` at a public URL, and the repository's git history before it is made
public.
