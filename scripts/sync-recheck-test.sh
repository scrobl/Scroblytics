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
#   * a difference the window cannot settle (a deletion far back, or a late play together with one) is not walked automatically: the sync
#     finishes and asks. Left unanswered, or "Skip for now", it asks again at the next sync; "Ignore" accepts the difference (the app then
#     keeps the plays Last.fm no longer has) and stops asking; "Check now" walks the whole history and the counts agree again.
#   The choice is made by the app itself a moment after the prompt appears, from SCROBLYTICS_RECHECK_CHOICE (Debug builds only).
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
# KEEP=1 leaves the profile behind afterwards, to read its activity log.
trap 'kill $server 2>/dev/null; wait $server 2>/dev/null; pkill -f "$profiles/$name/Scroblytics.app" 2>/dev/null; [ -n "${KEEP:-}" ] || env -u SCROBLYTICS_STORE_PATH "$root/scripts/first-run-profile.sh" "$name" --reset >/dev/null 2>&1' EXIT
for _ in $(seq 1 30); do curl -s "http://127.0.0.1:$port/__stats" >/dev/null 2>&1 && break; sleep 0.2; done

stat() { curl -s "http://127.0.0.1:$port/__stats" | python3 -I -c "import json,sys; print(json.load(sys.stdin)['$1'])"; }
rows() { sqlite3 "$store" "select count(*) from ZSCROBBLE" 2>/dev/null || echo -1; }
distinct_rows() { sqlite3 "$store" "select count(*) from (select distinct ZPLAYEDAT, ZARTISTNAME, ZTRACKNAME from ZSCROBBLE)" 2>/dev/null || echo -1; }
finished() { local n; n=$(grep -c "Sync finished" "$log" 2>/dev/null); echo "${n:-0}"; }
lines_since() { tail -n +"$(($1 + 1))" "$log" 2>/dev/null; }

inject() { curl -s "http://127.0.0.1:$port/__inject?$1" >/dev/null; }

# Launches the profile app (choice: what to press on the prompt: none, skip, ignore or now), waits for its sync(s) to finish (two when
# "now" starts a second one), and quits it. Sets $new_lines to the log lines the launch wrote.
launch() {
  local choice="${1:-none}" syncs=1 before_lines before_finished pages_before
  [ "$choice" = "now" ] && syncs=2
  before_lines=$( [ -f "$log" ] && wc -l < "$log" || echo 0 )
  before_finished=$(finished)
  pages_before=$(stat history_pages_served)
  env -u SCROBLYTICS_STORE_PATH "$root/scripts/first-run-profile.sh" "$name" \
    --env "SCROBLYTICS_LASTFM_BASE_URL=http://127.0.0.1:$port/2.0/" --env "SCROBLYTICS_PROFILE_SEED_ACCOUNT=1" --env "SCROBLYTICS_RECHECK_CHOICE=$choice" \
    --env "SCROBLYTICS_UPDATE_FEED_URL=http://127.0.0.1:$port/repos/scrobl/Scroblytics/releases?per_page=10" >/dev/null 2>&1 &
  local runner=$!
  for _ in $(seq 1 240); do
    [ "$(finished)" -ge $((before_finished + syncs)) ] && break
    sleep 0.5
  done
  # skip and ignore are pressed a moment after the prompt appears: wait for that to be recorded before quitting.
  if [ "$choice" = "skip" ] || [ "$choice" = "ignore" ]; then
    for _ in $(seq 1 40); do lines_since "$before_lines" | grep -q "Chose to" && break; sleep 0.5; done
  fi
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

echo "== 6. two plays deleted from over 25 days ago (outside the window): asked, left unanswered"
inject "delete_old=2"; launch none
expect "went down by 2" "the log says Last.fm's total went down by 2"
expect "totals still differ" "the window cannot account for it"
expect "waiting for the person to choose" "it asks instead of starting the long walk"
expect_not "Full re-check" "the whole history is NOT walked"
[ "$(rows)" = "$(( $(stat total_scrobbles) + 2 ))" ] && pass "nothing was removed: the app still has the 2 plays Last.fm deleted" || fail "unexpected count $(rows)"

echo "== 7. closing without answering is the same as skipping: it asks again"
launch none
expect "went down by 2" "the same difference is found again"
expect "waiting for the person to choose" "and it asks again"

echo "== 8. Skip for now: asks again next time"
launch skip
expect "Chose to skip for now" "the skip is recorded"
launch none
expect "waiting for the person to choose" "the next sync asks again"

echo "== 9. Ignore: the difference is accepted"
launch ignore
expect "Chose to ignore the difference" "the ignore is recorded"
launch none
expect "Sync plan: quick check" "the next sync is a quick check"
expect_not "waiting for the person to choose" "and it does not ask again"
expect_not "Full re-check" "nor walk the history"
[ "$(rows)" = "$(( $(stat total_scrobbles) + 2 ))" ] && pass "the app keeps the 2 plays Last.fm no longer has, as accepted" || fail "unexpected count $(rows)"

echo "== 10. two late plays together with one old deletion, then Check now"
inject "late=2&delete_old=1"; launch now
expect "totals still differ" "the window finds 2 but Last.fm moved by 1, so it does not settle it"
expect "waiting for the person to choose" "it asks"
expect "Chose to check the whole history now" "check now is recorded"
expect "Full re-check finished" "the whole history is walked"
expect_counts "after check now"

echo "== 11. settled"
launch none
expect "Sync plan: quick check" "a quick check"
expect_not "waiting for the person to choose" "no question"
expect_not "re-check" "nothing is re-checked"
expect_counts "settled"

echo
if [ "$failures" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "$failures CHECK(S) FAILED"; fi
exit "$failures"
