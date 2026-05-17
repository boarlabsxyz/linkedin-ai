#!/usr/bin/env bash
# TEMP: profile-share probe. Navigates to LinkedIn via the Playwright MCP and
# reports whether the pinned --user-data-dir profile is logged in. Revert to
# the full scrape flow once the shared profile is confirmed.
set -euo pipefail

for cmd in claude; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Required command not found in PATH: $cmd" >&2
    exit 1
  fi
done

PROMPT='Use the Playwright MCP to:
1. browser_navigate to https://www.linkedin.com/feed/
2. browser_snapshot
3. Report concisely: is the page the signed-in feed (look for the "Start a post" composer, the left-rail Me card, the "Home/My Network/Jobs/Messaging/Notifications" top nav) or the public login wall? Quote one short piece of the snapshot that proves it.
4. browser_close
Do not call browser_wait_for.'

echo "$PROMPT" | claude -p --dangerously-skip-permissions --output-format stream-json --verbose
