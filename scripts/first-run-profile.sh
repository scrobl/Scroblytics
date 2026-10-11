#!/bin/bash
# Runs the Debug app as a brand-new user would meet it, in an isolated "test profile", without touching your real
# library, preferences or Keychain items.
#
#   scripts/first-run-profile.sh <name>                       start (or continue) the profile <name>
#   scripts/first-run-profile.sh <name> --reset               delete the profile's data, preferences and Keychain items
#   scripts/first-run-profile.sh <name> --fake <scenario>     also start a stand-in Last.fm server (see scripts/fake-lastfm.py)
#   scripts/first-run-profile.sh <name> --fake <scenario> --seed   also have the app save made-up credentials in the
#                                                            profile's own Keychain item, so it syncs from the stand-in at launch
#   scripts/first-run-profile.sh <name> --fake <scenario> --env KEY=VALUE   pass an environment variable to the app, e.g.
#                                                            SCROBLYTICS_PROFILE_AUTOCONNECT=name:key (types the account in for you)
#   scripts/first-run-profile.sh <name> --fake <scenario> --port 8800
#   scripts/first-run-profile.sh --selftest                   prove the app refuses to run a profile that isn't isolated
#
# What is separate for a profile named "t1":
#   database, images, caches   /tmp/scroblytics-profiles/t1/home/Library/...   (the process's home is redirected)
#   preferences                a copy of the app with the bundle id app.scroblytics.Scroblytics.profile.t1
#   Keychain items             services ending in ".profile.t1" (Last.fm credentials, Ask keys)
# The app stops at launch unless all three are isolated (Scroblytics/Verification/TestProfile.swift).
#
# Before and after, this prints a tamper check on your REAL data (file sizes and dates only: no contents, no secrets).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
real_prefix="app.scroblytics.Scroblytics"
profiles_root="/tmp/scroblytics-profiles"

find_app() {
  local dir
  dir="$(xcodebuild -project "$root/Scroblytics.xcodeproj" -scheme Scroblytics -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR =/ {print $2; exit}')"
  [ -n "$dir" ] && [ -d "$dir/Scroblytics.app" ] || { echo "Build the Debug app first: xcodebuild -project Scroblytics.xcodeproj -scheme Scroblytics -destination 'platform=macOS' build" >&2; exit 1; }
  echo "$dir/Scroblytics.app"
}

# Size and modification time of the real data, never contents.
real_fingerprint() {
  local support="$HOME/Library/Application Support"
  for f in "$support/default.store" "$support/default.store-wal" "$HOME/Library/Preferences/$real_prefix.plist"; do
    if [ -e "$f" ]; then stat -f "%N %z bytes, modified %Sm" -t "%Y-%m-%d %H:%M:%S" "$f"; else echo "$f (absent)"; fi
  done
  # Keychain item attributes only (no -g / -w), so no secret is read.
  for kind in lastfm ask getsongbpm; do
    security find-generic-password -s "$real_prefix.$kind" 2>/dev/null | grep -E '"mdat"|"svce"' | tr '\n' ' ' || true
    echo
  done
}

real_app_running() { pgrep -f "Build/Products/Debug/Scroblytics.app/Contents/MacOS/Scroblytics|/Applications/.*Scroblytics.app/Contents/MacOS/Scroblytics" >/dev/null 2>&1; }

if [ "${1:-}" = "--selftest" ]; then
  app="$(find_app)"
  echo "Self-test: a profile run that is NOT isolated (no redirected home, real bundle id) must be refused."
  set +e
  SCROBLYTICS_PROFILE=selftest "$app/Contents/MacOS/Scroblytics" >/tmp/scroblytics-selftest.out 2>&1
  code=$?
  set -e
  sed 's/^/  | /' /tmp/scroblytics-selftest.out | head -8
  rm -f /tmp/scroblytics-selftest.out
  if [ "$code" -eq 2 ]; then echo "PASS: the app refused to start (exit 2)."; exit 0; fi
  echo "FAIL: expected exit 2, got $code." >&2; exit 1
fi

name="${1:?usage: first-run-profile.sh <name> [--reset] [--fake <scenario>] [--port N] | --selftest}"
shift
[[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { echo "Profile names are lowercase letters, digits and hyphens." >&2; exit 1; }
reset=0; scenario=""; port=8765; seed=0; user_env=()
while [ $# -gt 0 ]; do
  case "$1" in
    --reset) reset=1 ;;
    --fake) scenario="${2:?scenario}"; shift ;;
    --port) port="${2:?port}"; shift ;;
    --seed) seed=1 ;;
    --env) user_env+=("${2:?KEY=VALUE}"); shift ;;
    *) echo "Unknown option $1" >&2; exit 1 ;;
  esac
  shift
done

profile_dir="$profiles_root/$name"
home_dir="$profile_dir/home"
bundle_id="$real_prefix.profile.$name"

if [ "$reset" -eq 1 ]; then
  rm -rf "$profile_dir"
  # Only items whose service ends in ".profile.<name>" — never the real ones.
  for kind in lastfm ask getsongbpm; do
    while security delete-generic-password -s "$real_prefix.$kind.profile.$name" >/dev/null 2>&1; do :; done
  done
  defaults delete "$bundle_id" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$bundle_id.plist"
  echo "Profile '$name' reset: data folder, preferences and its Keychain items removed."
  exit 0
fi

src_app="$(find_app)"
mkdir -p "$profile_dir" "$home_dir"
app="$profile_dir/Scroblytics.app"
rsync -a --delete "$src_app/" "$app/"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Scroblytics-$name" "$app/Contents/Info.plist" 2>/dev/null || true
codesign --force --deep --sign - "$app" >/dev/null 2>&1

fake_pid=""
cleanup() {
  if [ -n "$fake_pid" ]; then
    echo "--- stand-in Last.fm served:"
    curl -s "http://127.0.0.1:$port/__stats" || true
    echo
    kill "$fake_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

extra_env=()
if [ -n "$scenario" ]; then
  python3 -I "$root/scripts/fake-lastfm.py" --scenario "$scenario" --port "$port" &
  fake_pid=$!
  for _ in $(seq 1 30); do curl -s "http://127.0.0.1:$port/__stats" >/dev/null 2>&1 && break; sleep 0.2; done
  extra_env+=("SCROBLYTICS_LASTFM_BASE_URL=http://127.0.0.1:$port/2.0/")
fi

if [ "$seed" -eq 1 ]; then
  [ -n "$scenario" ] || { echo "--seed needs --fake (it saves made-up credentials that only the stand-in server accepts)." >&2; exit 1; }
  extra_env+=("SCROBLYTICS_PROFILE_SEED_ACCOUNT=1")
fi

[ ${#user_env[@]} -eq 0 ] || extra_env+=("${user_env[@]}")

before="$(real_fingerprint)"
echo "=== real data BEFORE ==="; echo "$before"
echo "=== starting profile '$name' (close the app window / quit it to finish) ==="
env CFFIXED_USER_HOME="$home_dir" SCROBLYTICS_PROFILE="$name" ${extra_env[@]+"${extra_env[@]}"} "$app/Contents/MacOS/Scroblytics" &
app_pid=$!

# Audit: while the profile app runs, none of its open files may be your real database or preferences.
audit_log="$profile_dir/audit.log"; : > "$audit_log"
( while kill -0 "$app_pid" 2>/dev/null; do
    lsof -p "$app_pid" 2>/dev/null | grep -E "Library/Application Support/default\.store|Library/Preferences/$real_prefix\.plist" \
      | grep -v "$profiles_root" >> "$audit_log" || true
    sleep 3
  done ) &
audit_pid=$!
disown "$audit_pid"

set +e
wait "$app_pid"
code=$?
set -e
kill "$audit_pid" 2>/dev/null || true
if [ -s "$audit_log" ]; then
  echo "AUDIT FAILED: the profile app had your REAL files open:" >&2; sort -u "$audit_log" >&2; exit 4
fi
echo "AUDIT: the profile app never opened your real database or preferences."
after="$(real_fingerprint)"
echo "=== real data AFTER ==="; echo "$after"
if [ "$before" = "$after" ]; then
  echo "TAMPER CHECK: real data unchanged."
elif real_app_running; then
  echo "TAMPER CHECK: differences found, but your real app appears to be running, which changes its own files. Compare the lists above."
else
  echo "TAMPER CHECK FAILED: your real data changed while no real app was running. Investigate before trusting this setup." >&2
  exit 3
fi
exit "$code"
