#!/usr/bin/env python3
"""A stand-in for Last.fm's API, for testing Scroblytics' first run and failure cases without a real account.

    python3 -I scripts/fake-lastfm.py --scenario small --port 8765

Serves synthetic data only ("Artist 1", "Track 7", ...). The app is pointed at it with
SCROBLYTICS_LASTFM_BASE_URL (see scripts/first-run-profile.sh, which starts both). Standard library only.

Scenarios
  empty-account   a valid account with 0 scrobbles
  small           50 scrobbles
  medium          2,000 scrobbles
  large           40,000 scrobbles (200 pages)
  bad-key         every request: error 10 (invalid API key)
  suspended-key   every request: error 26
  unknown-user    every request: error 6 (user not found)
  private         every request: error 17 (login required)
  rate-limited    the first 6 history pages answer error 29, then it recovers
  drops-mid-sync  after 5 history pages the connection is cut 3 times, then it recovers
  slow            every request takes 3 seconds
  flaky-key       works for 5 history pages, then error 10 (key revoked mid-import)
  rate-limited-long   every history request answers error 29 for the first 90 s (--window N to change), then it recovers
  strict-rate     Last.fm's real rule: more than 5 requests in any rolling second answer error 29 (6,000 scrobbles)
  rate-limited-forever   every history request answers error 29, always
  timing          10,000 scrobbles with no limits at all; use --latency-ms to simulate how slowly Last.fm answers
  late-plays      3,000 scrobbles an hour apart (125 days). GET /__inject?new=N&late=N&delete_recent=N&delete_old=N changes the history
                  between syncs: new = N newer plays; late = N plays dated within the last 10 days but older than the newest (a scrobbler
                  that sends late); delete_recent = N plays removed from 3 to 5 days ago; delete_old = N plays removed from over 25 days ago

GET /__stats returns what was served, and the dataset's own totals, as JSON, for cross-checking an import. It also reports the
busiest second (max_requests_in_one_second), the shortest gap between history requests (min_history_gap_ms) and how many requests
were answered with error 29 (rate_limit_answers).
"""
import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

SCENARIOS = {
    "empty-account": "A valid account with 0 scrobbles",
    "small": "50 scrobbles",
    "medium": "2,000 scrobbles",
    "large": "40,000 scrobbles (200 pages)",
    "bad-key": "Every request: invalid API key (error 10)",
    "suspended-key": "Every request: suspended API key (error 26)",
    "unknown-user": "Every request: user not found (error 6)",
    "private": "Every request: login required, private profile (error 17)",
    "rate-limited": "The first 6 history pages are rate-limited (error 29), then it recovers",
    "drops-mid-sync": "The connection is cut 3 times after 5 history pages, then it recovers",
    "slow": "Every request takes 3 seconds",
    "slow-import": "4,000 scrobbles, each history page takes 1.5 seconds (to try Stop and Resume)",
    "flaky-key": "Works for 5 history pages, then the key is rejected (error 10)",
    "rate-limited-long": "Every history request is rate-limited (error 29) for the first 90 seconds, then it recovers",
    "strict-rate": "More than 5 requests in any rolling second are rate-limited (error 29), as Last.fm does; 6,000 scrobbles",
    "rate-limited-forever": "Every history request is rate-limited (error 29), always",
    "timing": "10,000 scrobbles, no limits; with --latency-ms, every history page takes that long (to time an import)",
    "late-plays": "3,000 scrobbles an hour apart; /__inject adds new, late or deleted plays between syncs",
}
PAGE_SIZE = 200
NOW = int(time.time())
SIZES = {"empty-account": 0, "small": 50, "medium": 2000, "large": 40000, "slow-import": 4000,
         "rate-limited-long": 2000, "strict-rate": 6000, "rate-limited-forever": 2000, "timing": 10000, "late-plays": 3000}
RATE_LIMIT_ERROR = (29, "Rate Limit Exceeded - Your IP has made too many requests in a short period", 429)
STRICT_PER_SECOND = 5
LONG_WINDOW_SECONDS = 90.0
LATENCY_SECONDS = 0.0
RELEASE_VERSION = "9.9.9"   # newest version the stand-in GitHub release list announces; "down" makes it answer HTTP 500
ERRORS = {
    "bad-key": (10, "Invalid API key - You must be granted a valid key by last.fm", 403),
    "suspended-key": (26, "Suspended API key - Access for your account has been suspended, please contact Last.fm", 403),
    "unknown-user": (6, "User not found", 404),
    "private": (17, "Login: User required to be logged in", 403),
}


def make_scrobbles(total, spacing=240):
    """Newest first. Track i belongs to artist (i*7 % A) so every artist recurs; timestamps are 4 minutes apart (or `spacing` seconds)."""
    artists = max(5, min(900, total // 40))
    rows = []
    for i in range(total):
        a = (i * 7) % artists
        rows.append({
            "uts": NOW - 3600 - i * spacing,
            "artist": f"Artist {a + 1}",
            "album": f"Album {a + 1}.{(i // 11) % 4 + 1}",
            "track": f"Track {(i * 13) % 600 + 1}",
        })
    return rows


class State:
    def __init__(self, scenario):
        self.scenario = scenario
        self.total = SIZES.get(scenario, SIZES["small"] if scenario not in ERRORS else 0)
        if scenario in ("rate-limited", "drops-mid-sync", "flaky-key"):
            self.total = SIZES["medium"]
        self.rows = make_scrobbles(self.total, 3600 if scenario == "late-plays" else 240)
        self.lock = threading.Lock()
        self.history_requests = 0
        self.drops_left = 3
        self.served = {}
        self.history_pages_served = 0
        self.request_times = []        # time.monotonic() of every request
        self.history_times = []        # ... of every history request (limit > 1)
        self.rate_limit_answers = 0
        self.first_history_at = None

    def inject(self, new=0, late=0, delete_recent=0, delete_old=0):
        """Changes the history between syncs (see the late-plays scenario). Late plays are dated within the last 10 days, half an hour
        off the hourly grid, so they are older than the newest play but never the same as one."""
        self.injected = getattr(self, "injected", 0)
        for i in range(new):
            self.injected += 1
            self.rows.append({"uts": NOW - 3000 + self.injected * 30, "artist": f"New Artist {self.injected}", "album": "New Album", "track": f"New Track {self.injected}"})
        for i in range(late):
            self.injected += 1
            self.rows.append({"uts": NOW - 3600 * (5 + (self.injected * 7) % 230) - 1800, "artist": f"Late Artist {self.injected}", "album": "Late Album", "track": f"Late Track {self.injected}"})
        recent = [r for r in self.rows if NOW - 5 * 86400 <= r["uts"] <= NOW - 3 * 86400][:delete_recent]
        old = [r for r in self.rows if r["uts"] <= NOW - 25 * 86400][:delete_old]
        gone = {id(r) for r in recent + old}
        self.rows = [r for r in self.rows if id(r) not in gone]
        self.rows.sort(key=lambda r: -r["uts"])

    def stats(self):
        return {
            "scenario": self.scenario,
            "total_scrobbles": len(self.rows),
            "first_uts": self.rows[-1]["uts"] if self.rows else None,
            "last_uts": self.rows[0]["uts"] if self.rows else None,
            "distinct_artists": len({r["artist"] for r in self.rows}),
            "distinct_tracks": len({(r["artist"], r["track"]) for r in self.rows}),
            "requests_by_method": self.served,
            "history_pages_served": self.history_pages_served,
            "max_requests_in_one_second": self.max_in_one_second(),
            "min_history_gap_ms": self.min_history_gap_ms(),
            "rate_limit_answers": self.rate_limit_answers,
            "history_span_ms": round((self.history_times[-1] - self.history_times[0]) * 1000) if len(self.history_times) > 1 else None,
        }

    def max_in_one_second(self):
        times, best, lo = self.request_times, 0, 0
        for hi in range(len(times)):
            while times[hi] - times[lo] > 1.0:
                lo += 1
            best = max(best, hi - lo + 1)
        return best

    def min_history_gap_ms(self):
        gaps = [b - a for a, b in zip(self.history_times, self.history_times[1:])]
        return round(min(gaps) * 1000) if gaps else None


def build_handler(state):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            return

        def _send(self, status, payload):
            body = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _error(self, code, message, status):
            self._send(status, {"error": code, "message": message})

        def do_GET(self):
            url = urlparse(self.path)
            if url.path == "/__stats":
                self._send(200, state.stats())
                return
            if url.path == "/__inject":
                q = {k: int(v[0]) for k, v in parse_qs(url.query).items()}
                with state.lock:
                    state.inject(new=q.get("new", 0), late=q.get("late", 0), delete_recent=q.get("delete_recent", 0), delete_old=q.get("delete_old", 0))
                self._send(200, state.stats())
                return
            if url.path.startswith("/repos/scrobl/Scroblytics/releases"):
                # A stand-in for GitHub's release list, for testing the "update available" notice.
                if RELEASE_VERSION == "down":
                    self._send(500, {"message": "stand-in: GitHub is down"})
                    return
                page = "https://github.com/scrobl/Scroblytics/releases/tag/v" + RELEASE_VERSION
                self._send(200, [
                    {"tag_name": "v0.9.0", "html_url": "https://github.com/scrobl/Scroblytics/releases/tag/v0.9.0", "draft": False, "prerelease": True},
                    {"tag_name": "v" + RELEASE_VERSION, "html_url": page, "draft": False, "prerelease": True},
                    {"tag_name": "v99.0.0", "html_url": "https://github.com/scrobl/Scroblytics/releases/tag/v99.0.0", "draft": True, "prerelease": False},
                ])
                return
            q = {k: v[0] for k, v in parse_qs(url.query).items()}
            method = q.get("method", "")
            now = time.monotonic()
            is_history = method == "user.getRecentTracks" and int(q.get("limit", PAGE_SIZE)) > 1
            with state.lock:
                state.served[method] = state.served.get(method, 0) + 1
                state.request_times.append(now)
                if is_history:
                    state.history_times.append(now)
                    if state.first_history_at is None:
                        state.first_history_at = now
                limited = False
                if state.scenario == "strict-rate":
                    recent = [t for t in state.request_times if now - t <= 1.0]
                    limited = len(recent) > STRICT_PER_SECOND
                elif state.scenario == "rate-limited-forever":
                    limited = is_history
                elif state.scenario == "rate-limited-long":
                    limited = is_history and now - state.first_history_at < LONG_WINDOW_SECONDS
                if limited:
                    state.rate_limit_answers += 1
            if limited:
                self._error(*RATE_LIMIT_ERROR)
                return
            if state.scenario == "slow":
                time.sleep(3)
            if is_history and LATENCY_SECONDS:
                time.sleep(LATENCY_SECONDS)
            if state.scenario in ERRORS:
                self._error(*ERRORS[state.scenario])
                return
            if not q.get("api_key") or not q.get("user") and method.startswith("user."):
                self._error(10, "Invalid API key - You must be granted a valid key by last.fm", 403)
                return

            if method == "user.getInfo":
                self._send(200, {"user": {"name": q.get("user", "tester"), "playcount": str(len(state.rows)),
                                          "registered": {"unixtime": str(NOW - 86400 * 365)}}})
            elif method == "user.getRecentTracks":
                self._recent(q)
            elif method == "user.getLovedTracks":
                self._send(200, {"lovedtracks": {"track": [], "@attr": {
                    "user": q.get("user", ""), "totalPages": "0", "page": "1", "perPage": str(PAGE_SIZE), "total": "0"}}})
            else:
                # Tags, popularity, similar music, tracklists: this stand-in has none of it.
                self._error(6, "not found", 404)

        def _recent(self, q):
            limit = int(q.get("limit", PAGE_SIZE))
            page = int(q.get("page", "1"))
            lo = int(q["from"]) if "from" in q else None
            hi = int(q["to"]) if "to" in q else None
            rows = [r for r in state.rows if (lo is None or r["uts"] >= lo) and (hi is None or r["uts"] <= hi)]
            total = len(rows)
            pages = (total + limit - 1) // limit
            if limit > 1 and state.scenario == "slow-import":
                time.sleep(1.5)
            if limit > 1:
                with state.lock:
                    state.history_requests += 1
                    n = state.history_requests
                    if state.scenario == "rate-limited" and n <= 6:
                        self._error(29, "Rate Limit Exceeded - Your IP has made too many requests in a short period", 429)
                        return
                    if state.scenario == "drops-mid-sync" and n > 5 and state.drops_left > 0:
                        state.drops_left -= 1
                        self.connection.close()
                        return
                    if state.scenario == "flaky-key" and n > 5:
                        self._error(10, "Invalid API key - You must be granted a valid key by last.fm", 403)
                        return
                    state.history_pages_served += 1
            chunk = rows[(page - 1) * limit: page * limit]
            tracks = [{
                "name": r["track"],
                "artist": {"#text": r["artist"], "mbid": ""},
                "album": {"#text": r["album"], "mbid": ""},
                "image": [{"size": "extralarge", "#text": ""}],
                "date": {"uts": str(r["uts"]), "#text": ""},
            } for r in chunk]
            attr = {"user": q.get("user", ""), "totalPages": str(pages), "page": str(page),
                    "perPage": str(limit), "total": str(total)}
            payload = {"recenttracks": {"track": tracks, "@attr": attr}}
            if tracks == [] and total == 0:
                payload["recenttracks"]["track"] = []
            self._send(200, payload)

    return Handler


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scenario", default="small", choices=sorted(SCENARIOS))
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--window", type=float, default=90.0, help="seconds rate-limited-long keeps answering error 29")
    ap.add_argument("--latency-ms", type=float, default=0.0, help="delay every history page by this long")
    ap.add_argument("--release-version", default="9.9.9", help='newest version the stand-in release list announces ("down": answer HTTP 500)')
    ap.add_argument("--list", action="store_true", help="print the scenarios, one 'name<TAB>description' per line, and exit")
    args = ap.parse_args()
    if args.list:
        for name, detail in SCENARIOS.items():
            print(f"{name}\t{detail}")
        return
    global LONG_WINDOW_SECONDS, LATENCY_SECONDS, RELEASE_VERSION
    RELEASE_VERSION = args.release_version
    LONG_WINDOW_SECONDS = args.window
    LATENCY_SECONDS = args.latency_ms / 1000.0
    state = State(args.scenario)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), build_handler(state))
    print(f"fake Last.fm: scenario={args.scenario} scrobbles={len(state.rows)} http://127.0.0.1:{args.port}/2.0/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
