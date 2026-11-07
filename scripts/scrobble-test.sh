#!/bin/bash
# End to end: submitting plays to Last.fm (track.scrobble) through the app's real client, against the stand-in Last.fm server, in an
# isolated test profile. Never your real data or account: the app is started with the stand-in's loopback address, and the test hook
# refuses to run against anything else.
#
#   scripts/scrobble-test.sh
#
# The stand-in verifies each request's signature on its own (shared secret "scrobblesecret"), keeps what it accepts, and ignores plays
# older than 14 days. The script then checks, from the server's own list, that:
#   * all 55 made-up plays arrived exactly once (two batches: 50 and 5), in the order sent, with names (symbols, quotes, accents, other
#     scripts, stray spaces) and timestamps intact;
#   * a play 20 days old comes back ignored with code 3, not accepted and not an error;
#   * a request signed with the wrong secret is refused (error 13) and keeps nothing.
# Build the Debug app first (see CLAUDE.md). Exits 0 only if every check passes.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
port=8815
name=scrobbletest
out=/tmp/scroblytics-scrobble-e2e.txt
failures=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; failures=$((failures + 1)); }

rm -f "$out"
env -u SCROBLYTICS_STORE_PATH "$root/scripts/first-run-profile.sh" "$name" --reset >/dev/null 2>&1
python3 -I "$root/scripts/fake-lastfm.py" --scenario empty-account --port "$port" --secret scrobblesecret >/dev/null 2>&1 &
server=$!
trap 'kill $server 2>/dev/null; wait $server 2>/dev/null; env -u SCROBLYTICS_STORE_PATH "$root/scripts/first-run-profile.sh" "$name" --reset >/dev/null 2>&1' EXIT
for _ in $(seq 1 30); do curl -s "http://127.0.0.1:$port/__stats" >/dev/null 2>&1 && break; sleep 0.2; done

env -u SCROBLYTICS_STORE_PATH "$root/scripts/first-run-profile.sh" "$name" \
  --env "SCROBLYTICS_LASTFM_BASE_URL=http://127.0.0.1:$port/2.0/" --env "SCROBLYTICS_SCROBBLE_E2E=1" --env "SCROBLYTICS_SCROBBLE_E2E_OUT=$out" >/dev/null 2>&1
[ -s "$out" ] && pass "the app ran the hook and wrote its result" || { fail "the app wrote no result ($out)"; exit 1; }
grep -q "^REFUSED" "$out" && { fail "the hook refused to run: $(grep '^REFUSED' "$out")"; exit 1; }

curl -s "http://127.0.0.1:$port/__scrobbles" > /tmp/scroblytics-scrobble-server.json
python3 -I - "$out" /tmp/scroblytics-scrobble-server.json <<'PY'
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
server = json.load(open(sys.argv[2], encoding="utf-8"))
expected = [tuple(l.split("\t")[1:]) for l in lines if l.startswith("EXPECTED\t")]
expected = [(a, t, al, int(ts)) for a, t, al, ts in expected]
got = [(s["artist"], s["track"], s["album"], s["timestamp"]) for s in server]
field = lambda k: next((l.split(" ", 1)[1] for l in lines if l.startswith(k + " ")), None)
results = []
def check(label, ok): results.append((ok, label))
check("the app sent 55 plays and Last.fm took all 55", field("ACCEPTED") == "55" and field("IGNORED") == "0" and field("NOTSENT") == "0" and field("FAILURE") == "none")
check("the server kept 55 plays, each exactly once (50 + 5 in two requests)", len(got) == 55 + 0 and len(set(got)) == len(got))
check("they are exactly the plays the app meant to send, names and timestamps intact", sorted(got) == sorted(expected))
check("they arrived oldest first", [g[3] for g in got] == sorted(g[3] for g in got))
check("a play 20 days old was ignored with code 3, not accepted and not an error", field("OLD") == "accepted=false code=3")
check("the too-old play was not kept", not any(g[0] == "Old Artist" for g in got))
check("a request signed with the wrong secret was refused with error 13", field("WRONGSECRET") == "api 13")
check("and it kept nothing", not any(g[0] == "Wrong Secret" for g in got))
for ok, label in results: print(("  PASS  " if ok else "  FAIL  ") + label)
sys.exit(0 if all(ok for ok, _ in results) else 1)
PY
[ $? -eq 0 ] || failures=$((failures + 1))
echo
if [ "$failures" -eq 0 ]; then echo "ALL CHECKS PASSED"; exit 0; else echo "$failures CHECK(S) FAILED"; exit 1; fi
