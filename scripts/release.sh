#!/bin/bash
# Builds a signed, notarized Scroblytics DMG for direct download. Never tags, pushes or uploads anything.
#
#   scripts/release.sh                      a full release build: Developer ID signing, notarization, a stapled DMG
#   scripts/release.sh --test-package       everything except Developer ID signing and notarization, labelled TEST, to try the
#                                           script (and the packaging) before the certificate and notary profile exist
#   options:
#     --identity "Developer ID Application: Name (TEAMID)"   which certificate to sign with (default: the one in the Keychain)
#     --notary-profile NAME                                   the notarytool Keychain profile (default: scroblytics-notary)
#     --allow-dirty                                           build even though the git tree has uncommitted changes
#     --skip-checks                                           don't build Debug and run the headless checks first
#
# One-time setup and the release routine are in docs/RELEASING.md. Output goes to build/release/.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/build/release"
work="$out/work"
scheme="Scroblytics"
project="$root/Scroblytics.xcodeproj"
entitlements="$root/Config/Scroblytics.entitlements"
forbidden_file="$root/Config/forbidden-terms.local"   # git-ignored: one regex of words that must never ship (names, emails, library facts)

test_package=0; allow_dirty=0; skip_checks=0
identity=""; notary_profile="scroblytics-notary"
while [ $# -gt 0 ]; do
  case "$1" in
    --test-package) test_package=1 ;;
    --identity) identity="$2"; shift ;;
    --notary-profile) notary_profile="$2"; shift ;;
    --allow-dirty) allow_dirty=1 ;;
    --skip-checks) skip_checks=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

step() { printf '\n== %s\n' "$*"; }
ok()   { printf '  PASS  %s\n' "$*"; }
note() { printf '  note  %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*" >&2; exit 1; }

label=""
[ "$test_package" = 1 ] && label="TEST-"

# ---------------------------------------------------------------------------------------------------------- 1. Preflight
step "Preflight"
command -v xcodebuild >/dev/null || fail "Xcode's command line tools are not installed."

settings="$(xcodebuild -project "$project" -scheme "$scheme" -configuration Release -showBuildSettings 2>/dev/null)"
version="$(printf '%s\n' "$settings" | awk -F' = ' '/^ *MARKETING_VERSION = /{print $2; exit}')"
build="$(printf '%s\n' "$settings" | awk -F' = ' '/^ *CURRENT_PROJECT_VERSION = /{print $2; exit}')"
team="$(printf '%s\n' "$settings" | awk -F' = ' '/^ *DEVELOPMENT_TEAM = /{print $2; exit}')"
[ -n "$version" ] || fail "Couldn't read MARKETING_VERSION from the project."
case "$version" in [0-9]*.[0-9]*.[0-9]*) ;; *) fail "Version \"$version\" isn't of the form 1.2.3." ;; esac
ok "version $version (build $build)"

dmg_name="${label}Scroblytics-$version.dmg"
[ ! -e "$out/$dmg_name" ] || fail "$out/$dmg_name already exists. Bump the version, or delete it if you really mean to rebuild."

if [ -n "$(git -C "$root" status --porcelain)" ]; then
  if [ "$allow_dirty" = 1 ] || [ "$test_package" = 1 ]; then warn "the git tree has uncommitted changes (allowed for this run)"
  else fail "the git tree has uncommitted changes. Commit them first (a release should be a known commit), or use --allow-dirty."; fi
else
  ok "git tree is clean at $(git -C "$root" rev-parse --short HEAD)"
fi

if [ "$test_package" = 1 ]; then
  [ -n "$identity" ] || identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
  [ -n "$identity" ] || fail "no signing identity of any kind found in the Keychain."
  note "TEST package: signing with \"$identity\"; it will NOT pass Gatekeeper on another Mac, and nothing is notarized."
else
  [ -n "$identity" ] || identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
  [ -n "$identity" ] || fail "no \"Developer ID Application\" certificate in your Keychain. Create one in Xcode > Settings > Accounts > Manage Certificates (see docs/RELEASING.md), or pass --identity."
  security find-identity -v -p codesigning | grep -qF "$identity" || fail "the identity \"$identity\" isn't in your Keychain."
  xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1 \
    || fail "no working notarization profile named \"$notary_profile\". Create it once with: xcrun notarytool store-credentials \"$notary_profile\" (see docs/RELEASING.md)."
  ok "signing identity and notary profile \"$notary_profile\" found"
fi

if [ -f "$root/Config/Secrets.xcconfig" ] && grep -Eq '^[[:space:]]*GETSONGBPM_API_KEY[[:space:]]*=[[:space:]]*[^[:space:]]' "$root/Config/Secrets.xcconfig"; then
  ok "the built-in tempo-lookup key will be included (it is readable in the shipped app)"
else
  [ "$test_package" = 1 ] && warn "Config/Secrets.xcconfig has no GetSongBPM key; this build would ship without it" \
    || fail "Config/Secrets.xcconfig is missing or has no GETSONGBPM_API_KEY. Public builds are meant to include it."
fi

forbidden=""
if [ -f "$forbidden_file" ]; then
  forbidden="$(grep -v '^[[:space:]]*#' "$forbidden_file" | grep -v '^[[:space:]]*$' | head -1)"
fi
if [ -n "$forbidden" ]; then
  hits="$(git -C "$root" grep -n -i -E "$forbidden" -- . || true)"
  [ -z "$hits" ] || { printf '%s\n' "$hits" | head -5 >&2; fail "words that must never ship were found in the repository (above)."; }
  ok "no forbidden words in the repository"
else
  warn "Config/forbidden-terms.local is missing, so the personal-information search was skipped"
fi

rm -rf "$work"; mkdir -p "$work" "$out"

# ---------------------------------------------------------------------------------------------------------- 2. Checks
if [ "$skip_checks" = 1 ]; then
  step "Headless checks"; warn "skipped (--skip-checks)"
else
  step "Headless checks (Debug build, scratch database)"
  xcodebuild -project "$project" -scheme "$scheme" -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath "$work/debug" build >"$work/debug-build.log" 2>&1 || { tail -20 "$work/debug-build.log" >&2; fail "the Debug build failed."; }
  debug_bin="$work/debug/Build/Products/Debug/Scroblytics.app/Contents/MacOS/Scroblytics"
  for check in HELP_CHECK HELP_CLAIMS PROFILE_CHECK FIRSTRUN_CHECK LOVEDAUDIT_CHECK MUSICLINK_CHECK QUERYCAP_CHECK; do
    if env "SCROBLYTICS_STORE_PATH=$work/check.store" "SCROBLYTICS_$check=1" perl -e 'alarm 300; exec @ARGV' "$debug_bin" >"$work/$check.log" 2>&1; then
      ok "$check"
    else
      grep -E "FAIL" "$work/$check.log" | head -5 >&2 || true
      fail "$check failed (full output: $work/$check.log)"
    fi
  done
fi

# ---------------------------------------------------------------------------------------------------------- 3. Archive and export
step "Archive and export"
archive="$work/Scroblytics.xcarchive"
xcodebuild -project "$project" -scheme "$scheme" -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$archive" archive >"$work/archive.log" 2>&1 || { tail -25 "$work/archive.log" >&2; fail "the archive failed."; }
ok "archived"

app="$work/export/Scroblytics.app"
mkdir -p "$work/export"
if [ "$test_package" = 1 ]; then
  # No Developer ID: take the app from the archive and re-sign it the way an export would (hardened runtime, only the
  # entitlements the app declares), so the same checks apply.
  ditto "$archive/Products/Applications/Scroblytics.app" "$app"
  codesign --force --options runtime --entitlements "$entitlements" --sign "$identity" "$app" >/dev/null 2>&1 || fail "signing the TEST app failed."
  ok "TEST app signed with \"$identity\""
else
  options="$work/ExportOptions.plist"
  sed "s/__TEAM__/$team/" "$root/Config/ExportOptions.plist" >"$options"
  xcodebuild -exportArchive -archivePath "$archive" -exportPath "$work/export" -exportOptionsPlist "$options" >"$work/export.log" 2>&1 \
    || { tail -25 "$work/export.log" >&2; fail "exporting with Developer ID failed."; }
  ok "exported with Developer ID"
fi
[ -d "$app" ] || fail "the exported app is missing."

# ---------------------------------------------------------------------------------------------------------- 4. Verify the app
verify_app() {
  local app="$1" info="$1/Contents/Info.plist" bin="$1/Contents/MacOS/Scroblytics" details ents
  codesign --verify --deep --strict "$app" >/dev/null 2>&1 && ok "signature is valid" || fail "codesign --verify failed."
  details="$(codesign -dvv "$app" 2>&1)"
  printf '%s\n' "$details" | grep -q "flags=0x[0-9a-f]*(runtime)" && ok "hardened runtime is on" || fail "hardened runtime is off."
  if [ "$test_package" = 1 ]; then
    printf '%s\n' "$details" | grep -q "Authority=Apple Development" && ok "signed by an Apple Development certificate (TEST)" || fail "unexpected signer."
  else
    printf '%s\n' "$details" | grep -q "Authority=Developer ID Application" && ok "signed by a Developer ID Application certificate" || fail "not signed by Developer ID Application."
    printf '%s\n' "$details" | grep -q "^Timestamp=" && ok "has a secure timestamp" || fail "no secure timestamp."
  fi
  ents="$(codesign -d --entitlements :- "$app" 2>/dev/null)"
  printf '%s\n' "$ents" | grep -q "com.apple.security.automation.apple-events" && ok "has the Apple Events entitlement" || fail "the Apple Events entitlement is missing."
  printf '%s\n' "$ents" | grep -q "get-task-allow" && fail "still has get-task-allow (a debuggable build)." || ok "no get-task-allow"
  [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$info")" = "$version" ] && ok "bundle version is $version" || fail "bundle version doesn't match $version."
  [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$info")" = "$build" ] && ok "build number is $build" || fail "build number doesn't match $build."
  [ -n "$(/usr/libexec/PlistBuddy -c 'Print NSAppleEventsUsageDescription' "$info" 2>/dev/null)" ] && ok "Music usage description present" || fail "NSAppleEventsUsageDescription is missing."
  if [ -n "$(/usr/libexec/PlistBuddy -c 'Print GetSongBPMAPIKey' "$info" 2>/dev/null)" ]; then ok "tempo-lookup key included"
  else [ "$test_package" = 1 ] && warn "no tempo-lookup key in this build" || fail "the tempo-lookup key is empty in this build."; fi
  strings -a "$bin" >"$work/binary-strings.txt"
  if grep -q -E "SCROBLYTICS_[A-Z_]+" "$work/binary-strings.txt"; then
    grep -o -E "SCROBLYTICS_[A-Z_]+" "$work/binary-strings.txt" | sort -u | head -5 >&2
    fail "debug hooks are present in the binary (above)."
  fi
  ok "no debug hooks in the binary"
  if grep -q -E "/Users/[A-Za-z]" "$work/binary-strings.txt"; then
    grep -E "/Users/[A-Za-z]" "$work/binary-strings.txt" | head -3 >&2
    fail "a home-folder path is embedded in the binary (above)."
  fi
  ok "no home-folder paths in the binary"
  if [ -n "$forbidden" ]; then
    if grep -q -i -E "$forbidden" "$work/binary-strings.txt"; then fail "forbidden words are embedded in the binary."; fi
    ok "no forbidden words in the binary"
  fi
  note "architectures: $(lipo -archs "$bin" 2>/dev/null || echo unknown)"
}
step "Verify the app"
verify_app "$app"

# ---------------------------------------------------------------------------------------------------------- 5. Notarize the app
notarize() {
  local file="$1" result id
  result="$(xcrun notarytool submit "$file" --keychain-profile "$notary_profile" --wait 2>&1)" || true
  printf '%s\n' "$result" | sed 's/^/    /'
  if ! printf '%s\n' "$result" | grep -q "status: Accepted"; then
    id="$(printf '%s\n' "$result" | awk '/^ *id:/{print $2; exit}')"
    [ -z "$id" ] || xcrun notarytool log "$id" --keychain-profile "$notary_profile" 2>&1 | head -60 >&2
    fail "Apple did not accept $(basename "$file") (the log is above; docs/RELEASING.md explains the usual causes)."
  fi
}
if [ "$test_package" = 0 ]; then
  step "Notarize the app"
  ditto -c -k --keepParent "$app" "$work/Scroblytics-app.zip"
  notarize "$work/Scroblytics-app.zip"
  xcrun stapler staple "$app" >/dev/null 2>&1 || fail "stapling the app failed."
  xcrun stapler validate "$app" >/dev/null 2>&1 && ok "app accepted and stapled" || fail "the stapled ticket doesn't validate."
fi

# ---------------------------------------------------------------------------------------------------------- 6. DMG
step "Build the DMG"
stage="$work/dmg"
rm -rf "$stage"; mkdir -p "$stage"
ditto "$app" "$stage/Scroblytics.app"
ln -s /Applications "$stage/Applications"
dmg="$out/$dmg_name"
hdiutil create -volname "Scroblytics $version" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null 2>&1 || fail "hdiutil couldn't create the disk image."
if [ "$test_package" = 1 ]; then
  codesign --force --sign "$identity" "$dmg" >/dev/null 2>&1 || fail "signing the TEST disk image failed."
else
  codesign --force --sign "$identity" --timestamp "$dmg" >/dev/null 2>&1 || fail "signing the disk image failed."
fi
ok "created $dmg_name"

if [ "$test_package" = 0 ]; then
  step "Notarize the DMG"
  notarize "$dmg"
  xcrun stapler staple "$dmg" >/dev/null 2>&1 || fail "stapling the disk image failed."
  xcrun stapler validate "$dmg" >/dev/null 2>&1 && ok "disk image accepted and stapled" || fail "the stapled ticket on the disk image doesn't validate."
fi

# ---------------------------------------------------------------------------------------------------------- 7. Final checks on the finished file
step "Check the finished disk image"
mount="$work/mount"
mkdir -p "$mount"
hdiutil attach -readonly -nobrowse -noverify -mountpoint "$mount" "$dmg" >/dev/null 2>&1 || fail "couldn't mount the finished disk image."
cleanup() { hdiutil detach "$mount" >/dev/null 2>&1 || hdiutil detach -force "$mount" >/dev/null 2>&1 || true; }
trap cleanup EXIT
[ -d "$mount/Scroblytics.app" ] && [ -L "$mount/Applications" ] && ok "contains Scroblytics.app and an Applications shortcut" || fail "the disk image's contents are wrong."
if [ "$test_package" = 0 ]; then
  verdict="$(spctl -a -vv "$mount/Scroblytics.app" 2>&1 || true)"
  printf '%s\n' "$verdict" | grep -q "source=Notarized Developer ID" && ok "Gatekeeper: app accepted, Notarized Developer ID" || { printf '%s\n' "$verdict" >&2; fail "Gatekeeper doesn't accept the app inside the disk image."; }
  verdict="$(spctl -a -t open --context context:primary-signature -vv "$dmg" 2>&1 || true)"
  printf '%s\n' "$verdict" | grep -q "source=Notarized Developer ID" && ok "Gatekeeper: disk image accepted, Notarized Developer ID" || { printf '%s\n' "$verdict" >&2; fail "Gatekeeper doesn't accept the disk image."; }
else
  note "Gatekeeper is not asked about a TEST package (it would be rejected)."
fi
cleanup; trap - EXIT

(cd "$out" && shasum -a 256 "$dmg_name" >"$dmg_name.sha256")
ok "checksum written: $dmg_name.sha256"

# ---------------------------------------------------------------------------------------------------------- 8. What's left for a person
notes="$out/${label}RELEASE_NOTES-$version.md"
last_tag="$(git -C "$root" describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
written_notes="$root/docs/release-notes/v$version.md"
if [ -f "$written_notes" ]; then
  cp "$written_notes" "$notes"
  ok "release notes: using docs/release-notes/v$version.md"
else
  warn "no docs/release-notes/v$version.md; the notes below are only a list of commit subjects"
{
  echo "# Scroblytics $version"
  echo
  echo "Changes since ${last_tag:-the beginning}:"
  echo
  git -C "$root" log --pretty='- %s' ${last_tag:+"$last_tag..HEAD"}
} >"$notes"
fi
# Early commit subjects can mention things that must never be published; they are left out of the draft.
if [ -n "$forbidden" ] && grep -q -i -E "$forbidden" "$notes"; then
  dropped="$(grep -c -i -E "$forbidden" "$notes")"
  grep -v -i -E "$forbidden" "$notes" >"$notes.clean" && mv "$notes.clean" "$notes"
  warn "$dropped commit subject(s) containing forbidden words were left out of the release-notes draft"
fi

printf '\n== Done: %s\n' "$out/$dmg_name"
printf '   %s\n' "$out/$dmg_name.sha256" "$notes"
if [ "$test_package" = 1 ]; then
  printf '\nThis was a TEST package: not signed for distribution and not notarized. Do not publish it.\n'
else
  cat <<EOF

Nothing has been tagged, pushed or uploaded. To publish it yourself:
  1. Test the disk image on a clean macOS user account (docs/RELEASING.md has the list).
  2. git tag v$version && git push origin v$version          (only when you are ready)
  3. On GitHub: Releases > Draft a new release > choose v$version, attach $dmg_name and $dmg_name.sha256,
     paste the notes from RELEASE_NOTES-$version.md, and link PRIVACY.md.
EOF
fi
