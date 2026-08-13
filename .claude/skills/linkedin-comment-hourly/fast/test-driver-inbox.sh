#!/usr/bin/env bash
# Isolated tests for run-hourly.sh's inbox functions (validate_inbox_contract
# + install_inbox_state), extracted by sed so the driver itself never runs
# (no git, no Slack, no browser). Complements test-gather-inbox.sh.
set -uo pipefail

FAST_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$FAST_DIR")"
FIX="$FAST_DIR/fixtures"
REPO="$(cd "$FAST_DIR/../../../.." && pwd)"
WORK="$REPO/tmp/inbox-tests/driver-$$"
mkdir -p "$WORK"
cd "$WORK"

# Extract the two functions from the driver (sentinel comments bound them).
sed -n '/^validate_inbox_contract()/,/^# Slack read + gather-inbox under ONE kill watchdog/p' \
  "$SKILL_DIR/run-hourly.sh" | sed '$d' > funcs.sh
sed -n '/^install_inbox_state()/,/^# ------------------------------------------------------------ strategy hooks/p' \
  "$SKILL_DIR/run-hourly.sh" | sed '$d' >> funcs.sh
bash -n funcs.sh || { echo "FAIL: extracted functions do not parse"; exit 1; }
. ./funcs.sh

FAILURES=0
t() { local name="$1"; shift; if eval "$@" >/dev/null 2>&1; then echo "PASS: $name"; else echo "FAIL: $name"; FAILURES=$((FAILURES+1)); fi; }

INBOX_STATE_FILE=state.json
RUN_ERRORS=""
MSG_TS="1784992193.489909"
SEED_TS="1784992000.000000"
# Stored drafts + the comment ids proving their delivery — the second leg is
# only exercised when an entry HAS variants.
DRAFTS='[{"strategy_label":"s1","comment":"c1","rationale":"r1"},{"strategy_label":"s2","comment":"c2","rationale":"r2"}]'
CMT_IDS='["cmt-aaa","cmt-bbb"]'
URL="https://www.linkedin.com/posts/davidlinthicum_the-hidden-tax-on-honest-discourse-in-technology-ugcPost-7486729143691337728-2b55"
jq -n --arg ts "$SEED_TS" '{last_ts: $ts, updated_at: "x", pending: [], dead: []}' > state.json
echo '[]' > comments-empty.json

gen_contract() { # gen_contract <dir> <comments-file>
  rm -rf "$1" && mkdir -p "$1"
  node "$FAST_DIR/gather-inbox.mjs" --messages-file="$FIX/slack-messages.json" \
    --state-file="$WORK/state.json" --comments-file="$2" \
    --out-dir="$1" --fetch-stub="$FIX/fetch-stub.json" >/dev/null 2>&1
  cp "$FIX/slack-messages.json" "$1/messages.json"
}

# ---- validation on a real draft-mode contract
D="$WORK/v1"; gen_contract "$D" "$WORK/comments-empty.json"
INBOX_OUT="$D"; validate_inbox_contract
t "V1 real contract validates"     '[ "$INBOX_CONTRACT_OK" = 1 ] && [ "$INBOX_POSTS_N" = 1 ]'
KEY=$(grep '^POST_1_KEY=' "$D/contract.env" | cut -d= -f2-)

# ---- rejection paths (each on a mutated copy)
for case_name in posts_found url linkless_url watermark stale_watermark conservation; do
  DC="$WORK/v-$case_name"; rm -rf "$DC"; cp -r "$D" "$DC"
  case "$case_name" in
    posts_found)     sed -i '' 's/^POSTS_FOUND=1/POSTS_FOUND=banana/' "$DC/contract.env";;
    url)             sed -i '' 's|^POST_1_URL=.*|POST_1_URL=https://evil.example.com/x|' "$DC/contract.env";;
    linkless_url)    sed -i '' 's|^POST_1_URL=.*|POST_1_URL=-|' "$DC/contract.env";;
    watermark)       sed -i '' 's/^PROPOSED_WATERMARK=.*/PROPOSED_WATERMARK=1784992999.000000/' "$DC/contract.env";;
    stale_watermark) sed -i '' "s/^PROPOSED_WATERMARK=.*/PROPOSED_WATERMARK=${SEED_TS}/" "$DC/contract.env";;
    conservation)    jq '.conservation.jobs_new += 1' "$DC/manifest.json" > "$DC/m.tmp" && mv "$DC/m.tmp" "$DC/manifest.json";;
  esac
  INBOX_OUT="$DC"; validate_inbox_contract
  t "V rejects $case_name" '[ "$INBOX_CONTRACT_OK" = 0 ]'
done

# ---- install gates, draft mode
INBOX_OUT="$D"; validate_inbox_contract
mkdir -p linkedin-compain && echo '[]' > linkedin-compain/comments.json
INBOX_NOTE=""; install_inbox_state
t "I1 draft-mode install blocked"  '[ "$(jq -r .last_ts state.json)" = "$SEED_TS" ]'
jq -n --arg k "$KEY" --argjson v "$DRAFTS" '[{key: $k, disposition: "drafted", source: "slack-inbox", variants: $v, clickup_task_id: null, clickup_error: null, clickup_comment_ids: [], clickup_comment_error: null}]' > linkedin-compain/comments.json
INBOX_NOTE=""; install_inbox_state
t "I2 blocked w/o delivery legs"   '[ "$(jq -r .last_ts state.json)" = "$SEED_TS" ]'
# Task alone is NOT completion while variants remain undelivered.
jq '(.[0].clickup_task_id) = "86abc"' \
  linkedin-compain/comments.json > c.tmp && mv c.tmp linkedin-compain/comments.json
INBOX_NOTE=""; install_inbox_state
t "I2b task alone still blocked"   '[ "$(jq -r .last_ts state.json)" = "$SEED_TS" ]'
jq --argjson c "$CMT_IDS" '(.[0].clickup_comment_ids) = $c' \
  linkedin-compain/comments.json > c.tmp && mv c.tmp linkedin-compain/comments.json
INBOX_NOTE=""; install_inbox_state
t "I3 both legs install ok"        '[ "$(jq -r .last_ts state.json)" = "$MSG_TS" ]'

# ---- install gates, clickup-only mode (entry pre-exists: existence proves nothing)
jq -n --arg ts "$SEED_TS" '{last_ts: $ts, updated_at: "x", pending: [], dead: []}' > state.json
jq -n --arg k "$KEY" --arg u "$URL" --argjson v "$DRAFTS" \
  '[{key: $k, disposition: "drafted", post_url: $u, author_name: "David Linthicum",
     post_text: "x", author_url: null, author_headline: "", urn: null, variants: $v,
     source: "slack-inbox", clickup_task_id: null, clickup_error: null,
     clickup_comment_ids: [], clickup_comment_error: null}]' > comments-c.json
DC="$WORK/vc"; gen_contract "$DC" "$WORK/comments-c.json"
INBOX_OUT="$DC"; validate_inbox_contract
t "C1 clickup-only contract"       '[ "$INBOX_CONTRACT_OK" = 1 ] && grep -q "^POST_1_MODE=clickup-only" "$DC/contract.env"'
t "C1b flags missing comment leg"  'grep -q "^POST_1_NEED_COMMENTS=1" "$DC/contract.env"'
cp comments-c.json linkedin-compain/comments.json   # untouched entry: no task id, no error, no comments
INBOX_NOTE=""; install_inbox_state
t "C2 blocked w/o mutation proof"  '[ "$(jq -r .last_ts state.json)" = "$SEED_TS" ]'
jq '(.[0].clickup_error) = "listTasks failed"' comments-c.json > linkedin-compain/comments.json
INBOX_NOTE=""; install_inbox_state
t "C3 blocked w/o comment evidence" '[ "$(jq -r .last_ts state.json)" = "$SEED_TS" ]'
jq --argjson c "$CMT_IDS" '(.[0].clickup_error) = "listTasks failed" | (.[0].clickup_comment_ids) = $c' \
  comments-c.json > linkedin-compain/comments.json
INBOX_NOTE=""; install_inbox_state
t "C4 both legs unblock"           '[ "$(jq -r .last_ts state.json)" = "$MSG_TS" ]'

echo
if [ "$FAILURES" -gt 0 ]; then echo "$FAILURES FAILED (work dir kept: $WORK)"; exit 1; fi
echo "ALL PASS"
cd / && rm -rf "$WORK"
