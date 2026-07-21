#!/usr/bin/env bash
# Scheduled LinkedIn comment-ideas drop, driven non-interactively by the
# linkedin-comment-hourly GitHub Actions workflow on a self-hosted macOS
# runner (Tue–Fri 04:00 UTC; mirrors linkedin-stats/run-weekly.sh).
#
# Built on .claude/skills/pipeline-shared/lib.sh (Template Method + Strategy:
# the lib owns the attempt-loop skeleton, watchdogs, heal-session runner and
# Slack micro-call; this driver supplies the policy hooks and owns trap
# composition, the fallback/drafting phases, and the commit strategy).
#
# Flow:
#   1. Branch off origin/main.
#   2. FAST GATHER under the self-heal attempt loop: up to MAX_ATTEMPTS runs
#      of the deterministic feed scraper
#      (.claude/skills/linkedin-comment-hourly/fast/gather-feed.mjs), each
#      with a fresh --out-dir and, on retries, linkedin-compain/ reset to the
#      committed baseline (the gather appends filtered entries to the
#      seen-set mid-scrape — a retry must verify against clean state, and
#      the final tree must be ONE attempt's coherent output). Exit policy:
#      0/10 with a valid contract → accept; 0/10 with a missing/malformed
#      contract, 23, or unknown exits → heal session (MAX_HEALS=1, ~30 min)
#      then retry; 21 → sweep once, heal on the second; 20 (auth), 22
#      (rate-limit), 31 (classifier down — another `claude -p` can't heal
#      that) → fail fast, no heal; 30 (selector drift) → legacy-agent
#      FALLBACK first (drafts must ship), then ONE post-landing heal session
#      AFTER the data is safely merged — its fix is unverified until the
#      next fire and lands on a review PR. An accepted contract with
#      PERMALINKS_MISSING>0 (a draft would ship without its post link) is
#      ALSO an error: the fire goes ⚠️ and gets the same post-landing heal.
#   3. DRAFTING: invoke the linkedin-comment-hourly skill via `claude -p`
#      pointing at the accepted contract (or the legacy gather on fallback).
#      Skipped entirely when the gather found 0 draftable posts.
#   4. COMMIT: unhealed fires keep today's single auto-merged PR. Healed
#      fires SPLIT: the linkedin-compain/ data commit auto-merges (Slack
#      already received the drafts — the cross-fire seen-set must reach main
#      or the next fire re-drafts the same posts), while the heal's code
#      changes + incident doc go to a separate `heal/…` PR left OPEN for
#      review (same review-gate philosophy as the weekly pipeline).
#   5. BOOKENDS: a 🟢 run-started message goes to Slack C0BF606R4N7 up front,
#      and a single EXIT trap posts the ✅/⚠️/❌ run-finished summary (drafted/
#      filtered counts, duration, PR URLs, heal status) on every exit path —
#      best-effort pinned-haiku micro-calls that never fail the fire.
#
# Test hooks (all default to production values): FAST_DIR, MAX_ATTEMPTS,
# MAX_HEALS, GATHER_DEADLINE_SECS, GATHER_WATCHDOG_SECS, HEAL_TIMEOUT_SECS,
# HEAL_CUTOFF_SECS, CLAUDE_TIMEOUT_SECS, CLAUDE_BIN, and DRY_RUN=1 (skip
# branch checkout and every commit/PR chain). NOTE: bookends still post
# unless CLAUDE_BIN points at a stub — the offline harness always stubs it.
set -euo pipefail

# Re-exec from a detached copy so a heal session may safely edit the tracked
# run-hourly.sh (bash reads its script file incrementally — editing the
# executing file corrupts the run). Such edits are unverified until the next
# fire — the incident doc must say so. The minimal trap covers a failed lib
# source; on_exit takes over the EXIT slot below.
case "$0" in
  */run-hourly-exec-*.sh)
    trap 'rm -f "$0"' EXIT
    ;;
  *)
    mkdir -p tmp
    cp "$0" "tmp/run-hourly-exec-$$.sh"
    exec bash "tmp/run-hourly-exec-$$.sh" "$@"
    ;;
esac

SKILL_DIR=".claude/skills/linkedin-comment-hourly"
SHARED_DIR=".claude/skills/pipeline-shared"
. "$SHARED_DIR/lib.sh"

TS=$(date -u '+%Y-%m-%dT%H-%M-%SZ')
BRANCH="chore/linkedin-comments-${TS}"
TODAY=$(date -u +%Y-%m-%d)
INCIDENT_FILE="doc/incidents/${TODAY}-linkedin-comment-hourly.md"
HEAL_ROOT="tmp/self-heal/${TS}"
mkdir -p "$HEAL_ROOT"

FAST_DIR="${FAST_DIR:-$SKILL_DIR/fast}"
DRY_RUN="${DRY_RUN:-0}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
# ONE heal max: this is a morning delivery pipeline, not the weekly scrape —
# a second 30-min heal would push drafts past breakfast.
MAX_HEALS="${MAX_HEALS:-1}"
HEAL_TIMEOUT_SECS="${HEAL_TIMEOUT_SECS:-1800}"
# Don't START a heal this late into the fire: the drafting phase + PR chains
# + the finish bookend must still fit under the workflow's timeout-minutes.
HEAL_CUTOFF_SECS="${HEAL_CUTOFF_SECS:-6600}"
GATHER_DEADLINE_SECS="${GATHER_DEADLINE_SECS:-300}"
# Belt-and-suspenders wall clock around the node process itself: the
# in-process deadline should always win; if node wedges anyway (stalled
# Chrome launch, hung subprocess), the watchdog frees the runner slot.
GATHER_WATCHDOG_SECS="${GATHER_WATCHDOG_SECS:-420}"
CLAUDE_TIMEOUT_SECS="${CLAUDE_TIMEOUT_SECS:-2400}"
LOCK_RETRY_SLEEP_SECS="${LOCK_RETRY_SLEEP_SECS:-60}"

PL_LOG_PREFIX="run-hourly"
PL_PIPELINE_NAME="linkedin-comment-hourly"
PL_HEAL_ROOT="$HEAL_ROOT"
PL_INCIDENT_FILE="$INCIDENT_FILE"
PL_MAX_ATTEMPTS="$MAX_ATTEMPTS"
PL_MAX_HEALS="$MAX_HEALS"
PL_HEAL_TIMEOUT_SECS="$HEAL_TIMEOUT_SECS"
PL_HEAL_CUTOFF_SECS="$HEAL_CUTOFF_SECS"
PL_HEAL_ROLE="comments-heal"
PL_SLACK_CHANNEL_ID="C0BF606R4N7"
PL_SESSION_NOTES=()

# ----------------------------------------------------------- slack bookends
# Posted via the lib's pl_post_slack (the empirically pinned haiku micro-call
# shape lives there now — see lib.sh). Best-effort: a Slack failure must
# never fail the fire.

# Finish-message state, updated as the run progresses; read by the EXIT trap.
RUN_STAGE="preflight"        # preflight | gather | drafting | pr-chain | post-landing-heal | heal-pr | done
RUN_ERRORS=""                # accumulated one-line failure notes
POSTS_FOUND_N=""             # from the gather contract
POSTS_FILTERED_N=""          # off-topic + already-commented, this run
GATHER_END_REASON_TXT=""
PR_URL=""                    # data PR (auto-merged)
CODE_PR_URL=""               # heal PR (left open)
DRAFTED_BASELINE=""          # drafted-entry count at branch checkout
DRAFTED_DELTA=""             # frozen from the feature branch before merge.sh
FINISH_POSTED=0
HEAL_MODE="in-loop"
FALLBACK_USED=0              # exit 30 → legacy gather (fast path unverified)
HEAL_RESULT=""               # post-landing heal: completed | timed out | failed | aborted | skipped
PERMALINKS_MISSING_N=0       # accepted posts whose permalink capture failed (contract)
PERMALINK_HEAL=0             # missing permalinks → error + post-landing heal

# Single EXIT trap composes + posts the finish message on EVERY exit path
# (explicit exit N, set -e aborts, and — via the TERM/INT traps — signals).
on_exit() {
    local ec=$?
    trap - EXIT
    set +e            # set -e stays live inside traps — an unguarded failure
                      # here would eat the message AND replace the exit code
    # rm before the network call: a hung Slack post must not leak the copy.
    case "$0" in */run-hourly-exec-*.sh) rm -f "$0";; esac
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
    if [ "${PL_HEAL_COUNT:-0}" -gt 0 ]; then
        summary="${summary}; self-heal ×${PL_HEAL_COUNT} (${HEAL_MODE}${HEAL_RESULT:+, ${HEAL_RESULT}})${CODE_PR_URL:+ — heal PR awaiting review: ${CODE_PR_URL}}"
    elif [ "${FALLBACK_USED:-0}" = 1 ]; then
        summary="${summary}; fast gather NOT healed (${HEAL_RESULT:-skipped})"
    elif [ "${PERMALINK_HEAL:-0}" = 1 ]; then
        summary="${summary}; permalink failure NOT healed (${HEAL_RESULT:-skipped})"
    fi

    local msg
    if [ "$ec" -eq 0 ]; then
        if [ "${POSTS_FOUND_N:-}" = "0" ]; then
            msg="⚠️ linkedin-comment-hourly: run finished in ${dur} — no draftable posts ($(pl_oneline "${GATHER_END_REASON_TXT:-unknown}")); ${summary}"
        elif [ "${FALLBACK_USED:-0}" = 1 ]; then
            msg="⚠️ linkedin-comment-hourly: run finished in ${dur} (selector drift — legacy fallback shipped the drafts) — ${summary}"
        elif [ "${PERMALINK_HEAL:-0}" = 1 ]; then
            msg="⚠️ linkedin-comment-hourly: run finished in ${dur} (permalink capture FAILED on ${PERMALINKS_MISSING_N} accepted post(s) — drafts shipped) — ${summary}"
        elif [ "${PL_HEAL_COUNT:-0}" -gt 0 ]; then
            msg="⚠️ linkedin-comment-hourly: run finished in ${dur} (self-healed) — ${summary}"
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
            msg="⚠️ linkedin-comment-hourly: partial failure in ${dur} — $(pl_oneline "$why"); ${summary} (exit ${ec})"
        else
            msg="❌ linkedin-comment-hourly: run failed in ${dur} — $(pl_oneline "$why"); ${summary} (exit ${ec})"
        fi
    fi
    [ "$DRY_RUN" = 1 ] && msg="${msg} [DRY_RUN]"
    pl_post_slack "$msg"
}
trap on_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

pl_post_slack "🟢 linkedin-comment-hourly: run started — ${TS}"

pl_require_cmds claude node npm gh git jq
pl_codex_available

if [ "$DRY_RUN" != 1 ]; then
    git fetch origin main
    git checkout -B "$BRANCH" origin/main
fi
# Immutable reset anchor for retries and the split-landing guards:
# `git checkout -- <path>` restores from the INDEX (which a heal session
# could have polluted), not from this commit.
BASE_SHA=$(git rev-parse HEAD)

# Drafted-count baseline for the finish bookend: this run's contribution is
# measured as a delta against origin/main's seen-set.
DRAFTED_BASELINE=$(jq '[.[] | select(.disposition=="drafted")] | length' linkedin-compain/comments.json 2>/dev/null || echo 0)
case "$DRAFTED_BASELINE" in (*[!0-9]*|'') DRAFTED_BASELINE=0;; esac

pl_npm_ensure "$FAST_DIR"

# ------------------------------------------------------------ strategy hooks

pipeline_heal_prompt() {
  PL_HEAL_PROMPT=$(cat <<EOF
You are the self-healing layer of the linkedin-comment-hourly pipeline,
invoked headless by run-hourly.sh on the self-hosted runner after a failed
gather attempt. Read ${SHARED_DIR}/references/self-heal-core.md first, then
the overlay at OVERLAY_FILE, and follow them exactly.
Context:
PIPELINE_NAME=linkedin-comment-hourly
OVERLAY_FILE=${SKILL_DIR}/references/self-heal.md
WRAPPER=${SKILL_DIR}/run-hourly.sh
HEAL_MODE=${HEAL_MODE}
ATTEMPT=${PL_ATTEMPT}/${MAX_ATTEMPTS}
HEAL_COUNT=${PL_HEAL_COUNT}
EXIT_CODE=${PL_ATTEMPT_EXIT}
LOG_FILE=${PL_ATTEMPT_LOG}
HEAL_DIR=${HEAL_ROOT}
INCIDENT_FILE=${INCIDENT_FILE}
CODEX_AVAILABLE=${PL_CODEX_AVAILABLE}
FAST_DIR=${FAST_DIR}
GATHER_OUT=${GATHER_OUT:-}
PERMALINKS_MISSING=${PERMALINKS_MISSING_N:-0}
COMMENTS_FILE=./linkedin-compain/comments.json
TS=${TS}
EOF
)
}

pipeline_reset_baseline() {
  # The gather appends filtered entries to the seen-set WHILE scraping, so a
  # failed attempt leaves partial state behind. Retries must start from the
  # committed baseline: a healed rerun that sees the previous attempt's
  # appends is verifying against different input (it could return 0 posts
  # and "pass" without exercising the bug), and the final tree must be ONE
  # attempt's coherent output, never a cross-attempt hybrid. Restore from
  # the immutable BASE_SHA (the index is not trustworthy after a heal
  # session) and fail LOUD if the reset didn't take.
  git checkout -q "$BASE_SHA" -- linkedin-compain/
  git clean -qfd linkedin-compain/
  if [ -n "$(git status --porcelain -- linkedin-compain/)" ]; then
    echo "run-hourly: linkedin-compain/ did not reset cleanly to ${BASE_SHA} — aborting." >&2
    exit 1
  fi
}

pipeline_run_attempt() {
  local marker="$HEAL_ROOT/timeout-gather-${PL_ATTEMPT}" pid wd attempt_start
  attempt_start=$SECONDS
  # Fresh out-dir per attempt: a healed rerun must not be able to read (or
  # half-overwrite) a stale contract from the failed attempt.
  GATHER_OUT="tmp/gather-feed/${TS}-a${PL_ATTEMPT}"
  echo "run-hourly: fast gather attempt ${PL_ATTEMPT}/${MAX_ATTEMPTS} starting ($(date -u +%H:%M:%SZ))"
  set +e
  (
    node "$FAST_DIR/gather-feed.mjs" \
      --deadline-secs="$GATHER_DEADLINE_SECS" --out-dir="$GATHER_OUT" 2>&1 | tee "$PL_ATTEMPT_LOG"
    exit "${PIPESTATUS[0]}"
  ) &
  pid=$!
  pl_spawn_killer "$GATHER_WATCHDOG_SECS" "$pid" "fast gather (attempt ${PL_ATTEMPT})" "$marker"
  wd=$!
  pl_await_target "$pid" "$wd" "$marker"
  PL_ATTEMPT_EXIT=$?
  set -e
  local timed_out_note=""
  [ -f "$marker" ] && timed_out_note=", KILLED at watchdog cap"
  attempt_summaries+=("attempt ${PL_ATTEMPT}: exit ${PL_ATTEMPT_EXIT}, $(( SECONDS - attempt_start ))s${timed_out_note}")
  echo "run-hourly: fast gather attempt ${PL_ATTEMPT} exited ${PL_ATTEMPT_EXIT} ($(date -u +%H:%M:%SZ))"
}

# Exit 0/10 promises a usable contract — a missing/malformed one is a scraper
# bug (never silently "0 posts"), which is exactly what the heal loop is for.
# Sets CONTRACT_OK plus the bookend counters. `|| true` keeps set -e/pipefail
# from aborting the driver on a failed grep. Never `source` the contract —
# it holds scraped values, not trusted shell.
validate_contract() {
  local contract="$GATHER_OUT/contract.env" posts_found end_reason posts_off posts_already i tf k a contract_out
  CONTRACT_OK=0
  CONTRACT_NOTE=""
  if [ ! -f "$contract" ]; then
    CONTRACT_NOTE="contract missing at ${contract}"
    return 0
  fi
  posts_found=$(grep '^POSTS_FOUND=' "$contract" 2>/dev/null | head -1 | cut -d= -f2- || true)
  end_reason=$(grep '^GATHER_END_REASON=' "$contract" 2>/dev/null | head -1 | cut -d= -f2- || true)
  posts_off=$(grep '^POSTS_OFF_TOPIC=' "$contract" 2>/dev/null | head -1 | cut -d= -f2- || true)
  posts_already=$(grep '^POSTS_ALREADY_COMMENTED=' "$contract" 2>/dev/null | head -1 | cut -d= -f2- || true)
  contract_out=$(grep '^OUT_DIR=' "$contract" 2>/dev/null | head -1 | cut -d= -f2- || true)
  if ! printf '%s' "$posts_found" | grep -qE '^[0-9]+$'; then
    CONTRACT_NOTE="contract has no numeric POSTS_FOUND (got: '${posts_found}')"
    return 0
  fi
  # Provenance: the contract must be THIS attempt's output, not a stale one
  # (the mjs resolves --out-dir to an absolute path, so match on the tail).
  case "$contract_out" in
    "$GATHER_OUT"|*"/$GATHER_OUT") : ;;
    *)
      CONTRACT_NOTE="contract OUT_DIR '${contract_out}' is not this attempt's ${GATHER_OUT}"
      return 0
      ;;
  esac
  # Every promised post must carry its identity (KEY + AUTHOR) and a body
  # file that exists INSIDE this attempt's dir — the draft agents take these
  # on faith. (URL/URN/HEADLINE may legitimately be "-", so not enforced.)
  i=1
  while [ "$i" -le "$posts_found" ]; do
    tf=$(grep "^POST_${i}_TEXT_FILE=" "$contract" 2>/dev/null | head -1 | cut -d= -f2- || true)
    k=$(grep "^POST_${i}_KEY=" "$contract" 2>/dev/null | head -1 | cut -d= -f2- || true)
    a=$(grep "^POST_${i}_AUTHOR=" "$contract" 2>/dev/null | head -1 | cut -d= -f2- || true)
    if [ -z "$k" ] || [ -z "$a" ]; then
      CONTRACT_NOTE="POST_${i} is missing KEY or AUTHOR"
      return 0
    fi
    if [ -z "$tf" ] || [ ! -s "$tf" ]; then
      CONTRACT_NOTE="POST_${i}_TEXT_FILE missing or empty (got: '${tf}')"
      return 0
    fi
    case "$tf" in
      "$GATHER_OUT"/*|*"/$GATHER_OUT/"*) : ;;
      *)
        CONTRACT_NOTE="POST_${i}_TEXT_FILE '${tf}' is outside this attempt's ${GATHER_OUT}"
        return 0
        ;;
    esac
    i=$((i + 1))
  done
  case "$posts_off" in (*[!0-9]*|'') posts_off=0;; esac
  case "$posts_already" in (*[!0-9]*|'') posts_already=0;; esac
  # PERMALINKS_MISSING is an error SIGNAL, not a contract breaker (absent in
  # pre-2026-07-21 contracts → 0): >0 flags the fire and schedules a
  # post-landing heal, but the drafts still ship.
  permalinks_missing=$(grep '^PERMALINKS_MISSING=' "$contract" 2>/dev/null | head -1 | cut -d= -f2- || true)
  case "$permalinks_missing" in (*[!0-9]*|'') permalinks_missing=0;; esac
  PERMALINKS_MISSING_N="$permalinks_missing"
  POSTS_FOUND_N="$posts_found"
  POSTS_FILTERED_N=$(( posts_off + posts_already ))
  GATHER_END_REASON_TXT="$end_reason"
  CONTRACT_OK=1
  return 0
}

pipeline_classify() {
  [ "$PL_ATTEMPT_EXIT" -ne 21 ] && consecutive_lock=0
  case "$PL_ATTEMPT_EXIT" in
    0|10)
      validate_contract
      if [ "$CONTRACT_OK" = 1 ]; then
        PL_VERDICT=accept
      else
        echo "run-hourly: gather exited ${PL_ATTEMPT_EXIT} but its contract is unusable (${CONTRACT_NOTE}) — scraper bug; healing." >&2
        RUN_ERRORS="${RUN_ERRORS:+${RUN_ERRORS}; }gather attempt ${PL_ATTEMPT}: ${CONTRACT_NOTE}"
        PL_VERDICT=heal
      fi
      ;;
    30)
      echo "run-hourly: fast gather reported selector drift — legacy fallback ships the drafts first; the fast path gets a post-landing heal." >&2
      PL_VERDICT=fallback
      ;;
    20)
      echo "run-hourly: AUTH wall — LinkedIn session expired on the shared Chrome profile; failing (needs Peter's interactive relogin, no heal can fix it)." >&2
      RUN_ERRORS="${RUN_ERRORS:+${RUN_ERRORS}; }gather: auth wall — LinkedIn session expired"
      PL_VERDICT=fail
      ;;
    22)
      echo "run-hourly: rate-limited with nothing accepted — committing any filtered appends, then failing (time is the only fix; next fire is tomorrow)." >&2
      RUN_ERRORS="${RUN_ERRORS:+${RUN_ERRORS}; }gather: rate-limited, nothing accepted"
      PL_VERDICT=fail
      ;;
    31)
      # A broken `claude -p` classifier cannot be healed by another
      # `claude -p` session, and the drafting phase would fail the same way.
      echo "run-hourly: classifier unusable and nothing accepted — failing without a heal (the healer runs on the same claude -p)." >&2
      RUN_ERRORS="${RUN_ERRORS:+${RUN_ERRORS}; }gather: classifier unusable, nothing accepted"
      PL_VERDICT=fail
      ;;
    21)
      consecutive_lock=$((consecutive_lock + 1))
      if [ "$consecutive_lock" -ge 2 ]; then
        # The sweep didn't free the profile — something is actively holding
        # it; that needs diagnosis, not another blind pkill.
        RUN_ERRORS="${RUN_ERRORS:+${RUN_ERRORS}; }gather: profile still locked after sweep"
        PL_VERDICT=heal
      else
        echo "run-hourly: profile locked — sweeping orphaned Chrome and retrying in ${LOCK_RETRY_SLEEP_SECS}s."
        PL_VERDICT=retry
        PL_RETRY_SECS="$LOCK_RETRY_SLEEP_SECS"
        PL_RETRY_SWEEP=1
      fi
      ;;
    23)
      RUN_ERRORS="${RUN_ERRORS:+${RUN_ERRORS}; }gather: filesystem/jq failure"
      PL_VERDICT=heal
      ;;
    *)
      RUN_ERRORS="${RUN_ERRORS:+${RUN_ERRORS}; }gather: unexpected exit ${PL_ATTEMPT_EXIT}"
      PL_VERDICT=heal
      ;;
  esac
}

# ---------------------------------------------------------------- fast gather

attempt_summaries=()
consecutive_lock=0
RUN_STAGE="gather"
pl_attempt_loop

CLAUDE_PROMPT=""
FIRE_FAILED=0
POST_LANDING_HEAL=0
case "$PL_OUTCOME" in
  accept)
    # An accepted post without a permalink is an ERROR (user-mandated
    # 2026-07-21: a draft reached Slack as "no stable permalink" for a post
    # that had one), but a morning-delivery error: the drafts still ship
    # first, then the self-heal loop engages post-landing — same philosophy
    # as the exit-30 fallback, and an in-loop retry couldn't rerun-verify a
    # fix anyway (the feed has moved on by the retry).
    if [ "${PERMALINKS_MISSING_N:-0}" -gt 0 ]; then
      echo "run-hourly: ${PERMALINKS_MISSING_N} accepted post(s) have no permalink — treating as an error; post-landing heal after the drafts land." >&2
      RUN_ERRORS="${RUN_ERRORS:+${RUN_ERRORS}; }gather: ${PERMALINKS_MISSING_N} accepted post(s) missing permalinks"
      POST_LANDING_HEAL=1
      PERMALINK_HEAL=1
    fi
    if [ "${POSTS_FOUND_N:-0}" -gt 0 ]; then
      CLAUDE_PROMPT="run linkedin comment hourly using the pre-gathered contract at ${GATHER_OUT}/contract.env — do not re-run the gather step"
    else
      echo "run-hourly: gather found 0 draftable posts (end reason: ${GATHER_END_REASON_TXT:-unknown}) — skipping drafting, committing any filtered appends." >&2
    fi
    ;;
  fallback)
    CLAUDE_PROMPT="run linkedin comment hourly using the legacy agent gather — the fast gather script reported selector drift"
    POST_LANDING_HEAL=1
    FALLBACK_USED=1
    ;;
  aborted)
    FIRE_FAILED=1
    RUN_ERRORS="${RUN_ERRORS:+${RUN_ERRORS}; }heal session aborted the loop: ${PL_ABORT_REASON}"
    ;;
  *)
    FIRE_FAILED=1
    RUN_ERRORS="${RUN_ERRORS:+${RUN_ERRORS}; }gather loop ended: ${PL_OUTCOME} (last exit ${PL_ATTEMPT_EXIT})"
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

    run_claude_pipeline() {
      set -o pipefail   # a claude crash must not be masked by jq's exit 0
      # The final stream record carries is_error when the run failed even if
      # the claude process exits 0 — halt_error makes jq exit nonzero so
      # pipefail surfaces it (safe: the result record is terminal anyway).
      echo "$CLAUDE_PROMPT" \
        | "${CLAUDE_BIN:-claude}" -p --dangerously-skip-permissions --output-format stream-json --verbose \
        | jq -r --unbuffered '
            (select(.type == "result" and .is_error == true)
              | "ERROR: \(.result // .error // "unknown")" | halt_error(3))
            // .description
            // (.message?.content? | arrays | map(select(.type=="text") | .text) | .[])
            // (select(.is_error == true or .error) | "ERROR: \(.error // .message?.content)")
            // empty
          '
    }

    # Hard wall-clock cap on the whole `claude -p` run. A stalled MCP call
    # can wedge this process indefinitely (a launchd-era 00:15 fire once hung
    # 19h). The workflow's timeout-minutes is the outer backstop, but only
    # THIS watchdog still commits partial drafts + sweeps the orphaned
    # browser — a runner-level kill loses both.
    drafting_marker="$HEAL_ROOT/timeout-drafting"
    set +e
    run_claude_pipeline &
    pipeline_pid=$!
    pl_spawn_killer "$CLAUDE_TIMEOUT_SECS" "$pipeline_pid" "claude drafting" "$drafting_marker"
    drafting_wd=$!
    pl_await_target "$pipeline_pid" "$drafting_wd" "$drafting_marker"
    pipeline_status=$?
    set -e
    # A failed/killed drafting run must NOT end the fire green — but we still
    # commit any drafts already written + posted to Slack before the kill.
    if [ "$pipeline_status" -ne 0 ]; then
        echo "run-hourly: drafting pipeline exited $pipeline_status — committing partials, marking the fire failed." >&2
        FIRE_FAILED=1
        RUN_ERRORS="${RUN_ERRORS:+${RUN_ERRORS}; }drafting: exited ${pipeline_status} (watchdog cap ${CLAUDE_TIMEOUT_SECS}s; partials committed)"
    fi
fi

# ------------------------------------------------------------- commit + PR

# A watchdog kill can land mid-write; never commit a truncated seen-set.
if [ -f linkedin-compain/comments.json ] && ! jq empty linkedin-compain/comments.json 2>/dev/null; then
    if [ "${PL_HEAL_COUNT:-0}" -gt 0 ]; then
        # A healed fire must still ship its fix + incident — revert the
        # corrupt data instead of bailing (the heal work outlives the appends).
        git checkout -- linkedin-compain/comments.json 2>/dev/null || true
        echo "run-hourly: comments.json invalid after kill — reverted; data not committed this fire." >&2
        RUN_ERRORS="${RUN_ERRORS:+${RUN_ERRORS}; }comments.json invalid after kill — data reverted"
        FIRE_FAILED=1
    else
        echo "run-hourly: linkedin-compain/comments.json is not valid JSON — skipping commit/PR." >&2
        RUN_ERRORS="${RUN_ERRORS:+${RUN_ERRORS}; }comments.json invalid after kill — commit skipped"
        exit 1
    fi
fi

# Freeze this run's drafted delta from the feature-branch file BEFORE any
# merge.sh checks out + pulls main (concurrent merges could skew a live
# recount there, and a failed pull would read as 0).
freeze_drafted_delta() {
    local drafted_now
    drafted_now=$(jq '[.[] | select(.disposition=="drafted")] | length' linkedin-compain/comments.json 2>/dev/null)
    case "$drafted_now" in (*[!0-9]*|'') : ;; (*) DRAFTED_DELTA=$(( drafted_now - DRAFTED_BASELINE ));; esac
    return 0
}

# Unhealed fires: today's single auto-merged PR (git status --porcelain also
# catches untracked files; filtered appends land even on failed fires —
# they're the cross-fire seen-set).
land_data_normal() {
    if [ -z "$(git status --porcelain -- linkedin-compain/)" ]; then
        echo "No changes under linkedin-compain/ — skipping commit/PR." >&2
        return 0
    fi
    RUN_STAGE="pr-chain"
    freeze_drafted_delta
    if [ "$DRY_RUN" = 1 ]; then
        echo "run-hourly: DRY_RUN — would commit + PR + merge."
        return 0
    fi
    ./.claude/skills/common-pr-commit/commit.sh
    ./.claude/skills/common-pr-update/pr-update.sh
    PR_URL=$(gh pr view "$BRANCH" --json url -q .url 2>/dev/null || true)
    ./.claude/skills/common-pr-merge/merge.sh
    return 0
}

# Healed fires: the data commit must still reach main — Slack already
# received the drafts, and an unmerged seen-set would make the next fire
# re-draft (and re-post) the same posts. Only linkedin-compain/ goes into
# this auto-merged PR; the heal's code + incident stay behind for review.
# Deterministic commit/PR copy: no claude in this path (commit.sh stages
# everything with `git add .`, which would drag the unreviewed fix along).
land_data_split() {
    if [ -z "$(git status --porcelain -- linkedin-compain/)" ]; then
        echo "run-hourly: no data changes to land from this healed fire — skipping the data PR." >&2
        return 0
    fi
    RUN_STAGE="pr-chain"
    freeze_drafted_delta
    if [ "$DRY_RUN" = 1 ]; then
        echo "run-hourly: DRY_RUN — would land data PR (auto-merged) + keep code for the heal PR."
        return 0
    fi
    # The auto-merge is only safe if this commit is PROVABLY data-only. A
    # heal session that (against the protocol) moved HEAD, switched branches,
    # or staged code must not ride an unreviewed commit onto main — on any
    # violated invariant, refuse the auto-merge and let everything land
    # review-gated on the heal/ PR instead.
    if [ "$(git branch --show-current)" != "$BRANCH" ] || [ "$(git rev-parse HEAD)" != "$BASE_SHA" ]; then
        echo "run-hourly: branch/HEAD moved during healing — refusing the data auto-merge; everything goes to the review PR." >&2
        RUN_ERRORS="${RUN_ERRORS:+${RUN_ERRORS}; }data auto-merge refused (branch/HEAD moved during heal)"
        return 0
    fi
    git reset -q          # a healer may have staged code; start from an empty index
    git add linkedin-compain
    if git diff --cached --name-only | grep -qv '^linkedin-compain/'; then
        echo "run-hourly: staged set escaped linkedin-compain/ — refusing the data auto-merge." >&2
        git reset -q
        RUN_ERRORS="${RUN_ERRORS:+${RUN_ERRORS}; }data auto-merge refused (staged set escaped linkedin-compain/)"
        return 0
    fi
    git commit -m "chore: comment drafts + seen-set for ${TS} (self-healed fire)

Data-only commit from a self-healed fire: Slack already received these
drafts, so the cross-fire seen-set must land on main. The heal's code
changes + incident ship separately on a review-gated heal/ PR."
    git push origin HEAD
    gh pr create --title "chore: comment drafts + seen-set for ${TS} (self-healed fire)" \
        --body "Data-only PR from a self-healed fire — auto-merged so the cross-fire seen-set stays on main (the Slack side effects already happened). The code fix + incident arrive on a separate heal/ PR for review."
    PR_URL=$(gh pr view --json url -q .url 2>/dev/null || true)
    ./.claude/skills/common-pr-merge/merge.sh
    return 0
}

append_incident_run_summary() {
    pl_ensure_incident_skeleton
    {
      printf '\n## Run summary — %s\n' "$(date -u +%FT%TZ)"
      printf -- '- %s\n' "${attempt_summaries[@]}"
      if [ "${#PL_SESSION_NOTES[@]}" -gt 0 ]; then
        printf -- '- note: %s\n' "${PL_SESSION_NOTES[@]}"
      fi
      printf -- '- gather outcome: %s (last exit %s); heal mode: %s; drafted delta: %s; fire %s\n' \
        "$PL_OUTCOME" "$PL_ATTEMPT_EXIT" "$HEAL_MODE" "${DRAFTED_DELTA:-?}" \
        "$([ "$FIRE_FAILED" = 1 ] && echo FAILED || echo ok)"
      if [ "$HEAL_MODE" = "post-landing" ]; then
        printf -- '- post-landing heal: the fix could NOT be rerun-verified this fire — verify on the next fire\n'
      fi
    } >> "$INCIDENT_FILE"
    return 0
}

# The heal's code changes + incident doc go to a separate branch and an OPEN
# PR — the same review-gate philosophy as the weekly pipeline: an unreviewed
# self-fix must not auto-merge.
commit_heal_code_pr() {
    RUN_STAGE="heal-pr"
    local incident_outcome
    if [ "$PL_OUTCOME" = "fallback" ]; then
        incident_outcome="selector drift — legacy fallback shipped drafts; fast-path fix unverified until next fire, PR review pending"
    elif [ "${PERMALINK_HEAL:-0}" = 1 ]; then
        incident_outcome="permalink capture failed on ${PERMALINKS_MISSING_N} accepted post(s) — drafts shipped; fix unverified until next fire, PR review pending"
    elif [ "$FIRE_FAILED" = 1 ]; then
        incident_outcome="gather failed (${PL_OUTCOME}) after ${PL_HEAL_COUNT} heal(s), PR review pending"
    else
        incident_outcome="recovered after ${PL_HEAL_COUNT} heal(s), PR review pending"
    fi
    append_incident_run_summary
    pl_link_incident_in_claude_md "- ${TODAY} — comment-hourly fire: ${incident_outcome} — [${INCIDENT_FILE}](${INCIDENT_FILE})"
    if [ -z "$(git status --porcelain)" ]; then
        echo "run-hourly: heal session left no changes to commit (unexpected — the incident doc alone should be dirty)." >&2
        return 0
    fi
    if [ "$DRY_RUN" = 1 ]; then
        echo "run-hourly: DRY_RUN — would commit heal branch + open review PR."
        return 0
    fi
    local heal_branch="heal/linkedin-comments-${TS}"
    git checkout -B "$heal_branch"
    git add -A
    git commit -m "fix: linkedin-comment-hourly self-heal (${HEAL_MODE}) — ${TS}

${incident_outcome}. See ${INCIDENT_FILE}. Review-gated: this PR must NOT
be auto-merged."
    git push origin HEAD
    gh pr create --title "fix: linkedin-comment-hourly self-heal — ${TODAY}" \
        --body "Self-heal changes from the ${TS} fire (${incident_outcome}). Read ${INCIDENT_FILE} first. The fire's data landed separately; this PR is code + incident only and stays open for review."
    CODE_PR_URL=$(gh pr view --json url -q .url 2>/dev/null || true)
    echo "run-hourly: heal PR left OPEN for review — ${CODE_PR_URL:-URL capture failed (see log)}"
    return 0
}

if [ "${PL_HEAL_COUNT:-0}" -eq 0 ]; then
    land_data_normal
else
    land_data_split
fi

# Post-landing heal: selector drift (exit 30) or accepted posts that shipped
# without a permalink (PERMALINKS_MISSING>0). The drafts are safely on main
# by now; spend the remaining budget fixing the fast path for the next fire.
# Its changes are unverified-by-rerun by definition.
if [ "$POST_LANDING_HEAL" = 1 ] && [ "${PL_HEAL_COUNT:-0}" -lt "$MAX_HEALS" ]; then
    if [ "$SECONDS" -gt "$HEAL_CUTOFF_SECS" ]; then
        echo "run-hourly: past the heal cutoff (${SECONDS}s > ${HEAL_CUTOFF_SECS}s) — skipping the post-landing heal." >&2
        HEAL_RESULT="skipped (past cutoff)"
        RUN_ERRORS="${RUN_ERRORS:+${RUN_ERRORS}; }selector drift NOT healed (past cutoff) — next fire falls back again"
    else
        RUN_STAGE="post-landing-heal"
        HEAL_MODE="post-landing"
        pl_run_heal_session
        # A post-landing heal has no rerun to vouch for it — report its own
        # session outcome honestly instead of calling every attempt "healed".
        HEAL_RESULT="session completed, fix unverified until next fire"
        [ "${PL_CLAUDE_STATUS:-0}" -ne 0 ] && HEAL_RESULT="session FAILED (claude exit ${PL_CLAUDE_STATUS})"
        [ "${PL_CLAUDE_TIMED_OUT:-0}" = 1 ] && HEAL_RESULT="session TIMED OUT"
        [ "${PL_ABORTED:-0}" = 1 ] && HEAL_RESULT="ABORTED: $(pl_oneline "$PL_ABORT_REASON")"
        if [ "$HEAL_RESULT" != "session completed, fix unverified until next fire" ]; then
            RUN_ERRORS="${RUN_ERRORS:+${RUN_ERRORS}; }post-landing heal ${HEAL_RESULT}"
        fi
    fi
fi

if [ "${PL_HEAL_COUNT:-0}" -gt 0 ]; then
    commit_heal_code_pr
fi

RUN_STAGE="done"
if [ "$FIRE_FAILED" = 1 ]; then
    echo "run-hourly: changes committed, but the fire had failures (${RUN_ERRORS:-see log}) — marking the fire failed." >&2
    exit 1
fi
