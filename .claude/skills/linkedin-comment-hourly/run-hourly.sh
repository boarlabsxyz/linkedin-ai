#!/usr/bin/env bash
# Scheduled LinkedIn comment-ideas drop, driven non-interactively by the
# xyz.boarlabs.slack-heartbeat LaunchAgent (which execs this script instead
# of posting a bare heartbeat).
#
# Flow:
#   1. Branch off origin/main.
#   2. FAST GATHER: run the deterministic feed scraper
#      (.claude/skills/linkedin-comment-hourly/fast/gather-feed.mjs) — one
#      paced Playwright process over the shared logged-in Chrome profile that
#      scrapes, classifies (batched tool-free `claude -p` haiku calls),
#      appends filtered entries to linkedin-compain/comments.json, recovers
#      permalinks, and writes a KEY=VALUE contract. <5 min; replaces the
#      ~7+ min LLM gather agent.
#   3. DRAFTING: invoke the linkedin-comment-hourly skill via `claude -p`
#      pointing at the pre-gathered contract — the skill spawns prep-refs +
#      the parallel draft agents, writes drafted entries, posts to Slack.
#      Skipped entirely when the gather found 0 draftable posts.
#      FALLBACK: only when the fast gather exits 30 (selector drift), the
#      skill is told to use the legacy gather-feed agent instead.
#   4. If anything changed under linkedin-compain/, commit + push + PR +
#      squash-merge via the common-pr-* scripts so PRs don't pile up.
set -euo pipefail

for cmd in claude node npm gh git jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Required command not found in PATH: $cmd" >&2
        exit 1
    fi
done

TS=$(date -u '+%Y-%m-%dT%H-%M-%SZ')
BRANCH="chore/linkedin-comments-${TS}"

git fetch origin main
git checkout -B "$BRANCH" origin/main

# ---------------------------------------------------------------- fast gather

FAST_DIR=".claude/skills/linkedin-comment-hourly/fast"
GATHER_OUT="tmp/gather-feed/${TS}"
GATHER_DEADLINE_SECS=300
# Belt-and-suspenders wall clock around the node process itself: the in-process
# deadline should always win; if node wedges anyway (stalled Chrome launch,
# hung subprocess), this watchdog frees the launchd slot instead of blocking
# every later fire. macOS has no coreutils timeout, hence the bash pattern.
GATHER_WATCHDOG_SECS=420

# node_modules is gitignored; the cron worker clone starts clean every fire.
if [ ! -d "$FAST_DIR/node_modules/playwright-core" ]; then
    (cd "$FAST_DIR" && npm install --no-audit --no-fund --silent)
fi

echo "run-hourly: fast gather starting ($(date -u +%H:%M:%SZ))"
set +e
node "$FAST_DIR/gather-feed.mjs" \
    --deadline-secs="$GATHER_DEADLINE_SECS" --out-dir="$GATHER_OUT" &
gather_pid=$!
(
    sleep "$GATHER_WATCHDOG_SECS"
    kill -0 "$gather_pid" 2>/dev/null || exit 0
    echo "run-hourly: fast gather exceeded ${GATHER_WATCHDOG_SECS}s — killing (pid $gather_pid)." >&2
    kill -TERM "$gather_pid" 2>/dev/null || true
    sleep 10
    kill -KILL "$gather_pid" 2>/dev/null || true
    pkill -f 'mcp-chrome-linkedin-ai' 2>/dev/null || true
) &
gather_watchdog_pid=$!
wait "$gather_pid"
gather_exit=$?
kill "$gather_watchdog_pid" 2>/dev/null || true
wait "$gather_watchdog_pid" 2>/dev/null || true
set -e
echo "run-hourly: fast gather exited $gather_exit ($(date -u +%H:%M:%SZ))"

CLAUDE_PROMPT=""
FIRE_FAILED=0
case "$gather_exit" in
    0|10)
        # Exit 0/10 promises a contract — a missing/malformed one is a failure,
        # never silently "0 posts". `|| true` keeps set -e/pipefail from
        # aborting the driver before FIRE_FAILED handling on a failed grep.
        contract="$GATHER_OUT/contract.env"
        posts_found=$(grep '^POSTS_FOUND=' "$contract" 2>/dev/null | head -1 | cut -d= -f2- || true)
        end_reason=$(grep '^GATHER_END_REASON=' "$contract" 2>/dev/null | head -1 | cut -d= -f2- || true)
        if [ ! -f "$contract" ]; then
            echo "run-hourly: gather exited $gather_exit but wrote no contract at $contract; failing." >&2
            FIRE_FAILED=1
        elif ! printf '%s' "$posts_found" | grep -qE '^[0-9]+$'; then
            echo "run-hourly: contract has no numeric POSTS_FOUND (got: '${posts_found}'); failing." >&2
            FIRE_FAILED=1
        elif [ "$posts_found" -gt 0 ]; then
            CLAUDE_PROMPT="run linkedin comment hourly using the pre-gathered contract at ${contract} — do not re-run the gather step"
        else
            echo "run-hourly: gather found 0 draftable posts (end reason: ${end_reason:-unknown}) — skipping drafting, committing any filtered appends." >&2
        fi
        ;;
    30)
        echo "run-hourly: fast gather reported selector drift — falling back to the legacy agent gather." >&2
        CLAUDE_PROMPT="run linkedin comment hourly using the legacy agent gather — the fast gather script reported selector drift"
        ;;
    20)
        echo "run-hourly: AUTH wall — LinkedIn session expired on the shared Chrome profile; failing." >&2
        FIRE_FAILED=1
        ;;
    21)
        echo "run-hourly: Chrome profile is locked by another session; failing (next fire retries)." >&2
        FIRE_FAILED=1
        ;;
    22)
        echo "run-hourly: rate-limited with nothing accepted — committing any filtered appends, then failing." >&2
        FIRE_FAILED=1
        ;;
    23)
        echo "run-hourly: filesystem/jq failure in the fast gather; failing." >&2
        FIRE_FAILED=1
        ;;
    31)
        echo "run-hourly: classifier unusable and nothing accepted — the claude drafting phase would fail too; failing." >&2
        FIRE_FAILED=1
        ;;
    *)
        echo "run-hourly: fast gather failed with unexpected exit $gather_exit; failing." >&2
        FIRE_FAILED=1
        ;;
esac

# ------------------------------------------------------------ drafting phase

if [ -n "$CLAUDE_PROMPT" ]; then
    # CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 disables the 10-minute
    # background-task kill switch — the parallel drafting pipeline (prep-refs +
    # 5 draft agents + Slack) can exceed it, and the legacy gather fallback
    # certainly does.
    export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0

    # Hard wall-clock cap on the whole `claude -p` run. A stalled MCP call can
    # wedge this process indefinitely — and launchd's at-most-one-instance
    # guarantee then silently blocks EVERY later fire until it's killed by hand
    # (a 00:15 fire once hung 19h). macOS ships no coreutils timeout, so guard
    # with a bash watchdog.
    CLAUDE_TIMEOUT_SECS=2400

    run_claude_pipeline() {
      set -o pipefail   # a claude crash must not be masked by jq's exit 0
      # The final stream record carries is_error when the run failed even if
      # the claude process exits 0 — halt_error makes jq exit nonzero so
      # pipefail surfaces it (safe: the result record is terminal anyway).
      echo "$CLAUDE_PROMPT" \
        | claude -p --dangerously-skip-permissions --output-format stream-json --verbose \
        | jq -r --unbuffered '
            (select(.type == "result" and .is_error == true)
              | "ERROR: \(.result // .error // "unknown")" | halt_error(3))
            // .description
            // (.message?.content? | arrays | map(select(.type=="text") | .text) | .[])
            // (select(.is_error == true or .error) | "ERROR: \(.error // .message?.content)")
            // empty
          '
    }

    run_claude_pipeline &
    pipeline_pid=$!

    # Watchdog: after the cap, TERM the pipeline's children (echo/claude/jq)
    # then the subshell, sweep any orphaned Playwright browser, and SIGKILL
    # anything still standing.
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

    # Don't let `set -e` abort on a non-zero pipeline/timeout exit — we still
    # want to commit any drafts already written + posted to Slack before the
    # kill — but a failed/killed drafting run must NOT end the fire green.
    pipeline_status=0
    wait "$pipeline_pid" 2>/dev/null || pipeline_status=$?
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    if [ "$pipeline_status" -ne 0 ]; then
        echo "run-hourly: drafting pipeline exited $pipeline_status — committing partials, marking the fire failed." >&2
        FIRE_FAILED=1
    fi
fi

# ------------------------------------------------------------- commit + PR

# A watchdog kill can land mid-write; never commit a truncated seen-set. Bail if
# comments.json no longer parses (the next fire hard-resets the worker anyway).
if [ -f linkedin-compain/comments.json ] && ! jq empty linkedin-compain/comments.json 2>/dev/null; then
    echo "run-hourly: linkedin-compain/comments.json is not valid JSON — skipping commit/PR." >&2
    exit 1
fi

# git diff --quiet only sees TRACKED changes; git status --porcelain also
# catches untracked files. Filtered appends land even on failed fires, and
# they're worth committing (they're the cross-fire seen-set).
if [ -z "$(git status --porcelain -- linkedin-compain/)" ]; then
    echo "No changes under linkedin-compain/ — skipping commit/PR." >&2
    [ "$FIRE_FAILED" = 1 ] && exit 1
    exit 0
fi

./.claude/skills/common-pr-commit/commit.sh
./.claude/skills/common-pr-update/pr-update.sh
./.claude/skills/common-pr-merge/merge.sh

if [ "$FIRE_FAILED" = 1 ]; then
    echo "run-hourly: changes committed, but the fire had failures (gather exit ${gather_exit}, drafting exit ${pipeline_status:-not-run}) — marking the fire failed." >&2
    exit 1
fi
