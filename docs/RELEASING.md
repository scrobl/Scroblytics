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

## The release routine

1. Set the version in both places (they must match): `MARKETING_VERSION` in `project.yml` and in the two build configurations of
   `Scroblytics.xcodeproj`. Raise `CURRENT_PROJECT_VERSION` (the build number) too. Commit.
2. Run it:

   ```bash
   scripts/release.sh
   ```

   It stops at the first problem. In order it: checks the git tree is clean and the signing identity and notary profile exist,
   runs the app's headless checks against a scratch database, archives and exports with Developer ID, verifies the app
   (signature, hardened runtime, entitlements, version, no debug hooks, no personal strings), has Apple notarize and staple it, builds
   the DMG, notarizes and staples that, and asks Gatekeeper about the finished files. The result is in `build/release/`:
   `Scroblytics-<version>.dmg`, a `.sha256` checksum and a release-notes draft.
3. **Test the DMG on a clean macOS user account** (System Settings › Users & Groups › Add User). Open it, drag the app to
   Applications, launch it, and check: no Gatekeeper warning beyond the usual "downloaded from the internet" prompt, the Welcome
   screen, adding a Last.fm account, and the Music permission prompt showing the usage text when you first use a Music feature.
4. Publish by hand: `git tag v<version>` and `git push origin v<version>`, then on GitHub create a release from that tag, attach the
   DMG and the `.sha256`, paste the notes, and link `PRIVACY.md`.

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
