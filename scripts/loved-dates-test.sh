#!/bin/bash
# End to end: the loved-tracks sync keeps the date each track was loved, against the stand-in Last.fm server's "loved-dates" scenario, in an
# isolated test profile (never your real data or account).
#
#   scripts/loved-dates-test.sh
#
# The server keeps its loved list between launches; between launches the script adds or removes loves and relaunches the app (a real sync at
# launch). After each launch it reads the profile's own database and checks, against the server's own list:
#   * a first sync saves all of the loves, each with the date the server gave it;
#   * a new love found by the quick check (page 1 only) is saved with its date;
#   * loves saved without dates (as before dates were kept) get them from one full walk, and no more full walks are forced after that;
#   * an unloved track is removed.
# Build the Debug app first (see CLAUDE.md). Exits 0 only if every check passes.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
port=8812
name=lovedates
profiles=/tmp/scroblytics-profiles
home="$profiles/$name/home"
store="$home/Library/Application Support/default.store"
log="$home/Library/Application Support/Scroblytics/activity.log"
bundle="app.scroblytics.Scroblytics.profile.$name"
failures=0

pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; failures=$((failures + 1)); }

env -u SCROBLYTICS_STORE_PATH "$root/scripts/first-run-profile.sh" "$name" --reset >/dev/null 2>&1
python3 -I "$root/scripts/fake-lastfm.py" --scenario loved-dates --port "$port" >/dev/null 2>&1 &
server=$!
trap 'kill $server 2>/dev/null; wait $server 2>/dev/null; pkill -f "$profiles/$name/Scroblytics.app" 2>/dev/null; [ -n "${KEEP:-}" ] || env -u SCROBLYTICS_STORE_PATH "$root/scripts/first-run-profile.sh" "$name" --reset >/dev/null 2>&1' EXIT
for _ in $(seq 1 30); do curl -s "http://127.0.0.1:$port/__stats" >/dev/null 2>&1 && break; sleep 0.2; done

stat() { curl -s "http://127.0.0.1:$port/__stats" | python3 -I -c "import json,sys; print(json.load(sys.stdin)['$1'])"; }
sql() { sqlite3 "$store" "$1" 2>/dev/null || echo -1; }
finished() { local n; n=$(grep -c "Sync finished" "$log" 2>/dev/null); echo "${n:-0}"; }
# Core Data stores dates as seconds since 2001-01-01.
epoch_offset=978307200

# Launches the profile app, waits for its sync to finish (and a moment more for the loved-tracks sync that follows), and quits it.
launch() {
  local before; before=$(finished)
  env -u SCROBLYTICS_STORE_PATH "$root/scripts/first-run-profile.sh" "$name" \
    --env "SCROBLYTICS_LASTFM_BASE_URL=http://127.0.0.1:$port/2.0/" --env "SCROBLYTICS_PROFILE_SEED_ACCOUNT=1" >/dev/null 2>&1 &
  local runner=$!
  for _ in $(seq 1 240); do [ "$(finished)" -gt "$before" ] && break; sleep 0.5; done
  sleep 6
  pkill -f "$profiles/$name/Scroblytics.app/Contents/MacOS" 2>/dev/null
  wait "$runner" 2>/dev/null
}

loves() { sql "select count(*) from ZLOVEDTRACKENTRY"; }
dated() { sql "select count(*) from ZLOVEDTRACKENTRY where ZLOVEDAT is not null"; }
newest() { local v; v=$(sql "select max(ZLOVEDAT) from ZLOVEDTRACKENTRY"); python3 -I -c "print(int(float('$v')) + $epoch_offset)"; }
oldest() { local v; v=$(sql "select min(ZLOVEDAT) from ZLOVEDTRACKENTRY"); python3 -I -c "print(int(float('$v')) + $epoch_offset)"; }
agree() {
  local label="$1" app server
  app=$(loves); server=$(stat loved_total)
  [ "$app" = "$server" ] && pass "$label: the app has the server's $server loved tracks" || fail "$label: the app has $app loved tracks, the server $server"
  [ "$(dated)" = "$app" ] && pass "$label: every loved track has a date" || fail "$label: only $(dated) of $app have a date"
  [ "$(newest)" = "$(stat loved_newest_uts)" ] && pass "$label: the newest date is the server's" || fail "$label: newest $(newest), server $(stat loved_newest_uts)"
  [ "$(oldest)" = "$(stat loved_oldest_uts)" ] && pass "$label: the oldest date is the server's" || fail "$label: oldest $(oldest), server $(stat loved_oldest_uts)"
}

echo "== 1. first sync: three pages of loves"
launch
agree "first sync"

echo "== 2. two new loves: found on page 1"
curl -s "http://127.0.0.1:$port/__love?add=2" >/dev/null; launch
agree "new loves"

echo "== 3. loves saved without dates (as before this feature) get them from a full walk"
sqlite3 "$store" "update ZLOVEDTRACKENTRY set ZLOVEDAT = null" 2>/dev/null
defaults delete "$bundle" lovedTracksDatesBackfilled 2>/dev/null
[ "$(dated)" = "0" ] && pass "the dates were cleared" || fail "could not clear the dates ($(dated))"
launch
agree "after backfill"

echo "== 4. a love Last.fm gave no date for does not force full walks"
sqlite3 "$store" "update ZLOVEDTRACKENTRY set ZLOVEDAT = null where Z_PK in (select Z_PK from ZLOVEDTRACKENTRY limit 3)" 2>/dev/null
launch
[ "$(dated)" = "$(( $(loves) - 3 ))" ] && pass "the backfill is done, so the quick check leaves three undated loves alone" || fail "unexpected: $(dated) dated of $(loves)"

echo "== 5. an unloved track is removed"
curl -s "http://127.0.0.1:$port/__love?remove=3" >/dev/null; launch
[ "$(loves)" = "$(stat loved_total)" ] && pass "the app has the server's $(stat loved_total) loved tracks" || fail "the app has $(loves), the server $(stat loved_total)"

echo
if [ "$failures" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "$failures CHECK(S) FAILED"; fi
exit "$failures"
