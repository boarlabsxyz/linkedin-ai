#!/usr/bin/env bash
# Every-15-min LinkedIn comment-ideas drop, driven non-interactively by the
# xyz.boarlabs.slack-heartbeat LaunchAgent (which now execs this script instead
# of posting a bare heartbeat).
#
# Flow:
#   1. Branch off origin/main.
#   2. Invoke the linkedin-comment-hourly skill via `claude -p` — the skill
#      spawns two sub-agents (gather-feed + draft-one-post), writes JSON under
#      linkedin-compain/comments/, and posts to Slack channel C0BF606R4N7.
#   3. If anything changed under linkedin-compain/, commit + push + open a PR
#      via the common-pr-commit / common-pr-update scripts, then
#      squash-merge via common-pr-merge so PRs don't pile up across the
#      15-minute cadence.
set -euo pipefail

for cmd in claude node gh git jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Required command not found in PATH: $cmd" >&2
        exit 1
    fi
done

TS=$(date -u '+%Y-%m-%dT%H-%M-%SZ')
BRANCH="chore/linkedin-comments-${TS}"

git fetch origin main
git checkout -B "$BRANCH" origin/main

# CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 disables the 10-minute background-task
# kill switch. The 5-post drafting pipeline (Playwright + 5 × GDrive checklist)
# reliably exceeds 10 minutes; without this, cycle 1 got SIGTERMed mid-scrape
# and shipped nothing. launchd's at-most-one-instance guarantee prevents overlap
# even if a fire runs longer than the 15-min interval.
export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0

# Hard wall-clock cap on the whole `claude -p` run. Disabling the ceiling above
# removed the only kill switch, so a stalled MCP call (e.g. the Playwright
# "Copy link to post" clipboard flow) can wedge this process indefinitely — and
# launchd's at-most-one-instance guarantee then silently blocks EVERY later fire
# until it's killed by hand (a 00:15 fire once hung 19h, eating 06:15/12:15/18:15).
# macOS ships no coreutils `timeout`/`gtimeout`, so guard with a bash watchdog.
# 40 min covers a real ~20-30 min fire and frees the slot well inside the 6h gap.
CLAUDE_TIMEOUT_SECS=2400

run_claude_pipeline() {
  echo "run linkedin comment hourly" \
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
# subshell, sweep any orphaned Playwright browser (the cron's profile name is
# unique — never collides with an interactive session's default profile), and
# SIGKILL anything still standing.
(
  sleep "$CLAUDE_TIMEOUT_SECS"
  kill -0 "$pipeline_pid" 2>/dev/null || exit 0
  echo "run-hourly: claude exceeded ${CLAUDE_TIMEOUT_SECS}s — terminating (pid $pipeline_pid)." >&2
  pkill -TERM -P "$pipeline_pid" 2>/dev/null || true
  kill -TERM "$pipeline_pid" 2>/dev/null || true
  pkill -f 'mcp-chrome-linkedin-ai' 2>/dev/null || true
  sleep 15
  pkill -KILL -P "$pipeline_pid" 2>/dev/null || true
  kill -KILL "$pipeline_pid" 2>/dev/null || true
) &
watchdog_pid=$!

# Don't let `set -e` abort on a non-zero pipeline/timeout exit — we still want to
# commit any drafts already written + posted to Slack before the kill. Then cancel
# the watchdog if the run finished before the cap.
wait "$pipeline_pid" 2>/dev/null || true
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true

# A watchdog kill can land mid-write; never commit a truncated seen-set. Bail if
# comments.json no longer parses (the next fire hard-resets the worker anyway).
if [ -f linkedin-compain/comments.json ] && ! jq empty linkedin-compain/comments.json 2>/dev/null; then
    echo "run-hourly: linkedin-compain/comments.json is not valid JSON — skipping commit/PR." >&2
    exit 1
fi

# git diff --quiet only sees TRACKED changes; the skill writes untracked new JSON
# files under linkedin-compain/comments/, so git status --porcelain is what we
# actually need to detect them. Earlier fires wrote real drafts + posted to
# Slack but this check said "no changes" and skipped the PR.
if [ -z "$(git status --porcelain -- linkedin-compain/)" ]; then
    echo "No changes under linkedin-compain/ — skipping commit/PR." >&2
    exit 0
fi

./.claude/skills/common-pr-commit/commit.sh
./.claude/skills/common-pr-update/pr-update.sh
./.claude/skills/common-pr-merge/merge.sh
