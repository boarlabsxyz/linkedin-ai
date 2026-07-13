#!/usr/bin/env bash
# Weekly LinkedIn-stats scrape, driven non-interactively by the
# linkedin-stats-weekly GitHub Actions workflow on a self-hosted macOS runner.
#
# Flow:
#   1. Branch off origin/main.
#   2. Invoke the linkedin-stats skill via `claude -p` (writes JSON snapshots
#      under dashboards/li-stats/).
#   3. If anything changed, commit + push + open a PR by reusing the existing
#      common-pr-commit / common-pr-update scripts (same message format as
#      manual runs).
#   4. Squash-merge the PR via common-pr-merge so weekly snapshots don't pile
#      up and conflict with each other on subsequent runs.
set -euo pipefail

for cmd in claude node gh git jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Required command not found in PATH: $cmd" >&2
    exit 1
  fi
done

WEEK=$(date -u -v-Mon "+%Y-%m-%d" 2>/dev/null || date -u -d "last monday" "+%Y-%m-%d")
BRANCH="chore/linkedin-stats-${WEEK}"

git fetch origin main
git checkout -B "$BRANCH" origin/main

# CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 disables the 10-minute background-task
# kill switch. The scrape (post discovery + one metrics agent per post,
# sequential) always exceeds 10 minutes; without this, the 2026-07-06 and
# 2026-07-13 scheduled runs got SIGTERMed mid-scrape ("Background tasks still
# running after 600s; terminating") and shipped nothing — while the workflow
# stayed green.
export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0

# Hard wall-clock cap on the whole `claude -p` run. Disabling the ceiling above
# removed the only kill switch, so a stalled MCP call can wedge the run until
# the 420-min job timeout. 6h covers a real multi-hour scrape and leaves room
# for the commit/PR/merge chain inside the job timeout.
CLAUDE_TIMEOUT_SECS=21600

run_claude_pipeline() {
  echo "gather linkedin stats" \
    | claude -p --dangerously-skip-permissions --output-format stream-json --verbose \
    | jq -r --unbuffered '
        .description
        // (.message?.content? | arrays | map(select(.type=="text") | .text) | .[])
        // (select(.is_error == true or .error) | "ERROR: \(.error // .message?.content)")
        // empty
      '
}

run_claude_pipeline &
pipeline_pid=$!

# Watchdog: after the cap, TERM the pipeline's children (echo/claude/jq) then the
# subshell, sweep any orphaned Playwright browser, and SIGKILL anything still
# standing. macOS ships no coreutils `timeout`/`gtimeout`.
(
  sleep "$CLAUDE_TIMEOUT_SECS"
  kill -0 "$pipeline_pid" 2>/dev/null || exit 0
  echo "run-weekly: claude exceeded ${CLAUDE_TIMEOUT_SECS}s — terminating (pid $pipeline_pid)." >&2
  pkill -TERM -P "$pipeline_pid" 2>/dev/null || true
  kill -TERM "$pipeline_pid" 2>/dev/null || true
  pkill -f 'mcp-chrome-linkedin-ai' 2>/dev/null || true
  sleep 15
  pkill -KILL -P "$pipeline_pid" 2>/dev/null || true
  kill -KILL "$pipeline_pid" 2>/dev/null || true
) &
watchdog_pid=$!

# Don't let `set -e` abort on a non-zero pipeline/timeout exit — partial
# snapshots (some posts scraped before a kill) are still worth committing.
# Then cancel the watchdog if the run finished before the cap.
wait "$pipeline_pid" 2>/dev/null || true
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true

# A watchdog kill can land mid-write; never commit a truncated snapshot.
while IFS= read -r -d '' f; do
  if ! jq empty "$f" 2>/dev/null; then
    echo "run-weekly: $f is not valid JSON — skipping commit/PR." >&2
    exit 1
  fi
done < <(find dashboards/li-stats -name '*.json' -print0)

# git diff --quiet only sees TRACKED changes; new posts create untracked JSON
# files under dashboards/li-stats/posts/, so use git status --porcelain. And a
# weekly run must at minimum add a weeks[WEEK] entry to account.json — "no
# changes" means the scrape produced nothing, so fail loudly instead of green.
if [ -z "$(git status --porcelain -- dashboards/li-stats/)" ]; then
  echo "run-weekly: no changes under dashboards/li-stats/ after scrape — the scrape failed; failing the run." >&2
  exit 1
fi

./.claude/skills/common-pr-commit/commit.sh
./.claude/skills/common-pr-update/pr-update.sh
./.claude/skills/common-pr-merge/merge.sh
