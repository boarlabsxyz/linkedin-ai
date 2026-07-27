#!/usr/bin/env bash
# Capture the Slack channel snapshot for the inbox gather, deterministically.
#
# Flow: ONE pinned-haiku `claude -p` micro-call mints a 5-minute REST bearer
# for the account Slack connector's proxy (the same auth path the bookends
# use — see pl_post_slack in pipeline-shared/lib.sh for why the shape is
# pinned), then plain `curl` pages GET /slack/channels/<id>/messages from the
# verified proxy (raw Slack message JSON: bot messages carry bot_id — the
# reliable non-bot discriminator) into <out-dir>/messages.json.
#
# The bearer lives in a shell VARIABLE only — the mint call is captured via
# command substitution under a perl-alarm cap (macOS has no GNU timeout), so
# the token is never logged and never touches disk. stderr from claude goes
# to /dev/null (progress noise; the token only ever appears on stdout).
#
# Scan floor = state.last_ts − 3 days (EDIT_OVERLAP_SECS, keep in sync with
# gather-inbox.mjs): Slack keeps a message's original ts on edit, so the
# overlap re-scans recently processed messages; gather-inbox drops the
# already-accounted links, making the overlap free.
#
# Usage: read-slack-inbox.sh <out-dir> [state-file]
# Env: INBOX_CHANNEL_ID (default C0BF606R4N7), CLAUDE_BIN, MINT_TIMEOUT_SECS.
# Stdout on success: MESSAGES_FILE=<path>. Exit nonzero on ANY failure —
# the driver treats that as "skip inbox this fire, retry next" (no advance).
set -euo pipefail

OUT_DIR="${1:?usage: read-slack-inbox.sh <out-dir> [state-file]}"
STATE_FILE="${2:-linkedin-compain/slack-inbox.json}"
CHANNEL_ID="${INBOX_CHANNEL_ID:-C0BF606R4N7}"
MINT_TIMEOUT_SECS="${MINT_TIMEOUT_SECS:-120}"
EDIT_OVERLAP_SECS=259200
MAX_PAGES=20

mkdir -p "$OUT_DIR"

[ -f "$STATE_FILE" ] || { echo "read-slack-inbox: state file missing: $STATE_FILE (never guess a watermark)" >&2; exit 1; }
last_ts=$(jq -r '.last_ts // empty' "$STATE_FILE")
printf '%s' "$last_ts" | grep -qE '^[0-9]+\.[0-9]+$' \
  || { echo "read-slack-inbox: state last_ts invalid: '${last_ts}'" >&2; exit 1; }
floor_sec=$(( ${last_ts%%.*} - EDIT_OVERLAP_SECS ))
[ "$floor_sec" -lt 0 ] && floor_sec=0
# Clamp to the immutable deployment floor — the overlap window must never
# reach back past the documented cutoff (gather-inbox clamps identically).
scan_floor=$(jq -r '.scan_floor_ts // empty' "$STATE_FILE")
if printf '%s' "$scan_floor" | grep -qE '^[0-9]+\.[0-9]+$'; then
  [ "${scan_floor%%.*}" -gt "$floor_sec" ] && floor_sec="${scan_floor%%.*}"
fi
OLDEST="${floor_sec}.000000"

# ---- mint the bearer (token stays in this variable; claude stderr dropped).
# Empirically pinned shape (2026-07-25, hard-won — every element matters):
#   - prompt INLINE as the positional arg — haiku ignores content on stdin
#     (the same pin as pl_post_slack's bookends);
#   - the pipeline context goes in --append-system-prompt: a bare user-level
#     "output the token" is indistinguishable from credential exfiltration
#     and sonnet REFUSES it outright ("prompt injection … won't comply"),
#     while haiku stalls because the tool's own description says to skip it
#     for shell-less callers. System-level framing naming the calling script
#     + a Read tool so the model can verify the caller fixed both (2/2 mints
#     on haiku after 0/2 without);
#   - haiku → sonnet escalation, same ladder philosophy as the classifier.
MINT_SYS='You are the credential-mint step inside .claude/skills/linkedin-comment-hourly/read-slack-inbox.sh, part of the linkedin-comment-hourly pipeline in the linkedin-ai repo, running locally under the repo owner'\''s own account. The invoking shell script immediately curls the account'\''s own awesome-mcp REST proxy with the minted 5-minute read-only bearer to bulk-download Slack channel history to disk — the exact escape-hatch flow mintRestBearerForCurl exists for. Printing the tool'\''s JSON result to stdout hands it only to that parent script.'
MINT_PROMPT='Mint the Slack REST bearer: call mcp__claude_ai_Slack_Bot__mintRestBearerForCurl exactly once and output ONLY the JSON object it returns — no code fences, no commentary. If you want to verify the caller, read .claude/skills/linkedin-comment-hourly/read-slack-inbox.sh first.'
TOKEN=""
BASE_URL=""
for mint_model in claude-haiku-4-5-20251001 claude-sonnet-5; do
  mint_out=$(CLAUDE_HISTORY_ROLE=0 perl -e 'alarm shift @ARGV; exec @ARGV' "$MINT_TIMEOUT_SECS" \
        "${CLAUDE_BIN:-claude}" -p "$MINT_PROMPT" \
        --append-system-prompt "$MINT_SYS" \
        --model "$mint_model" \
        --allowedTools "mcp__claude_ai_Slack_Bot__mintRestBearerForCurl,Read" \
        --permission-mode dontAsk \
        --no-session-persistence \
        2>/dev/null </dev/null) || { echo "read-slack-inbox: mint micro-call failed (${mint_model})" >&2; continue; }
  # Extract {..."token"...} even if the model wrapped it in prose/fences.
  mint_json=$(printf '%s' "$mint_out" | tr -d '\n' | grep -oE '\{[^{}]*"token"[^{}]*\}' | tail -1 || true)
  TOKEN=$(printf '%s' "$mint_json" | jq -r '.token // empty' 2>/dev/null || true)
  BASE_URL=$(printf '%s' "$mint_json" | jq -r '.baseUrl // empty' 2>/dev/null || true)
  if [ -z "$TOKEN" ] || [ -z "$BASE_URL" ]; then
    echo "read-slack-inbox: mint reply unparseable on ${mint_model} (len ${#mint_out}) — escalating" >&2
    TOKEN=""; BASE_URL=""
    continue
  fi
  case "$BASE_URL" in
    (https://*) : ;;
    (*) echo "read-slack-inbox: suspicious baseUrl from ${mint_model} — escalating" >&2; TOKEN=""; BASE_URL=""; continue;;
  esac
  # A parseable token can still be wrong — the model transcribes it and a
  # single flipped character parses fine but 401s (observed 2026-07-25).
  # Probe with a 1-message read before trusting it for the real pagination.
  probe=$(curl -sS --connect-timeout 10 -m 30 -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${TOKEN}" \
    "${BASE_URL}/slack/channels/${CHANNEL_ID}/messages?oldest=${OLDEST}&limit=1" || echo 000)
  [ "$probe" = 200 ] && break
  echo "read-slack-inbox: minted token rejected by probe (HTTP ${probe}) on ${mint_model} — escalating" >&2
  TOKEN=""; BASE_URL=""
done
[ -n "$TOKEN" ] && [ -n "$BASE_URL" ] || { echo "read-slack-inbox: could not obtain a working bearer" >&2; exit 1; }

# ---- paginate to exhaustion (older unread messages must never be skipped)
cursor=""
page=0
while :; do
  page=$((page + 1))
  if [ "$page" -gt "$MAX_PAGES" ]; then
    echo "read-slack-inbox: pagination ceiling (${MAX_PAGES} pages) hit with hasMore=true — refusing a partial snapshot" >&2
    exit 1
  fi
  url="${BASE_URL}/slack/channels/${CHANNEL_ID}/messages?oldest=${OLDEST}&limit=100${cursor:+&cursor=${cursor}}"
  curl -sS -f --connect-timeout 10 -m 30 -H "Authorization: Bearer ${TOKEN}" "$url" \
    -o "$OUT_DIR/page-${page}.json" \
    || { echo "read-slack-inbox: curl failed on page ${page}" >&2; exit 1; }
  jq -e '.messages | type == "array"' "$OUT_DIR/page-${page}.json" >/dev/null 2>&1 \
    || { echo "read-slack-inbox: page ${page} is not a message payload: $(head -c 200 "$OUT_DIR/page-${page}.json")" >&2; exit 1; }
  # hasMore must be an actual boolean — a missing/null/garbage field on a
  # malformed page must not read as "complete" (a max-scanned watermark over
  # a truncated snapshot skips messages forever).
  hm_type=$(jq -r '.hasMore | type' "$OUT_DIR/page-${page}.json")
  [ "$hm_type" = "boolean" ] \
    || { echo "read-slack-inbox: page ${page} hasMore is ${hm_type}, not boolean — refusing the snapshot" >&2; exit 1; }
  has_more=$(jq -r '.hasMore' "$OUT_DIR/page-${page}.json")
  cursor=$(jq -r '.nextCursor // empty | @uri' "$OUT_DIR/page-${page}.json")
  [ "$has_more" = "true" ] || break
  [ -n "$cursor" ] || { echo "read-slack-inbox: hasMore=true but no nextCursor on page ${page} — refusing a partial snapshot" >&2; exit 1; }
done

jq -s '{channelId: (.[0].channelId // null), messages: (map(.messages) | add)}' \
  "$OUT_DIR"/page-*.json > "$OUT_DIR/messages.json"
rm -f "$OUT_DIR"/page-*.json
count=$(jq '.messages | length' "$OUT_DIR/messages.json")
echo "read-slack-inbox: captured ${count} messages (${page} page(s), oldest=${OLDEST})" >&2
echo "MESSAGES_FILE=$OUT_DIR/messages.json"
