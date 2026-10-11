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

GET /__stats returns what was served, and the dataset's own totals, as JSON, for cross-checking an import.
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
}
PAGE_SIZE = 200
NOW = int(time.time())
SIZES = {"empty-account": 0, "small": 50, "medium": 2000, "large": 40000, "slow-import": 4000}
ERRORS = {
    "bad-key": (10, "Invalid API key - You must be granted a valid key by last.fm", 403),
    "suspended-key": (26, "Suspended API key - Access for your account has been suspended, please contact Last.fm", 403),
    "unknown-user": (6, "User not found", 404),
    "private": (17, "Login: User required to be logged in", 403),
}


def make_scrobbles(total):
    """Newest first. Track i belongs to artist (i*7 % A) so every artist recurs; timestamps are 4 minutes apart."""
    artists = max(5, min(900, total // 40))
    rows = []
    for i in range(total):
        a = (i * 7) % artists
        rows.append({
            "uts": NOW - 3600 - i * 240,
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
        self.rows = make_scrobbles(self.total)
        self.lock = threading.Lock()
        self.history_requests = 0
        self.drops_left = 3
        self.served = {}
        self.history_pages_served = 0

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
        }


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
            q = {k: v[0] for k, v in parse_qs(url.query).items()}
            method = q.get("method", "")
            with state.lock:
                state.served[method] = state.served.get(method, 0) + 1
            if state.scenario == "slow":
                time.sleep(3)
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
    ap.add_argument("--list", action="store_true", help="print the scenarios, one 'name<TAB>description' per line, and exit")
    args = ap.parse_args()
    if args.list:
        for name, detail in SCENARIOS.items():
            print(f"{name}\t{detail}")
        return
    state = State(args.scenario)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), build_handler(state))
    print(f"fake Last.fm: scenario={args.scenario} scrobbles={len(state.rows)} http://127.0.0.1:{args.port}/2.0/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
