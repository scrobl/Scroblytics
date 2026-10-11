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

## What the update notice needs

The app's daily "newer version available" notice reads GitHub's release list. For a release to be announced its tag must be named
`vX.Y.Z` (for example `v0.9.1`, matching `MARKETING_VERSION`), and the release must be **published** (not a draft). Pre-releases are
announced too, while the app is in beta.

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
