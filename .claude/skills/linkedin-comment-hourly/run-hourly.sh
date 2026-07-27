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
# 3000s (was 2400): the sequential write+Slack+ClickUp loop can now carry up
# to 5 feed + 5 inbox posts per fire.
CLAUDE_TIMEOUT_SECS="${CLAUDE_TIMEOUT_SECS:-3000}"
LOCK_RETRY_SLEEP_SECS="${LOCK_RETRY_SLEEP_SECS:-60}"
# Slack-inbox stage (runs BEFORE the feed gather; failures skip the inbox for
# this fire — watermark untouched, retried next fire — and never block the
# feed). Watchdog > mjs deadline: the soft deadline should always win.
INBOX_STATE_FILE="linkedin-compain/slack-inbox.json"
INBOX_MAX_LINKS="${INBOX_MAX_LINKS:-5}"
INBOX_DEADLINE_SECS="${INBOX_DEADLINE_SECS:-240}"
INBOX_WATCHDOG_SECS="${INBOX_WATCHDOG_SECS:-360}"

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
INBOX_OK=0                   # inbox stage produced an accepted contract
INBOX_POSTS_N=""             # inbox contract POSTS_FOUND
INBOX_SUMMARY=""             # "inbox: X msgs / Y links / …" for the bookend
INBOX_NOTE=""                # one-line inbox failure/delivery note (⚠️)
INBOX_OUT=""                 # inbox stage out-dir

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
    [ -n "$INBOX_SUMMARY" ] && summary="${summary}; ${INBOX_SUMMARY}"
    [ -n "$INBOX_NOTE" ] && summary="${summary}; inbox: $(pl_oneline "$INBOX_NOTE")"
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
        if [ "${POSTS_FOUND_N:-}" = "0" ] && [ "${INBOX_POSTS_N:-0}" = "0" ]; then
            msg="⚠️ linkedin-comment-hourly: run finished in ${dur} — no draftable posts ($(pl_oneline "${GATHER_END_REASON_TXT:-unknown}")); ${summary}"
        elif [ "${FALLBACK_USED:-0}" = 1 ]; then
            msg="⚠️ linkedin-comment-hourly: run finished in ${dur} (selector drift — legacy fallback shipped the drafts) — ${summary}"
        elif [ "${PERMALINK_HEAL:-0}" = 1 ]; then
            msg="⚠️ linkedin-comment-hourly: run finished in ${dur} (permalink capture FAILED on ${PERMALINKS_MISSING_N} accepted post(s) — drafts shipped) — ${summary}"
        elif [ "${PL_HEAL_COUNT:-0}" -gt 0 ]; then
            msg="⚠️ linkedin-comment-hourly: run finished in ${dur} (self-healed) — ${summary}"
        elif [ -n "$INBOX_NOTE" ]; then
            msg="⚠️ linkedin-comment-hourly: run finished in ${dur} (inbox issue — see summary) — ${summary}"
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

# ------------------------------------------------------------- inbox stage

# Validate the inbox contract beyond exit codes (mirrors validate_contract):
# provenance, per-post identity, no /feed/update/ URLs ever, watermark ==
# the snapshot's exact max ts, proposed-state well-formed, and the manifest's
# link-conservation arithmetic. An accepted-looking contract that fails any
# of these is DROPPED (inbox skipped, no advance) — never trusted.
validate_inbox_contract() {
  local contract="$INBOX_OUT/contract.env" n i k a tf mode url wm state_prop max_ts
  INBOX_CONTRACT_OK=0
  INBOX_CONTRACT_NOTE=""
  [ -f "$contract" ] || { INBOX_CONTRACT_NOTE="contract missing"; return 0; }
  n=$(grep '^POSTS_FOUND=' "$contract" | head -1 | cut -d= -f2- || true)
  printf '%s' "$n" | grep -qE '^[0-9]+$' || { INBOX_CONTRACT_NOTE="no numeric POSTS_FOUND"; return 0; }
  local contract_out
  contract_out=$(grep '^OUT_DIR=' "$contract" | head -1 | cut -d= -f2- || true)
  case "$contract_out" in
    "$INBOX_OUT"|*"/$INBOX_OUT") : ;;
    *) INBOX_CONTRACT_NOTE="OUT_DIR '${contract_out}' is not ${INBOX_OUT}"; return 0;;
  esac
  i=1
  while [ "$i" -le "$n" ]; do
    k=$(grep "^POST_${i}_KEY=" "$contract" | head -1 | cut -d= -f2- || true)
    a=$(grep "^POST_${i}_AUTHOR=" "$contract" | head -1 | cut -d= -f2- || true)
    tf=$(grep "^POST_${i}_TEXT_FILE=" "$contract" | head -1 | cut -d= -f2- || true)
    mode=$(grep "^POST_${i}_MODE=" "$contract" | head -1 | cut -d= -f2- || true)
    url=$(grep "^POST_${i}_URL=" "$contract" | head -1 | cut -d= -f2- || true)
    { [ -n "$k" ] && [ -n "$a" ]; } || { INBOX_CONTRACT_NOTE="POST_${i} missing KEY or AUTHOR"; return 0; }
    { [ -n "$tf" ] && [ -s "$tf" ]; } || { INBOX_CONTRACT_NOTE="POST_${i}_TEXT_FILE missing/empty"; return 0; }
    case "$tf" in
      "$INBOX_OUT"/*|*"/$INBOX_OUT/"*) : ;;
      *) INBOX_CONTRACT_NOTE="POST_${i}_TEXT_FILE outside ${INBOX_OUT}"; return 0;;
    esac
    case "$mode" in
      draft|clickup-only|reprocess-off-topic) : ;;
      *) INBOX_CONTRACT_NOTE="POST_${i}_MODE invalid ('${mode}')"; return 0;;
    esac
    # Positive whitelist (codex solution rounds 1–2): ONLY the two
    # LinkedIn-issued deliverable forms. Inbox rows are never legitimately
    # linkless — the gather keeps unresolvable links pending — so "-" is a
    # gather regression and rejects the contract.
    case "$url" in
      https://www.linkedin.com/posts/*|https://lnkd.in/*) : ;;
      *) INBOX_CONTRACT_NOTE="POST_${i}_URL not an allowed form ('${url}')"; return 0;;
    esac
    i=$((i + 1))
  done
  wm=$(grep '^PROPOSED_WATERMARK=' "$contract" | head -1 | cut -d= -f2- || true)
  printf '%s' "$wm" | grep -qE '^[0-9]+\.[0-9]+$' || { INBOX_CONTRACT_NOTE="watermark not a ts ('${wm}')"; return 0; }
  local cur_ts
  cur_ts=$(jq -r '.last_ts' "$INBOX_STATE_FILE" 2>/dev/null || echo '')
  awk -v a="$wm" -v b="$cur_ts" 'BEGIN { exit (a+0 >= b+0) ? 0 : 1 }' \
    || { INBOX_CONTRACT_NOTE="watermark ${wm} below current ${cur_ts}"; return 0; }
  # Exact STRING equality for the ts (float64 wobbles in the microsecond
  # digits); the snapshot's max is computed with the same [sec,usec] compare
  # the mjs uses. The watermark must be EXACTLY max(current, snapshot-max) —
  # accepting a stale "== current" while newer messages exist would let a
  # buggy gather silently skip them (codex solution round 2).
  max_ts=$(jq -r '[.messages[].ts] | sort_by(split(".") | map(tonumber)) | last // empty' "$INBOX_OUT/messages.json" 2>/dev/null || echo '')
  local expected_wm="$cur_ts"
  if [ -n "$max_ts" ] && awk -v a="$max_ts" -v b="$cur_ts" 'BEGIN { split(a, x, "."); split(b, y, ".");
      exit (x[1]+0 > y[1]+0 || (x[1]+0 == y[1]+0 && x[2]+0 > y[2]+0)) ? 0 : 1 }'; then
    expected_wm="$max_ts"
  fi
  if [ "$wm" != "$expected_wm" ]; then
    INBOX_CONTRACT_NOTE="watermark ${wm} != expected max(current, snapshot) = ${expected_wm}"
    return 0
  fi
  state_prop=$(grep '^PROPOSED_STATE_FILE=' "$contract" | head -1 | cut -d= -f2- || true)
  case "$state_prop" in
    "$INBOX_OUT"/*|*"/$INBOX_OUT/"*) : ;;
    *) INBOX_CONTRACT_NOTE="proposed state '${state_prop}' is outside ${INBOX_OUT}"; return 0;;
  esac
  jq -e --arg wm "$wm" '(.last_ts == $wm) and (.pending | type=="array") and (.dead | type=="array")' \
      "$state_prop" >/dev/null 2>&1 \
    || { INBOX_CONTRACT_NOTE="proposed state missing/malformed/watermark-mismatched"; return 0; }
  # scan_floor_ts is immutable — a proposed state that drops or changes it
  # could replay pre-cutoff messages on later fires.
  local cur_floor prop_floor
  cur_floor=$(jq -r '.scan_floor_ts // ""' "$INBOX_STATE_FILE" 2>/dev/null || echo '')
  prop_floor=$(jq -r '.scan_floor_ts // ""' "$state_prop" 2>/dev/null || echo '')
  if [ -n "$cur_floor" ] && [ "$prop_floor" != "$cur_floor" ]; then
    INBOX_CONTRACT_NOTE="proposed state altered scan_floor_ts ('${prop_floor}' vs '${cur_floor}')"
    return 0
  fi
  INBOX_EXPECTED_WM="$wm"
  jq -e '.conservation | (.jobs_pending_in + .jobs_new) ==
         (.contract_rows + .pending_out + .dead_new + .accounted_dupes
          + .skipped_already_commented + .alias_merged)' \
      "$INBOX_OUT/manifest.json" >/dev/null 2>&1 \
    || { INBOX_CONTRACT_NOTE="link-conservation arithmetic does not balance"; return 0; }
  INBOX_POSTS_N="$n"
  INBOX_PROPOSED_STATE="$state_prop"
  INBOX_SUMMARY="inbox: $(grep '^INBOX_MSGS_HUMAN=' "$contract" | head -1 | cut -d= -f2- || true)h msgs / $(grep '^INBOX_LINKS_FOUND=' "$contract" | head -1 | cut -d= -f2- || true) links / ${n} posts / $(grep '^INBOX_DUPLICATES=' "$contract" | head -1 | cut -d= -f2- || true) dup / $(grep '^INBOX_BACKLOG=' "$contract" | head -1 | cut -d= -f2- || true) backlog / $(grep '^INBOX_DEAD=' "$contract" | head -1 | cut -d= -f2- || true) dead"
  INBOX_CONTRACT_OK=1
  return 0
}

# Slack read + gather-inbox under ONE kill watchdog. Any failure degrades to
# feed-only (⚠️ note, watermark untouched, retried next fire) — by design the
# inbox never triggers the heal loop and never blocks the feed.
run_inbox_stage() {
  RUN_STAGE="inbox"
  INBOX_OUT="tmp/gather-inbox/${TS}"
  local marker="$HEAL_ROOT/timeout-inbox" log_file="$HEAL_ROOT/inbox-stage.log" pid wd rc
  echo "run-hourly: inbox stage starting ($(date -u +%H:%M:%SZ))"
  set +e
  (
    set -euo pipefail
    "$SKILL_DIR/read-slack-inbox.sh" "$INBOX_OUT" "$INBOX_STATE_FILE"
    node "$FAST_DIR/gather-inbox.mjs" \
      --messages-file="$INBOX_OUT/messages.json" \
      --state-file="$INBOX_STATE_FILE" \
      --out-dir="$INBOX_OUT" \
      --deadline-secs="$INBOX_DEADLINE_SECS" \
      --max-links="$INBOX_MAX_LINKS"
  ) > "$log_file" 2>&1 &
  pid=$!
  pl_spawn_killer "$INBOX_WATCHDOG_SECS" "$pid" "inbox stage" "$marker"
  wd=$!
  pl_await_target "$pid" "$wd" "$marker"
  rc=$?
  set -e
  sed 's/^/run-hourly[inbox]: /' "$log_file" | tail -40
  if [ -f "$marker" ]; then
    INBOX_NOTE="stage killed at ${INBOX_WATCHDOG_SECS}s watchdog — skipped this fire"
    echo "run-hourly: ${INBOX_NOTE}" >&2
    return 0
  fi
  case "$rc" in
    0|10)
      validate_inbox_contract
      if [ "$INBOX_CONTRACT_OK" = 1 ]; then
        INBOX_OK=1
        [ "$rc" = 10 ] && INBOX_NOTE="partial (fetch failures went to the durable backlog)"
        # New dead letters must be ACTIONABLE: name each URL + reason in the
        # bookend so Peter knows what to re-drop (re-dropping revives it).
        local dead_new_n dead_detail
        dead_new_n=$(grep '^INBOX_DEAD_NEW=' "$INBOX_OUT/contract.env" | head -1 | cut -d= -f2- || true)
        case "$dead_new_n" in (*[!0-9]*|'') dead_new_n=0;; esac
        if [ "$dead_new_n" -gt 0 ]; then
          dead_detail=$(jq -r '[.dead_new_detail[] | "\(.url) (\(.reason))"] | join("; ")' \
            "$INBOX_OUT/manifest.json" 2>/dev/null || echo "detail unavailable")
          INBOX_NOTE="${INBOX_NOTE:+${INBOX_NOTE}; }${dead_new_n} link(s) DEAD-LETTERED: $(pl_oneline "$dead_detail") — re-drop a link to retry it"
        fi
        echo "run-hourly: inbox contract accepted — ${INBOX_POSTS_N} post(s); ${INBOX_SUMMARY}"
      else
        INBOX_NOTE="contract unusable (${INBOX_CONTRACT_NOTE}) — skipped this fire"
        echo "run-hourly: inbox ${INBOX_NOTE}" >&2
      fi
      ;;
    20) INBOX_NOTE="auth wall during inbox fetch — skipped (feed gather will confirm)";;
    21) INBOX_NOTE="profile locked during inbox fetch — skipped (feed loop sweeps)";;
    22) INBOX_NOTE="rate-limited during inbox fetch — skipped this fire";;
    *)  INBOX_NOTE="stage exited ${rc} — skipped this fire";;
  esac
  [ -n "$INBOX_NOTE" ] && [ "$INBOX_OK" != 1 ] \
    && echo "run-hourly: inbox ${INBOX_NOTE}" >&2
  return 0
}

# Deterministic postcondition before installing the watermark: every inbox
# contract row must now exist in comments.json (reprocess rows at disposition
# drafted). A drafting session that "succeeded" while silently skipping a
# post must not consume its Slack message.
install_inbox_state() {
  local contract="$INBOX_OUT/contract.env" n i k mode missing="" tmp_state
  n="$INBOX_POSTS_N"
  # UNIFIED two-leg delivery evidence for EVERY mode (codex rounds 1–4): the
  # entry must carry `source` (all inbox writes set it), a NON-EMPTY ClickUp
  # outcome (task id or error), and — unless the row said NEED_SLACK=0 — a
  # Slack outcome, where completion means the THREAD's post reply landed
  # (`slack_thread.post_reply_ts`), not just the parent, or a recorded
  # slack_error. A "successful" session that wrote entries but skipped the
  # delivery legs must not consume the messages. Reprocess rows additionally
  # prove the in-place flip to disposition drafted. Stale markers can only
  # mis-time the watermark, never lose delivery: any `source` entry without
  # its task reconciles later, and a replayed message re-emits the Slack leg.
  local need_slack
  i=1
  while [ "$i" -le "$n" ]; do
    k=$(grep "^POST_${i}_KEY=" "$contract" | head -1 | cut -d= -f2- || true)
    mode=$(grep "^POST_${i}_MODE=" "$contract" | head -1 | cut -d= -f2- || true)
    need_slack=$(grep "^POST_${i}_NEED_SLACK=" "$contract" | head -1 | cut -d= -f2- || true)
    [ "$need_slack" = "0" ] || need_slack=1
    jq -e --arg k "$k" --arg mode "$mode" --argjson ns "$need_slack" '
        any(.[]; .key == $k and (.source != null)
          and (($mode != "reprocess-off-topic") or (.disposition == "drafted"))
          and (((.clickup_task_id | type == "string") and (.clickup_task_id | length > 0))
               or ((.clickup_error | type == "string") and (.clickup_error | length > 0)))
          and (($ns == 0)
               or ((.slack_thread.post_reply_ts? // null) != null)
               or ((.slack_error | type == "string") and (.slack_error | length > 0))))' \
      linkedin-compain/comments.json >/dev/null 2>&1 || missing="${missing} ${k}(${mode})"
    i=$((i + 1))
  done
  if [ -n "$missing" ]; then
    INBOX_NOTE="delivery incomplete — ledger missing:${missing}; watermark NOT advanced (messages retry next fire)"
    RUN_ERRORS="${RUN_ERRORS:+${RUN_ERRORS}; }inbox ${INBOX_NOTE}"
    echo "run-hourly: inbox ${INBOX_NOTE}" >&2
    return 0
  fi
  # Atomic + guarded: an install I/O failure must degrade to a warning (the
  # comments.json landing below matters more than the watermark), never abort
  # the fire via set -e. The full watermark predicate is re-checked right
  # before the mv — validation ran much earlier and the file could have been
  # touched in between (codex solution round 2).
  tmp_state="${INBOX_STATE_FILE}.install-$$"
  if jq -e --arg wm "${INBOX_EXPECTED_WM:-}" \
        '(.last_ts == $wm) and (.pending | type=="array") and (.dead | type=="array")' \
        "$INBOX_PROPOSED_STATE" >/dev/null 2>&1 \
     && cp "$INBOX_PROPOSED_STATE" "$tmp_state" 2>/dev/null \
     && jq empty "$tmp_state" 2>/dev/null \
     && mv "$tmp_state" "$INBOX_STATE_FILE" 2>/dev/null; then
    echo "run-hourly: inbox state installed (watermark $(jq -r '.last_ts' "$INBOX_STATE_FILE" 2>/dev/null || echo '?'))"
  else
    rm -f "$tmp_state" 2>/dev/null || true
    INBOX_NOTE="state install failed — watermark NOT advanced"
    RUN_ERRORS="${RUN_ERRORS:+${RUN_ERRORS}; }inbox ${INBOX_NOTE}"
    echo "run-hourly: inbox ${INBOX_NOTE}" >&2
  fi
  return 0
}

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
INBOX_OUT=${INBOX_OUT:-}
INBOX_OK=${INBOX_OK:-0}
INBOX_STATE_FILE=${INBOX_STATE_FILE}
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
  # Same-fire cross-source dedup: the inbox ran first; its accepted posts'
  # identities join the feed gather's seen-set so one post can't be accepted
  # from both sources in one fire.
  local extra_seen=""
  if [ "${INBOX_OK:-0}" = 1 ] && [ -s "$INBOX_OUT/keys.json" ]; then
    extra_seen="--extra-seen-file=$INBOX_OUT/keys.json"
  fi
  set +e
  (
    node "$FAST_DIR/gather-feed.mjs" \
      --deadline-secs="$GATHER_DEADLINE_SECS" --out-dir="$GATHER_OUT" \
      ${extra_seen:+"$extra_seen"} 2>&1 | tee "$PL_ATTEMPT_LOG"
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

# ------------------------------------------------------- inbox, then gather

# The inbox runs FIRST (its keys feed the gather's cross-source dedup) and is
# independent: whatever happens to the feed below, an accepted inbox contract
# still reaches the drafting phase (Peter-curated links must ship).
run_inbox_stage

attempt_summaries=()
consecutive_lock=0
RUN_STAGE="gather"
pl_attempt_loop

CLAUDE_PROMPT=""
FIRE_FAILED=0
POST_LANDING_HEAL=0
# Inbox clause appended to whichever drafting prompt the feed outcome builds;
# also the standalone prompt when the feed produced nothing draftable but the
# inbox did (feed failures must not hold Peter-curated links hostage).
INBOX_CLAUSE=""
if [ "${INBOX_OK:-0}" = 1 ] && [ "${INBOX_POSTS_N:-0}" -gt 0 ]; then
    INBOX_CLAUSE="ALSO process the slack-inbox contract at ${INBOX_OUT}/contract.env (same skill flow; note the per-post MODE field)"
fi
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
      CLAUDE_PROMPT="run linkedin comment hourly using the pre-gathered contract at ${GATHER_OUT}/contract.env — do not re-run the gather step${INBOX_CLAUSE:+. ${INBOX_CLAUSE}}"
    elif [ -n "$INBOX_CLAUSE" ]; then
      echo "run-hourly: feed found 0 draftable posts — drafting runs on the inbox contract alone." >&2
      CLAUDE_PROMPT="run linkedin comment hourly using ONLY the pre-gathered slack-inbox contract at ${INBOX_OUT}/contract.env (the feed gather found 0 draftable posts — do not re-run any gather; note the per-post MODE field)"
    else
      echo "run-hourly: gather found 0 draftable posts (end reason: ${GATHER_END_REASON_TXT:-unknown}) — skipping drafting, committing any filtered appends." >&2
    fi
    ;;
  fallback)
    CLAUDE_PROMPT="run linkedin comment hourly using the legacy agent gather — the fast gather script reported selector drift${INBOX_CLAUSE:+. ${INBOX_CLAUSE}}"
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

# A failed feed must not hold the inbox hostage: ship the Peter-curated posts
# anyway (the fire still exits red for the feed). Exception: exit 31 — the
# drafting session runs on the same `claude -p` the classifier just proved
# dead, so drafting would fail identically.
if [ "$FIRE_FAILED" = 1 ] && [ -z "$CLAUDE_PROMPT" ] && [ -n "$INBOX_CLAUSE" ] \
   && [ "${PL_ATTEMPT_EXIT:-0}" != 31 ]; then
    echo "run-hourly: feed gather failed but the inbox has ${INBOX_POSTS_N} post(s) — drafting the inbox contract anyway." >&2
    CLAUDE_PROMPT="run linkedin comment hourly using ONLY the pre-gathered slack-inbox contract at ${INBOX_OUT}/contract.env (the feed gather failed this fire — do not re-run any gather; note the per-post MODE field)"
fi

# Quiet-fire ClickUp reconciliation: entries that never got their task must
# not strand behind fires with nothing to draft.
if [ -z "$CLAUDE_PROMPT" ]; then
    RECONCILABLE_N=$(jq '[.[] | select(.source != null and .disposition == "drafted" and .clickup_task_id == null)] | length' \
        linkedin-compain/comments.json 2>/dev/null || echo 0)
    case "$RECONCILABLE_N" in (*[!0-9]*|'') RECONCILABLE_N=0;; esac
    if [ "$RECONCILABLE_N" -gt 0 ] && [ "${PL_ATTEMPT_EXIT:-0}" != 31 ]; then
        echo "run-hourly: ${RECONCILABLE_N} ledger entr(y/ies) lack their ClickUp task — running reconcile-only drafting session." >&2
        CLAUDE_PROMPT="run linkedin comment hourly in RECONCILE-ONLY mode: no gather contracts this fire — only run the ClickUp reconciliation sub-step from the skill's Step 2b (entries with source set, disposition drafted, and clickup_task_id null), then stop"
    fi
fi

# ------------------------------------------------------------ drafting phase

pipeline_status=""
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

# Inbox watermark install — BEFORE the commit section so the state file rides
# the same linkedin-compain/ data commit as the seen-set. Rules (plan §C):
# 0 inbox posts → install directly; >0 → only when the drafting session that
# covered the inbox contract exited 0 AND the ledger postcondition holds.
if [ "${INBOX_OK:-0}" = 1 ]; then
    if [ "${INBOX_POSTS_N:-0}" = "0" ]; then
        install_inbox_state
    else
        inbox_in_prompt=0
        case "$CLAUDE_PROMPT" in (*"${INBOX_OUT}/contract.env"*) inbox_in_prompt=1;; esac
        if [ "$inbox_in_prompt" = 1 ] && [ "${pipeline_status:-1}" -eq 0 ]; then
            install_inbox_state
        else
            INBOX_NOTE="drafting did not complete for the inbox contract — watermark NOT advanced (messages retry next fire)"
            echo "run-hourly: inbox ${INBOX_NOTE}" >&2
        fi
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
