#!/bin/bash
# End to end: the sync's handling of plays Last.fm adds late (dated before the newest play already here) or deletes, against the stand-in
# Last.fm server's "late-plays" scenario, in an isolated test profile (never your real data or account).
#
#   scripts/sync-recheck-test.sh
#
# One long-lived stand-in server keeps its history between launches; between launches the script injects new, late or deleted plays,
# launches the app (a real sync at launch), waits for it to finish, quits it, and then checks, from the profile's own database, the
# activity log and the server's own totals:
#   * the app's play count equals the server's, with no duplicates;
#   * late plays and recent deletions are settled by re-checking only the last days (few pages), the totals then agreeing;
#   * a deletion far back, or a late play together with an old deletion, falls back to re-checking the whole history and still ends right.
# Build the Debug app first (see CLAUDE.md). Exits 0 only if every check passes.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
port=8811
name=recheck
profiles=/tmp/scroblytics-profiles
home="$profiles/$name/home"
log="$home/Library/Application Support/Scroblytics/activity.log"
store="$home/Library/Application Support/default.store"
failures=0

pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; failures=$((failures + 1)); }

env -u SCROBLYTICS_STORE_PATH "$root/scripts/first-run-profile.sh" "$name" --reset >/dev/null 2>&1
python3 -I "$root/scripts/fake-lastfm.py" --scenario late-plays --port "$port" >/dev/null 2>&1 &
server=$!
trap 'kill $server 2>/dev/null; wait $server 2>/dev/null; pkill -f "$profiles/$name/Scroblytics.app" 2>/dev/null; env -u SCROBLYTICS_STORE_PATH "$root/scripts/first-run-profile.sh" "$name" --reset >/dev/null 2>&1' EXIT
for _ in $(seq 1 30); do curl -s "http://127.0.0.1:$port/__stats" >/dev/null 2>&1 && break; sleep 0.2; done

stat() { curl -s "http://127.0.0.1:$port/__stats" | python3 -I -c "import json,sys; print(json.load(sys.stdin)['$1'])"; }
rows() { sqlite3 "$store" "select count(*) from ZSCROBBLE" 2>/dev/null || echo -1; }
distinct_rows() { sqlite3 "$store" "select count(*) from (select distinct ZPLAYEDAT, ZARTISTNAME, ZTRACKNAME from ZSCROBBLE)" 2>/dev/null || echo -1; }
finished() { local n; n=$(grep -c "Sync finished" "$log" 2>/dev/null); echo "${n:-0}"; }
lines_since() { tail -n +"$(($1 + 1))" "$log" 2>/dev/null; }

inject() { curl -s "http://127.0.0.1:$port/__inject?$1" >/dev/null; }

# Launches the profile app, waits for its sync to finish, and quits it. Sets $new_lines to the log lines the launch wrote.
launch() {
  local before_lines before_finished pages_before
  before_lines=$( [ -f "$log" ] && wc -l < "$log" || echo 0 )
  before_finished=$(finished)
  pages_before=$(stat history_pages_served)
  env -u SCROBLYTICS_STORE_PATH "$root/scripts/first-run-profile.sh" "$name" \
    --env "SCROBLYTICS_LASTFM_BASE_URL=http://127.0.0.1:$port/2.0/" --env "SCROBLYTICS_PROFILE_SEED_ACCOUNT=1" \
    --env "SCROBLYTICS_UPDATE_FEED_URL=http://127.0.0.1:$port/repos/scrobl/Scroblytics/releases?per_page=10" >/dev/null 2>&1 &
  local runner=$!
  for _ in $(seq 1 240); do
    [ "$(finished)" -gt "$before_finished" ] && break
    sleep 0.5
  done
  sleep 1
  pkill -f "$profiles/$name/Scroblytics.app/Contents/MacOS" 2>/dev/null
  wait "$runner" 2>/dev/null
  new_lines=$(lines_since "$before_lines")
  pages_used=$(( $(stat history_pages_served) - pages_before ))
}
has() { echo "$new_lines" | grep -q -- "$1"; }
expect() { if has "$1"; then pass "$2"; else fail "$2 (no line matching: $1)"; fi; }
expect_not() { if has "$1"; then fail "$2 (found a line matching: $1)"; else pass "$2"; fi; }
expect_counts() {
  local app server dup
  app=$(rows); server=$(stat total_scrobbles); dup=$(distinct_rows)
  if [ "$app" = "$server" ]; then pass "$1: the app has exactly the server's $server plays"; else fail "$1: the app has $app plays, the server $server"; fi
  [ "$dup" = "$app" ] && pass "$1: no duplicates" || fail "$1: $dup distinct of $app plays"
}

echo "== 1. first import"
launch
expect "Sync plan: first import" "it is a first import"
expect_counts "first import"

echo "== 2. nothing changed"
launch
expect "Sync plan: quick check" "a quick check"
expect_not "re-check" "nothing is re-checked"
expect_counts "no change"

echo "== 3. five new plays"
inject "new=5"; launch
expect_not "re-checking" "new plays alone do not trigger a re-check"
expect_counts "new plays"

echo "== 4. four late plays (dated earlier than the newest)"
inject "late=4"; launch
expect "went up by 4" "the log says Last.fm's total went up by 4"
expect "found 0 new plays" "…and that the quick pass found none"
expect "Re-checking just the last" "only the recent days are re-checked"
expect "found 4 older plays" "the 4 late plays are found"
expect "totals now agree" "the totals then agree"
expect_not "Full re-check" "the whole history is NOT re-walked"
[ "$pages_used" -le 6 ] && pass "few pages were fetched ($pages_used; a whole-history walk is about 16)" || fail "$pages_used pages were fetched"
expect_counts "late plays"

echo "== 5. three plays deleted from 3 to 5 days ago"
inject "delete_recent=3"; launch
expect "went down by 3" "the log says Last.fm's total went down by 3"
expect "removed 3" "the 3 deleted plays are removed"
expect "totals now agree" "the totals then agree"
expect_not "Full re-check" "the whole history is NOT re-walked"
expect_counts "recent deletion"

echo "== 6. two plays deleted from over 25 days ago (outside the window)"
inject "delete_old=2"; launch
expect "went down by 2" "the log says Last.fm's total went down by 2"
expect "totals still differ" "the window cannot account for it"
expect "Full re-check finished" "the whole history is re-checked"
expect "removed 2" "the 2 old deletions are found and removed"
expect_counts "old deletion"

echo "== 7. two late plays together with one old deletion (net +1)"
inject "late=2&delete_old=1"; launch
expect "totals still differ" "the window finds 2 but Last.fm moved by 1, so it does not agree"
expect "Full re-check finished" "the whole history is re-checked"
expect_counts "late plus old deletion"

echo "== 8. nothing changed again"
launch
expect "Sync plan: quick check" "a quick check"
expect_not "re-check" "the baseline is right again, so nothing is re-checked"
expect_counts "settled"

echo
if [ "$failures" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "$failures CHECK(S) FAILED"; fi
exit "$failures"
