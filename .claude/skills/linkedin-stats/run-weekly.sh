#!/usr/bin/env bash
# Weekly LinkedIn-stats scrape, driven non-interactively by the
# linkedin-stats-weekly GitHub Actions workflow on a self-hosted macOS runner.
#
# Self-healing flow:
#   1. Branch off origin/main (suffixed if a same-week PR is still open).
#   2. Up to MAX_ATTEMPTS runs of the deterministic scraper
#      (.claude/skills/linkedin-stats/fast/scrape-weekly.mjs), each under a
#      hard watchdog (the scraper's own deadline is soft — a stuck browser
#      ignores it). Acceptable = exit 0, or exit 10 (partial) whose contract
#      shows no phase-level ERROR and >=80% per-post coverage.
#   3. Between failed attempts, a headless `claude -p` heal session diagnoses
#      and fixes the pipeline following references/self-heal.md: evidence,
#      a codex validation round, triage, fix, spot-verify, incident write-up
#      in doc/incidents/. Exceptions: exit 22 sleeps once (second consecutive
#      429 stops the loop — only time helps), exit 21 sweeps the orphan
#      Chrome once (second consecutive lock goes to a heal session). A heal
#      session can stop the loop via $HEAL_ROOT/ABORT. Before each retry,
#      dashboards/li-stats is reset to the committed baseline so the final
#      tree is one attempt's coherent output, never a cross-attempt hybrid.
#   4. jq-validate snapshots, then commit + push + PR via the common-pr-*
#      scripts. ONLY a no-heal exit-0 run auto-merges (and flips the
#      main_updated output that gates the Pages publish job). Everything
#      else — healed, partial, aborted, exhausted — leaves the PR OPEN for
#      review; a healed success first gets a read-only codex critique
#      session (references/self-heal-review.md).
#
# Test hooks (all default to production values): FAST_DIR, MAX_ATTEMPTS,
# DEADLINE_SECS, HEAL_TIMEOUT_SECS, REVIEW_TIMEOUT_SECS, RATE_LIMIT_SLEEP_SECS,
# CLAUDE_BIN, and DRY_RUN=1 (skip branch checkout and the commit/PR chain).
set -euo pipefail

# Re-exec from a detached copy so a heal session may safely edit the tracked
# run-weekly.sh (bash reads its script file incrementally — editing the
# executing file corrupts the run; the copy is never edited). Such edits are
# still unverified until the next fire — the incident doc must say so.
# Detection is $0-based (not an env var): a nested invocation of the tracked
# script gets its own copy and its EXIT trap can only remove that own copy.
case "$0" in
  */run-weekly-exec-*.sh)
    trap 'rm -f "$0"' EXIT
    ;;
  *)
    mkdir -p tmp
    cp "$0" "tmp/run-weekly-exec-$$.sh"
    exec bash "tmp/run-weekly-exec-$$.sh" "$@"
    ;;
esac

for cmd in claude node npm gh git jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Required command not found in PATH: $cmd" >&2
    exit 1
  fi
done
# codex is the heal sessions' second brain; its absence degrades them, not us.
CODEX_AVAILABLE=0
command -v codex >/dev/null 2>&1 && CODEX_AVAILABLE=1

MAX_ATTEMPTS="${MAX_ATTEMPTS:-5}"
DEADLINE_SECS="${DEADLINE_SECS:-1500}"
HEAL_TIMEOUT_SECS="${HEAL_TIMEOUT_SECS:-4500}"
REVIEW_TIMEOUT_SECS="${REVIEW_TIMEOUT_SECS:-1500}"
RATE_LIMIT_SLEEP_SECS="${RATE_LIMIT_SLEEP_SECS:-1200}"
HARD_CAP_EXTRA_SECS="${HARD_CAP_EXTRA_SECS:-600}"
FAST_DIR="${FAST_DIR:-.claude/skills/linkedin-stats/fast}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
DRY_RUN="${DRY_RUN:-0}"
SKILL_DIR=".claude/skills/linkedin-stats"

WEEK=$(date -u -v-Mon "+%Y-%m-%d" 2>/dev/null || date -u -d "last monday" "+%Y-%m-%d")
BRANCH="chore/linkedin-stats-${WEEK}"
TODAY=$(date -u +%Y-%m-%d)
INCIDENT_FILE="doc/incidents/${TODAY}-linkedin-stats-weekly.md"
HEAL_ROOT="tmp/self-heal/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$HEAL_ROOT"

# Only the auto-merge path updates main; the workflow's publish job reads
# this to skip republishing stale main after a healed/partial run.
emit_output() {
  # Not best-effort: silently losing main_updated=true would merge main but
  # skip the publish job with no signal. set -e makes a failed write fatal.
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "$1" >> "$GITHUB_OUTPUT"
  fi
}
emit_output "main_updated=false"

if [ "$DRY_RUN" != 1 ]; then
  git fetch origin main
  # A same-week rerun while the previous (healed, unmerged) PR is still open
  # must not collide with its branch.
  if git ls-remote --exit-code origin "refs/heads/$BRANCH" >/dev/null 2>&1; then
    BRANCH="${BRANCH}-$(date -u +%H%M%S)"
  fi
  git checkout -B "$BRANCH" origin/main
fi

if [ ! -f "$FAST_DIR/scrape-weekly.mjs" ]; then
  echo "run-weekly: $FAST_DIR/scrape-weekly.mjs missing from this checkout; failing." >&2
  exit 1
fi
# node_modules is gitignored; the runner's clone starts clean every fire.
if [ ! -d "$FAST_DIR/node_modules/playwright-core" ]; then
  (cd "$FAST_DIR" && npm install --no-audit --no-fund --silent)
fi

# The scraper's own launcher closes its browser; this catches everything a
# kill or a crashed probe leaves behind. Any Chrome on the shared profile
# while this job runs is an orphan — the single runner serializes jobs.
sweep_profile_chrome() {
  pkill -f 'user-data-dir=.*mcp-chrome-linkedin-ai' 2>/dev/null || true
}

# spawn_killer <cap-secs> <target-pid> <label> <marker>
# Background watchdog. At the cap it: creates <marker> (so the caller knows
# it fired and the timeout is visible in run state), records the target's
# direct children BEFORE anything dies (kill-by-recorded-PID still reaches a
# TERM-ignoring child after it's been reparented — pkill -P on a dead parent
# finds nothing), TERMs them and the target, sweeps the browser, then
# KILL-escalates after 15s.
spawn_killer() {
  local cap="$1" target="$2" label="$3" marker="$4" kids
  (
    # Background + wait: a reap then ends this subshell without bash's noisy
    # "Terminated" job notice (only foreground deaths print).
    sleep "$cap" &
    wait "$!" || exit 0
    kill -0 "$target" 2>/dev/null || exit 0
    touch "$marker"
    echo "run-weekly: $label exceeded ${cap}s — terminating (pid $target)." >&2
    kids=$(pgrep -P "$target" 2>/dev/null || true)
    # word-splitting of $kids is intended: it is a PID list
    kill -TERM $kids "$target" 2>/dev/null || true
    sweep_profile_chrome
    sleep 15
    kill -KILL $kids "$target" 2>/dev/null || true
  ) &
}

# await_target <target-pid> <watchdog-pid> <marker>
# Waits for the target and returns its exit status. If the watchdog fired,
# WAIT for its KILL escalation to finish — cancelling it would let a
# TERM-ignoring child (e.g. the scraper hanging in context.close()) survive
# into the next attempt. Otherwise reap the watchdog, its own sleep first:
# orphaned, that sleep would hold this script's stdout pipe open long after
# we exit; the racing subshell then sees a reaped target and exits harmlessly.
await_target() {
  local target="$1" wd="$2" marker="$3" status
  wait "$target" 2>/dev/null
  status=$?
  if [ -f "$marker" ]; then
    wait "$wd" 2>/dev/null || true
  else
    pkill -P "$wd" 2>/dev/null || true
    kill "$wd" 2>/dev/null || true
    wait "$wd" 2>/dev/null || true
  fi
  return "$status"
}

# run_claude_with_watchdog <timeout-secs> <history-role> <prompt>
# Streams claude's narration into the job log. GH_TOKEN is scrubbed — heal
# and review sessions have no business talking to GitHub.
run_claude_with_watchdog() {
  local cap="$1" role="$2" prompt="$3" pid wd marker
  # The 600s headless background-task ceiling would kill a 5-8 min codex run.
  (
    printf '%s' "$prompt" \
      | CLAUDE_HISTORY_ROLE="$role" CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 \
        env -u GH_TOKEN \
        "$CLAUDE_BIN" -p --dangerously-skip-permissions --output-format stream-json --verbose \
      | jq -r --unbuffered '
          .description
          // (.message?.content? | arrays | map(select(.type=="text") | .text) | .[])
          // (select(.is_error == true or .error) | "ERROR: \(.error // .message?.content)")
          // empty
        '
  ) &
  pid=$!
  marker="$HEAL_ROOT/timeout-${role}-${pid}"
  spawn_killer "$cap" "$pid" "claude ($role)" "$marker"
  wd=$!
  await_target "$pid" "$wd" "$marker" || true
  if [ -f "$marker" ]; then
    # A timed-out session may have left half-done work; the run state and
    # incident must say so instead of pretending the protocol completed.
    session_notes+=("claude ${role} session TIMED OUT at ${cap}s — its work may be incomplete")
    echo "run-weekly: claude ($role) timed out — continuing with whatever it left." >&2
  fi
}

# Exit 10 keeps partial data, but the contract must show the run was healthy
# enough to accept: no phase-level ERROR (a dead posts/account/comments phase
# means a whole surface is missing however good the per-post counters look —
# the 2026-07-20 nav-slowdown runs died exactly there), POSTS_MEASURED > 0,
# and >=80% per-post coverage (measured >= 4x the failed+unprocessed rest).
coverage_ok() {
  local log="$1" measured failed unprocessed
  if grep -q '^ERROR=' "$log"; then
    return 1
  fi
  measured=$(grep -Eo 'POSTS_MEASURED=[0-9]+' "$log" | tail -1 | cut -d= -f2)
  failed=$(grep -Eo 'POSTS_FAILED=[0-9]+' "$log" | tail -1 | cut -d= -f2)
  unprocessed=$(grep -Eo 'POSTS_UNPROCESSED=[0-9]+' "$log" | tail -1 | cut -d= -f2)
  [ -n "$measured" ] && [ "$measured" -gt 0 ] \
    && [ "$measured" -ge $(( 4 * ( ${failed:-0} + ${unprocessed:-0} ) )) ]
}

heal_prompt() {
  cat <<EOF
You are the self-healing layer of the linkedin-stats weekly pipeline, invoked
headless by run-weekly.sh on the self-hosted runner after a failed scrape
attempt. Read ${SKILL_DIR}/references/self-heal.md and follow it exactly.
Context:
ATTEMPT=${attempt}/${MAX_ATTEMPTS}
HEAL_COUNT=${heal_count}
EXIT_CODE=${fast_exit}
LOG_FILE=${ATTEMPT_LOG}
HEAL_DIR=${HEAL_ROOT}
INCIDENT_FILE=${INCIDENT_FILE}
CODEX_AVAILABLE=${CODEX_AVAILABLE}
WEEK=${WEEK}
FAST_DIR=${FAST_DIR}
EOF
}

review_prompt() {
  local acceptance="complete"
  [ "$fast_exit" -eq 10 ] && acceptance="accepted_partial"
  cat <<EOF
You are the review layer of the linkedin-stats weekly pipeline. Heal
sessions ran and the outer acceptance gate accepted the final scrape attempt
(see FINAL_ACCEPTANCE — "accepted_partial" means exit 10 with gaps, NOT a
full success; describe it accordingly). Read
${SKILL_DIR}/references/self-heal-review.md and follow it exactly. This
session is READ-ONLY for code: critique goes into the incident doc, not
into files under version control other than ${INCIDENT_FILE} and CLAUDE.md.
Context:
ATTEMPTS_USED=${attempt}
HEAL_COUNT=${heal_count}
FINAL_EXIT_CODE=${fast_exit}
FINAL_ACCEPTANCE=${acceptance}
FINAL_LOG_FILE=${ATTEMPT_LOG}
HEAL_DIR=${HEAL_ROOT}
INCIDENT_FILE=${INCIDENT_FILE}
CODEX_AVAILABLE=${CODEX_AVAILABLE}
WEEK=${WEEK}
FAST_DIR=${FAST_DIR}
EOF
}

# Create the incident doc BEFORE the first heal session — a watchdog-killed
# claude must still leave a committed trace of what happened.
ensure_incident_skeleton() {
  [ -f "$INCIDENT_FILE" ] && return 0
  mkdir -p "$(dirname "$INCIDENT_FILE")"
  {
    printf '# %s — linkedin-stats weekly scrape incident\n\n' "$TODAY"
    printf 'Auto-created by run-weekly.sh (attempt %s, exit %s). Log tail:\n\n```\n' "$attempt" "$fast_exit"
    tail -15 "$ATTEMPT_LOG" 2>/dev/null || true
    printf '```\n'
  } > "$INCIDENT_FILE"
}

run_heal_session() {
  healed=1
  heal_count=$((heal_count + 1))
  ensure_incident_skeleton
  echo "run-weekly: heal session ${heal_count} starting for exit ${fast_exit} ($(date -u +%H:%M:%SZ))"
  run_claude_with_watchdog "$HEAL_TIMEOUT_SECS" stats-heal "$(heal_prompt)"
  sweep_profile_chrome
  echo "run-weekly: heal session done ($(date -u +%H:%M:%SZ))"
  if [ -f "$HEAL_ROOT/ABORT" ]; then
    echo "run-weekly: heal session aborted the loop: $(cat "$HEAL_ROOT/ABORT")" >&2
    aborted=1
  fi
}

# ---------------------------------------------------------------- scrape loop

attempt=0
healed=0
heal_count=0
aborted=0
scrape_ok=0
fast_exit=1
consecutive_rate=0
consecutive_lock=0
attempt_summaries=()
session_notes=()

while [ "$attempt" -lt "$MAX_ATTEMPTS" ]; do
  attempt=$((attempt + 1))
  ATTEMPT_LOG="$HEAL_ROOT/attempt-${attempt}.log"
  attempt_start=$SECONDS

  if [ "$attempt" -gt 1 ]; then
    # Retries start from the committed baseline: never hand review a hybrid
    # of partial writes produced by different attempts/code versions.
    git checkout -q -- dashboards/li-stats/ 2>/dev/null || true
    git clean -qfd dashboards/li-stats/ 2>/dev/null || true
  fi

  echo "run-weekly: scrape attempt ${attempt}/${MAX_ATTEMPTS} starting ($(date -u +%H:%M:%SZ))"
  # The scraper's --deadline is soft (checked between navigations); a hung
  # browser sails past it. The killer is the hard cap.
  scrape_marker="$HEAL_ROOT/timeout-scrape-${attempt}"
  set +e
  (
    node "$FAST_DIR/scrape-weekly.mjs" --deadline-secs="$DEADLINE_SECS" 2>&1 | tee "$ATTEMPT_LOG"
    exit "${PIPESTATUS[0]}"
  ) &
  scrape_pid=$!
  spawn_killer "$(( DEADLINE_SECS + HARD_CAP_EXTRA_SECS ))" "$scrape_pid" "scraper (attempt ${attempt})" "$scrape_marker"
  scrape_wd=$!
  await_target "$scrape_pid" "$scrape_wd" "$scrape_marker"
  fast_exit=$?
  set -e
  timed_out_note=""
  [ -f "$scrape_marker" ] && timed_out_note=", KILLED at hard cap"
  attempt_summaries+=("attempt ${attempt}: exit ${fast_exit}, $(( SECONDS - attempt_start ))s${timed_out_note}")
  echo "run-weekly: attempt ${attempt} exited ${fast_exit} ($(date -u +%H:%M:%SZ))"

  [ "$fast_exit" -ne 22 ] && consecutive_rate=0
  [ "$fast_exit" -ne 21 ] && consecutive_lock=0

  if [ "$fast_exit" -eq 0 ]; then
    scrape_ok=1
    break
  fi
  if [ "$fast_exit" -eq 10 ] && coverage_ok "$ATTEMPT_LOG"; then
    echo "run-weekly: partial with acceptable coverage — keeping it (PR will stay unmerged)."
    scrape_ok=1
    break
  fi
  if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    break
  fi

  case "$fast_exit" in
    22)
      consecutive_rate=$((consecutive_rate + 1))
      if [ "$consecutive_rate" -ge 2 ]; then
        # A second 429 after a 20-min cool-down is not a pacing bug to fix
        # mid-run — it can be an account-level restriction. Stop poking.
        echo "run-weekly: second consecutive rate-limit — stopping the loop." >&2
        break
      fi
      echo "run-weekly: rate-limited — sleeping ${RATE_LIMIT_SLEEP_SECS}s before attempt $((attempt + 1))."
      sleep "$RATE_LIMIT_SLEEP_SECS"
      ;;
    21)
      consecutive_lock=$((consecutive_lock + 1))
      if [ "$consecutive_lock" -ge 2 ]; then
        # The sweep didn't free the profile — something is actively holding
        # it; that needs diagnosis, not another blind pkill.
        run_heal_session
        [ "$aborted" -eq 1 ] && break
      else
        echo "run-weekly: profile locked — sweeping orphaned Chrome and retrying in 60s."
        sweep_profile_chrome
        sleep 60
      fi
      ;;
    *)
      run_heal_session
      [ "$aborted" -eq 1 ] && break
      ;;
  esac
done

# ------------------------------------------------------------------- commit

# A kill/deadline can land mid-write; never commit a truncated snapshot.
# Always revert the corrupt file (the PR must stay parseable), and demote the
# whole run to failed — a run that silently discarded one of its outputs must
# not be called clean, partial, or recovered.
invalid_json=0
while IFS= read -r -d '' f; do
  if ! jq empty "$f" 2>/dev/null; then
    invalid_json=1
    git checkout -- "$f" 2>/dev/null || rm -f "$f"
    echo "run-weekly: $f was not valid JSON — reverted." >&2
    session_notes+=("invalid JSON reverted: $f")
  fi
done < <(find dashboards/li-stats -name '*.json' -print0)
if [ "$invalid_json" -eq 1 ] && [ "$scrape_ok" -eq 1 ]; then
  echo "run-weekly: truncated snapshot detected — demoting the run to UNRESOLVED." >&2
  scrape_ok=0
fi

# Auto-merge ONLY the boring case: first-grade success with no healing. A
# healed run's fix and an accepted partial's gaps both deserve human eyes —
# and a permanent regression must not quietly auto-merge partial data every
# Monday (that's how 2026-07-20 would have looked with a laxer gate).
if [ "$scrape_ok" -eq 1 ] && [ "$healed" -eq 0 ] && [ "$fast_exit" -eq 0 ]; then
  # git diff --quiet only sees TRACKED changes; new posts create untracked
  # JSON files, so use git status --porcelain. A weekly run must at minimum
  # add a weeks[WEEK] entry to account.json — "no changes" means the scrape
  # produced nothing, so fail loudly instead of green.
  if [ -z "$(git status --porcelain -- dashboards/li-stats/)" ]; then
    echo "run-weekly: no changes under dashboards/li-stats/ after scrape — failing the run." >&2
    exit 1
  fi
  if [ "$DRY_RUN" = 1 ]; then
    echo "run-weekly: DRY_RUN — would commit + PR + merge."
    exit 0
  fi
  ./.claude/skills/common-pr-commit/commit.sh
  ./.claude/skills/common-pr-update/pr-update.sh
  ./.claude/skills/common-pr-merge/merge.sh
  emit_output "main_updated=true"
  exit 0
fi

# Healed / partial / failed path: finish the incident doc, link it from
# CLAUDE.md, optionally run the read-only critique, then commit + PR WITHOUT
# merging.
# mkdir must precede the block: bash opens the >> target before running it,
# and a redirect failure on a compound command does NOT trip set -e — the
# incident would silently never be written.
mkdir -p "$(dirname "$INCIDENT_FILE")"
{
  if [ ! -f "$INCIDENT_FILE" ]; then
    printf '# %s — linkedin-stats weekly scrape incident\n' "$TODAY"
  fi
  printf '\n## Run summary — %s\n' "$(date -u +%FT%TZ)"
  printf -- '- %s\n' "${attempt_summaries[@]}"
  if [ "${#session_notes[@]}" -gt 0 ]; then
    printf -- '- note: %s\n' "${session_notes[@]}"
  fi
  if [ "$scrape_ok" -eq 1 ] && [ "$heal_count" -gt 0 ]; then
    if [ "$fast_exit" -eq 0 ]; then acceptance="full success"; else acceptance="accepted partial, exit 10"; fi
    printf -- '- outcome: RECOVERED — outer gate accepted attempt %s (%s) after %s heal session(s); PR left unmerged for review\n' "$attempt" "$acceptance" "$heal_count"
  elif [ "$scrape_ok" -eq 1 ]; then
    printf -- '- outcome: PARTIAL — exit 10 accepted with reduced coverage; PR left unmerged for review\n'
  elif [ "$aborted" -eq 1 ]; then
    printf -- '- outcome: ABORTED by heal session — %s\n' "$(cat "$HEAL_ROOT/ABORT")"
  else
    printf -- '- outcome: UNRESOLVED — stopped after %s of %s attempts (last exit %s)\n' "$attempt" "$MAX_ATTEMPTS" "$fast_exit"
  fi
} >> "$INCIDENT_FILE"

if ! grep -qF "(${INCIDENT_FILE})" CLAUDE.md; then
  if [ "$scrape_ok" -eq 1 ] && [ "$heal_count" -gt 0 ]; then
    outcome="recovered after ${attempt} attempts / ${heal_count} heal(s), PR review pending"
    [ "$fast_exit" -eq 10 ] && outcome="recovered (accepted partial) after ${attempt} attempts / ${heal_count} heal(s), PR review pending"
  elif [ "$scrape_ok" -eq 1 ]; then
    outcome="partial coverage accepted, PR review pending"
  elif [ "$aborted" -eq 1 ]; then
    outcome="heal aborted: $(head -c 80 "$HEAL_ROOT/ABORT")"
  else
    outcome="UNRESOLVED after ${attempt} attempts (last exit ${fast_exit})"
  fi
  link_line="- ${TODAY} — weekly scrape: ${outcome} — [${INCIDENT_FILE}](${INCIDENT_FILE})"
  if grep -q '^## Incidents' CLAUDE.md; then
    awk -v line="$link_line" '{ print } /^## Incidents/ && !done { print ""; print line; done=1 }' \
      CLAUDE.md > CLAUDE.md.tmp && mv CLAUDE.md.tmp CLAUDE.md
  else
    printf '\n## Incidents\n\n%s\n' "$link_line" >> CLAUDE.md
  fi
fi

if [ "$scrape_ok" -eq 1 ] && [ "$healed" -eq 1 ]; then
  echo "run-weekly: rerun succeeded after healing — starting read-only critique session."
  run_claude_with_watchdog "$REVIEW_TIMEOUT_SECS" stats-heal-review "$(review_prompt)"
  sweep_profile_chrome
fi

if [ -z "$(git status --porcelain)" ]; then
  echo "run-weekly: nothing to commit even after incident write-up — failing." >&2
  exit 1
fi

if [ "$DRY_RUN" = 1 ]; then
  echo "run-weekly: DRY_RUN — would commit + PR (no merge); scrape_ok=${scrape_ok} heal_count=${heal_count} aborted=${aborted}."
else
  ./.claude/skills/common-pr-commit/commit.sh
  ./.claude/skills/common-pr-update/pr-update.sh
  echo "run-weekly: PR left OPEN for review — merge manually after reading ${INCIDENT_FILE}, then dispatch pages-deploy.yml."
fi

# Recovered/partial runs are green (the PR is the review surface);
# aborted/exhausted runs are red so the missed week is visible.
[ "$scrape_ok" -eq 1 ] || exit 1
