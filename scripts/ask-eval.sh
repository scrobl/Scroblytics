#!/bin/bash
# Scores an Ask engine on the evaluation set (Query/Ask/AskEval.swift) using the Debug build of the app.
#
#   scripts/ask-eval.sh anthropic claude-sonnet-5-5          # key from $ANTHROPIC_API_KEY
#   scripts/ask-eval.sh openAI gpt-4o                        # key from $OPENAI_API_KEY
#   scripts/ask-eval.sh google gemini-2.5-flash              # key from $GEMINI_API_KEY (or $GOOGLE_API_KEY)
#   scripts/ask-eval.sh ollama qwen2.5:14b                   # no key; server at http://localhost:11434
#   scripts/ask-eval.sh openAICompatible some-model http://localhost:1234   # key (optional) from $OPENAI_COMPAT_API_KEY
#   scripts/ask-eval.sh onDevice
#
# The key is read from the environment of THIS shell, handed to the app process through its environment, and never
# written to a file or printed. The app reads a COPY of your store (so nothing in your library is touched) and the
# result goes to .ask-eval/<engine>-<model>.json, which is git-ignored. It makes one model call per request (58).
set -euo pipefail
provider="${1:?engine: anthropic | openAI | google | ollama | openAICompatible | onDevice}"
model="${2:-}"
baseurl="${3:-}"
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$(ls -d ~/Library/Developer/Xcode/DerivedData/Scroblytics-*/Build/Products/Debug/Scroblytics.app | head -1)"
[ -n "$app" ] || { echo "Build the Debug app first (xcodebuild … build)."; exit 1; }

case "$provider" in
  anthropic) key="${ANTHROPIC_API_KEY:-}" ;;
  openAI) key="${OPENAI_API_KEY:-}" ;;
  google) key="${GEMINI_API_KEY:-${GOOGLE_API_KEY:-}}" ;;
  openAICompatible) key="${OPENAI_COMPAT_API_KEY:-}" ;;
  *) key="" ;;
esac
case "$provider" in anthropic|openAI|google) [ -n "$key" ] || { echo "No API key in the environment for $provider."; exit 1; } ;; esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
support="$HOME/Library/Application Support"
cp "$support/default.store" "$support/default.store-wal" "$support/default.store-shm" "$work/" 2>/dev/null || cp "$support/default.store" "$work/"
mkdir -p "$root/.ask-eval"
out="$root/.ask-eval/${provider}-${model//[^A-Za-z0-9._-]/_}.json"
echo "Scoring $provider ${model:-} … (this takes a few minutes)"
SCROBLYTICS_STORE_PATH="$work/default.store" SCROBLYTICS_OFFLINE=1 \
  SCROBLYTICS_ASK_EVALSET="$out" SCROBLYTICS_ASK_PROVIDER="$provider" \
  SCROBLYTICS_ASK_MODEL="$model" SCROBLYTICS_ASK_BASEURL="$baseurl" SCROBLYTICS_ASK_KEY="$key" \
  "$app/Contents/MacOS/Scroblytics" >/dev/null 2>&1 || true
python3 - "$out" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(d["provider"], d.get("model", ""), "→", d["score"], "|", d.get("unseenScore", ""))
print("by category:", d["byCategory"])
t = d.get("tokens", {})
print("tokens in/out/cached:", t.get("input"), t.get("output"), t.get("cached"))
secs = [r["seconds"] for r in d["results"]]
print("avg seconds per request: %.1f" % (sum(secs) / len(secs)))
PY
echo "Full results: $out"
