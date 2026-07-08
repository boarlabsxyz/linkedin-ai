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

echo "run linkedin comment hourly" \
  | claude -p --dangerously-skip-permissions --output-format stream-json --verbose \
  | jq -r --unbuffered '
      .description
      // (.message?.content? | arrays | map(select(.type=="text") | .text) | .[])
      // (select(.is_error == true or .error) | "ERROR: \(.error // .message?.content)")
      // empty
    '

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
