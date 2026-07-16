#!/usr/bin/env bash
# Weekly LinkedIn-stats scrape, driven non-interactively by the
# linkedin-stats-weekly GitHub Actions workflow on a self-hosted macOS runner.
#
# Flow:
#   1. Branch off origin/main.
#   2. FAST PATH: run the deterministic scraper
#      (.claude/skills/linkedin-stats/fast/scrape-weekly.mjs) — one paced
#      Playwright process over the shared logged-in Chrome profile, ~5 min for
#      the whole snapshot set. No LLM in the scrape loop.
#   3. FALLBACK: only when the fast path exits 30 (selector/compat failure —
#      LinkedIn DOM drifted beyond what the line-anchored parsers handle),
#      invoke the legacy linkedin-stats agent pipeline via `claude -p` (the
#      sonnet agents improvise selectors; multi-hour, watchdogged).
#      Exit codes 20 (auth), 21 (profile locked), 22 (rate-limited), 23 (fs)
#      fail the run outright — the agent path would hit the same wall.
#   4. jq-validate every JSON, require a non-empty diff, then commit + push +
#      PR + squash-merge via the common-pr-* scripts.
set -euo pipefail

for cmd in claude node npm gh git jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Required command not found in PATH: $cmd" >&2
    exit 1
  fi
done

WEEK=$(date -u -v-Mon "+%Y-%m-%d" 2>/dev/null || date -u -d "last monday" "+%Y-%m-%d")
BRANCH="chore/linkedin-stats-${WEEK}"

git fetch origin main
git checkout -B "$BRANCH" origin/main

# ---------------------------------------------------------------- fast path

FAST_DIR=".claude/skills/linkedin-stats/fast"
fast_exit=0
if [ -f "$FAST_DIR/scrape-weekly.mjs" ]; then
  # node_modules is gitignored; the cron worker clone starts clean every fire.
  if [ ! -d "$FAST_DIR/node_modules/playwright-core" ]; then
    (cd "$FAST_DIR" && npm install --no-audit --no-fund --silent)
  fi
  echo "run-weekly: fast path starting ($(date -u +%H:%M:%SZ))"
  set +e
  node "$FAST_DIR/scrape-weekly.mjs" --deadline-secs=900
  fast_exit=$?
  set -e
  echo "run-weekly: fast path exited $fast_exit ($(date -u +%H:%M:%SZ))"
else
  fast_exit=30 # no fast script in this checkout — use the agent path
fi

case "$fast_exit" in
  0|10)
    echo "run-weekly: fast path succeeded (10 = partial per-post failures; still valid)."
    ;;
  30)
    echo "run-weekly: fast path reported selector/compat failure — falling back to the agent pipeline." >&2

    # CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 disables the 10-minute
    # background-task kill switch — the agent pipeline (one metrics agent per
    # post, sequential) runs multi-hour.
    export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0

    # Hard wall-clock cap on the whole `claude -p` run. 6h covers a real
    # multi-hour scrape and leaves room for the commit/PR/merge chain.
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

    # Watchdog: after the cap, TERM the pipeline's children then the subshell,
    # sweep any orphaned Playwright browser, and SIGKILL anything left.
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
    # snapshots are still worth committing. Then cancel the watchdog.
    wait "$pipeline_pid" 2>/dev/null || true
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    ;;
  20)
    echo "run-weekly: AUTH wall — LinkedIn session expired on the runner profile; failing." >&2
    exit 1
    ;;
  21)
    echo "run-weekly: Chrome profile is locked by another job; failing (next run retries)." >&2
    exit 1
    ;;
  22)
    # Commit whatever landed (weekly snapshots are unrecoverable later), but
    # fail the workflow at the end so the partial run is visible, not green.
    echo "run-weekly: rate-limited beyond recovery; committing partial snapshots, then failing the run." >&2
    partial_failure=1
    ;;
  *)
    echo "run-weekly: fast path failed with unexpected exit $fast_exit; failing." >&2
    exit 1
    ;;
esac

# A kill/deadline can land mid-write; never commit a truncated snapshot.
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

if [ "${partial_failure:-0}" = 1 ]; then
  echo "run-weekly: partial data committed, but the scrape was rate-limited — marking the run failed." >&2
  exit 1
fi
