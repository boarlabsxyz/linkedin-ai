#!/usr/bin/env bash
# TEMP: auth-probe mode. Opens LinkedIn via the Playwright MCP and waits long
# enough for the human to log in interactively, so the session lands in the
# Playwright cache. Revert to the full scrape flow once the session is seeded.
set -euo pipefail

for cmd in claude; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Required command not found in PATH: $cmd" >&2
    exit 1
  fi
done

PROMPT='Open https://www.linkedin.com/ in the browser via the Playwright MCP using browser_navigate.
Then take a browser_snapshot so you can confirm what loaded.
Then call browser_wait_for with ONLY the "time" parameter set to 540 (numeric seconds — do NOT also pass "text" or "textGone", they are mutually exclusive with "time"). This is a pure 9-minute pause to let the human log in manually.
After the wait, take a fresh browser_snapshot and report whether you can see signed-in chrome (e.g. the "Me" avatar, the home feed, the messaging icon) vs the public login wall.
Do not exit before the wait completes.'

echo "$PROMPT" | claude -p --dangerously-skip-permissions --output-format stream-json --verbose
