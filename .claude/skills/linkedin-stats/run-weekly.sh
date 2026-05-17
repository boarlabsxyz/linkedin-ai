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
Then call browser_wait_for with text "this-text-will-never-appear-just-burn-time" and a timeout of 540 seconds — during this 9-minute window the human will log in manually if needed; the wait will time out, which is fine and expected.
After the wait, take a fresh browser_snapshot and report whether you can see signed-in chrome (e.g. the "Me" avatar, the home feed, the messaging icon) vs the public login wall.
Do not exit before the wait completes.'

echo "$PROMPT" | claude -p --dangerously-skip-permissions --output-format stream-json --verbose
