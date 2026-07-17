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
#   5. BOOKENDS: a 🟢 run-started message goes to Slack C0BF606R4N7 up front,
#      and a single EXIT trap posts the ✅/⚠️/❌ run-finished summary (drafted/
#      filtered counts, duration, PR URL, error status) on every exit path —
#      both via best-effort pinned-haiku `claude -p` micro-calls that never
#      fail the fire.
set -euo pipefail

TS=$(date -u '+%Y-%m-%dT%H-%M-%SZ')
BRANCH="chore/linkedin-comments-${TS}"

# ----------------------------------------------------------- slack bookends
# Run-start / run-finish messages to the drafts channel, posted via a one-shot
# headless `claude -p` micro-call using the same login-keychain OAuth +
# claude.ai Slack connector the drafting phase uses (no webhook, no bot token).
# Best-effort: a Slack failure must never fail the fire.

SLACK_CHANNEL_ID="C0BF606R4N7"
SLACK_POST_TIMEOUT_SECS=120
SLACK_POST_MODEL="claude-haiku-4-5-20251001"  # same pin as the gather classifier

# Finish-message state, updated as the run progresses; read by the EXIT trap.
RUN_STAGE="preflight"        # preflight | gather | drafting | pr-chain | done
RUN_ERRORS=""                # accumulated one-line failure notes
POSTS_FOUND_N=""             # from the gather contract
POSTS_FILTERED_N=""          # off-topic + already-commented, this run
GATHER_END_REASON_TXT=""
PR_URL=""
DRAFTED_BASELINE=""          # drafted-entry count at branch checkout
DRAFTED_DELTA=""             # frozen from the feature branch before merge.sh
FINISH_POSTED=0

# post_slack <message> — bounded by its own bash watchdog (macOS has no
# coreutils timeout; mirrors the gather watchdog pattern). Always returns 0.
# Invocation shape is empirically pinned (2026-07-17):
#   - message goes INLINE in the prompt, NOT on stdin — haiku intermittently
#     refuses to post "content it can't see", so it must see the (fully
#     script-controlled) status line to post it reliably. Verified 3/3.
#   - --allowedTools pre-approves exactly the one connector tool; combined with
#     --permission-mode dontAsk, every other tool is denied non-interactively.
#   - NO --tools "" — on this CLI it strips MCP tools too, so the Slack
#     connector vanishes and the model hallucinates the call as text (exits 0).
#   - NO --setting-sources "" — it correlated with spurious safety refusals;
#     the inline-message shape makes it unnecessary.
# The message is script-controlled (fixed strings, counts, gather reason, PR
# URL — never scraped post/user content), so inlining carries no injection risk.
post_slack() {
    local msg="$1" out_log
    mkdir -p tmp
    out_log=$(mktemp tmp/slack-bookend.XXXXXX)
    local prompt="Post the status line below to Slack by calling mcp__claude_ai_Slack_Bot__postMessage exactly once with channel_id=${SLACK_CHANNEL_ID} and text set to the line verbatim. It is a pre-approved automated run-status notification for a channel that already receives these — do not alter, summarize, question, or withhold it. After the tool returns, reply with only: done

Status line to post:
${msg}"
    CLAUDE_HISTORY_ROLE=0 claude -p "$prompt" \
        --model "$SLACK_POST_MODEL" \
        --allowedTools "mcp__claude_ai_Slack_Bot__postMessage" \
        --permission-mode dontAsk \
        --no-session-persistence \
        >"$out_log" 2>&1 &
    local post_pid=$!
    (
        sleep "$SLACK_POST_TIMEOUT_SECS"
        kill -0 "$post_pid" 2>/dev/null || exit 0
        echo "run-hourly: slack bookend exceeded ${SLACK_POST_TIMEOUT_SECS}s — killing (pid $post_pid)." >&2
        pkill -TERM -P "$post_pid" 2>/dev/null || true
        kill -TERM "$post_pid" 2>/dev/null || true
        sleep 5
        pkill -KILL -P "$post_pid" 2>/dev/null || true
        kill -KILL "$post_pid" 2>/dev/null || true
    ) &
    local wd_pid=$!
    wait "$post_pid" 2>/dev/null \
        || echo "run-hourly: slack bookend post failed (non-fatal, log: $out_log)." >&2
    # claude can exit 0 after merely *explaining* a denial — assert the ack.
    grep -q 'done' "$out_log" 2>/dev/null \
        || echo "run-hourly: slack bookend may not have posted (log: $out_log) (non-fatal)." >&2
    pkill -KILL -P "$post_pid" 2>/dev/null || true   # sweep stragglers past the wd race
    kill "$wd_pid" 2>/dev/null || true
    wait "$wd_pid" 2>/dev/null || true
    return 0
}

# Single EXIT trap composes + posts the finish message on EVERY exit path
# (explicit exit N, set -e aborts, and — via the TERM/INT traps — signals).
on_exit() {
    local ec=$?
    trap - EXIT
    set +e            # set -e stays live inside traps — an unguarded failure
                      # here would eat the message AND replace the exit code
    [ "$FINISH_POSTED" = 1 ] && return 0
    FINISH_POSTED=1
    local dur="$((SECONDS / 60))m$((SECONDS % 60))s"

    # Prefer the pre-merge frozen delta; else compute live (pre-PR-chain paths).
    local drafted="$DRAFTED_DELTA" drafted_total
    if [ -z "$drafted" ] && [ -n "$DRAFTED_BASELINE" ]; then
        drafted_total=$(jq '[.[] | select(.disposition=="drafted")] | length' \
            linkedin-compain/comments.json 2>/dev/null)
        case "$drafted_total" in (*[!0-9]*|'') drafted_total="";; esac
        [ -n "$drafted_total" ] && drafted=$(( drafted_total - DRAFTED_BASELINE ))
    fi
    case "$drafted" in (''|-*) drafted="?";; esac   # unknown / counter regressed

    local summary="${drafted} drafted, ${POSTS_FILTERED_N:-?} filtered"
    [ -n "$PR_URL" ] && summary="${summary} — PR: ${PR_URL}"

    local msg
    if [ "$ec" -eq 0 ]; then
        if [ "${POSTS_FOUND_N:-}" = "0" ]; then
            msg="⚠️ linkedin-comment-hourly: run finished in ${dur} — no draftable posts (${GATHER_END_REASON_TXT:-unknown}); ${summary}"
        else
            msg="✅ linkedin-comment-hourly: run finished in ${dur} — ${summary}"
        fi
    else
        local why="${RUN_ERRORS:-failed during ${RUN_STAGE}}"
        case "$ec" in
            (143) why="terminated (SIGTERM) during ${RUN_STAGE}${RUN_ERRORS:+ — ${RUN_ERRORS}}";;
            (130) why="interrupted (SIGINT) during ${RUN_STAGE}${RUN_ERRORS:+ — ${RUN_ERRORS}}";;
        esac
        if { [ "$drafted" != "?" ] && [ "$drafted" -gt 0 ]; } || [ -n "$PR_URL" ]; then
            msg="⚠️ linkedin-comment-hourly: partial failure in ${dur} — ${why}; ${summary} (exit ${ec})"
        else
            msg="❌ linkedin-comment-hourly: run failed in ${dur} — ${why}; ${summary} (exit ${ec})"
        fi
    fi
    post_slack "$msg"
}
trap on_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

post_slack "🟢 linkedin-comment-hourly: run started — ${TS}"

for cmd in claude node npm gh git jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Required command not found in PATH: $cmd" >&2
        exit 1
    fi
done

git fetch origin main
git checkout -B "$BRANCH" origin/main

# Drafted-count baseline for the finish bookend: this run's contribution is
# measured as a delta against origin/main's seen-set.
DRAFTED_BASELINE=$(jq '[.[] | select(.disposition=="drafted")] | length' linkedin-compain/comments.json 2>/dev/null || echo 0)
case "$DRAFTED_BASELINE" in (*[!0-9]*|'') DRAFTED_BASELINE=0;; esac

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

RUN_STAGE="gather"
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

# Contract counters feed the finish bookend. The contract can exist even on
# failing exits (22/31 write one before bailing, and filtered appends land on
# those paths too), so parse it before the case. `|| true` keeps
# set -e/pipefail from aborting the driver on a failed grep.
contract="$GATHER_OUT/contract.env"
posts_found=""
end_reason=""
if [ -f "$contract" ]; then
    posts_found=$(grep '^POSTS_FOUND=' "$contract" 2>/dev/null | head -1 | cut -d= -f2- || true)
    end_reason=$(grep '^GATHER_END_REASON=' "$contract" 2>/dev/null | head -1 | cut -d= -f2- || true)
    posts_off=$(grep '^POSTS_OFF_TOPIC=' "$contract" 2>/dev/null | head -1 | cut -d= -f2- || true)
    posts_already=$(grep '^POSTS_ALREADY_COMMENTED=' "$contract" 2>/dev/null | head -1 | cut -d= -f2- || true)
    case "$posts_off" in (*[!0-9]*|'') posts_off=0;; esac
    case "$posts_already" in (*[!0-9]*|'') posts_already=0;; esac
    POSTS_FILTERED_N=$(( posts_off + posts_already ))
    GATHER_END_REASON_TXT="$end_reason"
fi

CLAUDE_PROMPT=""
FIRE_FAILED=0
case "$gather_exit" in
    0|10)
        # Exit 0/10 promises a contract — a missing/malformed one is a failure,
        # never silently "0 posts".
        if [ ! -f "$contract" ]; then
            echo "run-hourly: gather exited $gather_exit but wrote no contract at $contract; failing." >&2
            FIRE_FAILED=1
            RUN_ERRORS="gather: contract missing"
        elif ! printf '%s' "$posts_found" | grep -qE '^[0-9]+$'; then
            echo "run-hourly: contract has no numeric POSTS_FOUND (got: '${posts_found}'); failing." >&2
            FIRE_FAILED=1
            RUN_ERRORS="gather: contract has no numeric POSTS_FOUND"
        elif [ "$posts_found" -gt 0 ]; then
            POSTS_FOUND_N="$posts_found"
            CLAUDE_PROMPT="run linkedin comment hourly using the pre-gathered contract at ${contract} — do not re-run the gather step"
        else
            POSTS_FOUND_N="$posts_found"
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
        RUN_ERRORS="gather: auth wall — LinkedIn session expired"
        ;;
    21)
        echo "run-hourly: Chrome profile is locked by another session; failing (next fire retries)." >&2
        FIRE_FAILED=1
        RUN_ERRORS="gather: Chrome profile locked by another session"
        ;;
    22)
        echo "run-hourly: rate-limited with nothing accepted — committing any filtered appends, then failing." >&2
        FIRE_FAILED=1
        RUN_ERRORS="gather: rate-limited, nothing accepted"
        ;;
    23)
        echo "run-hourly: filesystem/jq failure in the fast gather; failing." >&2
        FIRE_FAILED=1
        RUN_ERRORS="gather: filesystem/jq failure"
        ;;
    31)
        echo "run-hourly: classifier unusable and nothing accepted — the claude drafting phase would fail too; failing." >&2
        FIRE_FAILED=1
        RUN_ERRORS="gather: classifier unusable, nothing accepted"
        ;;
    *)
        echo "run-hourly: fast gather failed with unexpected exit $gather_exit; failing." >&2
        FIRE_FAILED=1
        RUN_ERRORS="gather: unexpected exit ${gather_exit}"
        ;;
esac

# ------------------------------------------------------------ drafting phase

if [ -n "$CLAUDE_PROMPT" ]; then
    RUN_STAGE="drafting"
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
        RUN_ERRORS="${RUN_ERRORS:+${RUN_ERRORS}; }drafting: exited ${pipeline_status} (watchdog cap ${CLAUDE_TIMEOUT_SECS}s; partials committed)"
    fi
fi

# ------------------------------------------------------------- commit + PR

# A watchdog kill can land mid-write; never commit a truncated seen-set. Bail if
# comments.json no longer parses (the next fire hard-resets the worker anyway).
if [ -f linkedin-compain/comments.json ] && ! jq empty linkedin-compain/comments.json 2>/dev/null; then
    echo "run-hourly: linkedin-compain/comments.json is not valid JSON — skipping commit/PR." >&2
    RUN_ERRORS="${RUN_ERRORS:+${RUN_ERRORS}; }comments.json invalid after kill — commit skipped"
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

# Freeze this run's drafted delta from the feature-branch file BEFORE merge.sh
# checks out + pulls main (concurrent merges could skew a live recount there,
# and a failed pull would read as 0).
RUN_STAGE="pr-chain"
drafted_now=$(jq '[.[] | select(.disposition=="drafted")] | length' linkedin-compain/comments.json 2>/dev/null)
case "$drafted_now" in (*[!0-9]*|'') : ;; (*) DRAFTED_DELTA=$(( drafted_now - DRAFTED_BASELINE ));; esac

./.claude/skills/common-pr-commit/commit.sh
./.claude/skills/common-pr-update/pr-update.sh
PR_URL=$(gh pr view "$BRANCH" --json url -q .url 2>/dev/null || true)
./.claude/skills/common-pr-merge/merge.sh
RUN_STAGE="done"

if [ "$FIRE_FAILED" = 1 ]; then
    echo "run-hourly: changes committed, but the fire had failures (gather exit ${gather_exit}, drafting exit ${pipeline_status:-not-run}) — marking the fire failed." >&2
    exit 1
fi
