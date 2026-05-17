#!/usr/bin/env bash
# Weekly LinkedIn-stats scrape, driven non-interactively by the
# linkedin-stats-weekly GitHub Actions workflow on a self-hosted macOS runner.
#
# Flow:
#   1. Branch off origin/main.
#   2. Invoke the linkedin-stats skill via `claude -p` (writes JSON snapshots
#      under dashboards/li-stats/).
#   3. Refresh CSVs + rebuild both dashboards.
#   4. If anything changed, commit + push + open a PR by reusing the existing
#      common-pr-commit / common-pr-update scripts (same message format as
#      manual runs).
set -euo pipefail

for cmd in claude python3 node npm gh git; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Required command not found in PATH: $cmd" >&2
    exit 1
  fi
done

WEEK=$(date -u -v-Mon "+%Y-%m-%d" 2>/dev/null || date -u -d "last monday" "+%Y-%m-%d")
BRANCH="chore/linkedin-stats-${WEEK}"

git fetch origin main
git checkout -B "$BRANCH" origin/main

echo "gather linkedin stats" | claude -p --dangerously-skip-permissions

python3 dashboards/flatten.py

npm --prefix dashboards/evidence ci --prefer-offline --no-audit
npm --prefix dashboards/evidence run sources
npm --prefix dashboards/evidence run build

npm --prefix dashboards/observable ci --prefer-offline --no-audit
npm --prefix dashboards/observable run build

if git diff --quiet -- dashboards/li-stats/ && git diff --cached --quiet -- dashboards/li-stats/; then
  echo "No changes under dashboards/li-stats/ after scrape — skipping commit/PR." >&2
  exit 0
fi

./.claude/skills/common-pr-commit/commit.sh
./.claude/skills/common-pr-update/pr-update.sh
