#!/usr/bin/env bash
# Deterministic fixture tests for gather-inbox.mjs (no browser, no network:
# --fetch-stub). Run from anywhere: ./test-gather-inbox.sh — exits nonzero on
# the first failing assertion group; each scenario prints PASS/FAIL.
#
# Fixtures: fixtures/slack-messages.json is a sanitized capture of the real
# proxy payload (8 messages: 1 human with the davidlinthicum link + 7 bot),
# fixtures/fetch-stub.json maps the normalized link to the real unfurled post
# body — so the happy path asserts EXACT expected text end-to-end.
set -uo pipefail

FAST_DIR="$(cd "$(dirname "$0")" && pwd)"
FIX="$FAST_DIR/fixtures"
WORK="$(cd "$FAST_DIR/../../../.." && pwd)/tmp/inbox-tests/run-$$"
mkdir -p "$WORK"
MSG_TS="1784992193.489909"
SEED_TS="1784992000.000000"
URL="https://www.linkedin.com/posts/davidlinthicum_the-hidden-tax-on-honest-discourse-in-technology-ugcPost-7486729143691337728-2b55"
POST_KEY=$(node --input-type=module -e "
import { makeKey } from 'file://$FAST_DIR/keys.mjs';
import fs from 'node:fs';
const stub = JSON.parse(fs.readFileSync('$FIX/fetch-stub.json', 'utf8'));
console.log(makeKey('David Linthicum', stub['$URL'].body));
")

FAILURES=0
t() { # t <name> <shell-condition...>
  local name="$1"; shift
  if eval "$@" >/dev/null 2>&1; then echo "PASS: $name"; else echo "FAIL: $name"; FAILURES=$((FAILURES+1)); fi
}

state() { # state <file> <last_ts> [pending-json] [dead-json]
  jq -n --arg ts "$2" --argjson p "${3:-[]}" --argjson d "${4:-[]}" \
    '{last_ts: $ts, updated_at: "2026-07-25T00:00:00Z", pending: $p, dead: $d}' > "$1"
}

entry() { # entry <disposition> <clickup_task_id|null> <post_url|null>
  jq -n --arg k "$POST_KEY" --arg d "$1" \
    --argjson c "${2:-null}" --argjson u "${3:-null}" \
    '{key: $k, urn: null, post_url: $u, author_url: "https://www.linkedin.com/in/davidlinthicum",
      author_name: "David Linthicum", author_headline: "x", time_ago: null,
      post_text: "PLACEHOLDER", scraped_at: "2026-07-20T00:00:00Z", disposition: $d,
      reason: null, variants: [], draft_error: null,
      source: "feed", clickup_task_id: $c, clickup_url: null, clickup_adopted: null,
      clickup_comment_ids: [], clickup_comment_error: null, clickup_error: null}'
}

# Two stored drafts + the comment ids that would prove their delivery. The
# comment leg is only exercised when an entry HAS variants — an entry with
# none is trivially delivered (nothing to post).
DRAFTS='[{"strategy_label":"s1","comment":"c1","rationale":"r1"},{"strategy_label":"s2","comment":"c2","rationale":"r2"}]'
CMT_IDS='["cmt-aaa","cmt-bbb"]'

run() { # run <dir> <state> <comments> [extra args...]
  local dir="$1" st="$2" cm="$3"; shift 3
  mkdir -p "$dir"
  node "$FAST_DIR/gather-inbox.mjs" \
    --messages-file="$FIX/slack-messages.json" \
    --state-file="$st" --comments-file="$cm" --out-dir="$dir" \
    --fetch-stub="$FIX/fetch-stub.json" "$@" \
    > "$dir/stdout.log" 2> "$dir/stderr.log"
  echo "$?" > "$dir/exit"
}

cg() { grep "^$2=" "$1/contract.env" | head -1 | cut -d= -f2-; }
conservation_ok() {
  jq -e '.conservation | (.jobs_pending_in + .jobs_new) ==
    (.contract_rows + .pending_out + .dead_new + .accounted_dupes
     + .skipped_already_commented + .alias_merged)' "$1/manifest.json"
}

# ---- T1: fresh state, happy path (exact body text end-to-end)
D="$WORK/t1"; state "$WORK/t1-state.json" "$SEED_TS"; echo '[]' > "$WORK/t1-comments.json"
run "$D" "$WORK/t1-state.json" "$WORK/t1-comments.json"
t "T1 exit 0"                 '[ "$(cat "$D/exit")" = 0 ]'
t "T1 one draft row"          '[ "$(cg "$D" POSTS_FOUND)" = 1 ] && [ "$(cg "$D" POST_1_MODE)" = draft ]'
t "T1 key recipe"             '[ "$(cg "$D" POST_1_KEY)" = "$POST_KEY" ]'
t "T1 exact body text"        '[ "$(cat "$(cg "$D" POST_1_TEXT_FILE)")" = "$(jq -r ".[\"$URL\"].body" "$FIX/fetch-stub.json")" ]'
t "T1 canonical url"          '[ "$(cg "$D" POST_1_URL)" = "$URL" ]'
t "T1 source fields"          '[ "$(cg "$D" POST_1_SOURCE)" = slack-inbox ] && [ "$(cg "$D" POST_1_SOURCE_TS)" = "$MSG_TS" ]'
t "T1 watermark = msg ts"     '[ "$(cg "$D" PROPOSED_WATERMARK)" = "$MSG_TS" ]'
t "T1 bot messages filtered"  '[ "$(cg "$D" INBOX_MSGS_HUMAN)" = 1 ] && [ "$(cg "$D" INBOX_MSGS_SCANNED)" = 8 ]'
t "T1 conservation"           'conservation_ok "$D"'
t "T1 keys.json"              '[ "$(jq length "$D/keys.json")" = 1 ]'
t "T1 clean proposed state"   'jq -e ".pending == [] and .dead == [] and .last_ts == \"$MSG_TS\"" "$D/proposed-state.json"'

# ---- T2: already drafted with task id AND every draft comment delivered
#      → accounted dup (both ClickUp legs evidenced)
D="$WORK/t2"; state "$WORK/t2-state.json" "$SEED_TS"
jq -n --argjson e "$(entry drafted '"86xyz"' "\"$URL\"")" --argjson v "$DRAFTS" --argjson c "$CMT_IDS" \
  '[$e | .variants = $v | .clickup_comment_ids = $c]' > "$WORK/t2-comments.json"
run "$D" "$WORK/t2-state.json" "$WORK/t2-comments.json"
t "T2 no rows"                '[ "$(cg "$D" POSTS_FOUND)" = 0 ]'
t "T2 counted dup"            '[ "$(cg "$D" INBOX_DUPLICATES)" = 1 ]'
t "T2 conservation"           'conservation_ok "$D"'

# ---- T3: drafted WITHOUT task id → clickup-only row (fetchless)
D="$WORK/t3"; state "$WORK/t3-state.json" "$SEED_TS"
jq -n --argjson e "$(entry drafted null "\"$URL\"")" '[$e]' > "$WORK/t3-comments.json"
run "$D" "$WORK/t3-state.json" "$WORK/t3-comments.json"
t "T3 clickup-only row"       '[ "$(cg "$D" POSTS_FOUND)" = 1 ] && [ "$(cg "$D" POST_1_MODE)" = clickup-only ]'
t "T3 matched key"            '[ "$(cg "$D" POST_1_MATCHED_KEY)" = "$POST_KEY" ]'
t "T3 conservation"           'conservation_ok "$D"'

# ---- T4: off-topic entry (post_url null, like real filtered entries) → reprocess
D="$WORK/t4"; state "$WORK/t4-state.json" "$SEED_TS"
jq -n --argjson e "$(entry off-topic null null)" '[$e]' \
  | jq --arg b "$(jq -r ".[\"$URL\"].body" "$FIX/fetch-stub.json")" '.[0].post_text = $b' > "$WORK/t4-comments.json"
run "$D" "$WORK/t4-state.json" "$WORK/t4-comments.json"
t "T4 reprocess row"          '[ "$(cg "$D" POSTS_FOUND)" = 1 ] && [ "$(cg "$D" POST_1_MODE)" = reprocess-off-topic ]'
t "T4 matched key"            '[ "$(cg "$D" POST_1_MATCHED_KEY)" = "$POST_KEY" ]'

# ---- T5: already-commented entry → skipped
D="$WORK/t5"; state "$WORK/t5-state.json" "$SEED_TS"
jq -n --argjson e "$(entry already-commented null null)" '[$e]' \
  | jq --arg b "$(jq -r ".[\"$URL\"].body" "$FIX/fetch-stub.json")" '.[0].post_text = $b' > "$WORK/t5-comments.json"
run "$D" "$WORK/t5-state.json" "$WORK/t5-comments.json"
t "T5 no rows"                '[ "$(cg "$D" POSTS_FOUND)" = 0 ]'
t "T5 counted skip"           '[ "$(cg "$D" INBOX_SKIPPED_ALREADY_COMMENTED)" = 1 ]'
t "T5 conservation"           'conservation_ok "$D"'

# ---- T7: transient fetch failure → pending, exit 10
D="$WORK/t7"; state "$WORK/t7-state.json" "$SEED_TS"; echo '[]' > "$WORK/t7-comments.json"
jq '{("'"$URL"'"): {fail: "transient", reason: "nav timeout (test)"}}' -n > "$WORK/t7-stub.json"
mkdir -p "$D"
node "$FAST_DIR/gather-inbox.mjs" --messages-file="$FIX/slack-messages.json" \
  --state-file="$WORK/t7-state.json" --comments-file="$WORK/t7-comments.json" \
  --out-dir="$D" --fetch-stub="$WORK/t7-stub.json" >/dev/null 2>"$D/stderr.log"; echo $? > "$D/exit"
t "T7 exit 10"                '[ "$(cat "$D/exit")" = 10 ]'
t "T7 pending w/ attempt"     'jq -e ".pending | length == 1 and .[0].attempts == 1 and .[0].last_error != null" "$D/proposed-state.json"'
t "T7 watermark advances"     '[ "$(cg "$D" PROPOSED_WATERMARK)" = "$MSG_TS" ]'
t "T7 conservation"           'conservation_ok "$D"'

# ---- T8: attempts at cap → dead with reason
D="$WORK/t8"
state "$WORK/t8-state.json" "$MSG_TS" "[{\"url\": \"$URL\", \"requests\": [{\"message_ts\": \"$MSG_TS\", \"user\": \"US52EFX2S\"}], \"attempts\": 4, \"last_error\": \"nav\", \"first_seen\": \"2026-07-22T00:00:00Z\"}]"
echo '[]' > "$WORK/t8-comments.json"
mkdir -p "$D"
node "$FAST_DIR/gather-inbox.mjs" --messages-file="$FIX/slack-messages.json" \
  --state-file="$WORK/t8-state.json" --comments-file="$WORK/t8-comments.json" \
  --out-dir="$D" --fetch-stub="$WORK/t7-stub.json" >/dev/null 2>"$D/stderr.log"; echo $? > "$D/exit"
t "T8 dead-lettered"          'jq -e ".dead | length == 1 and (.[0].reason | test(\"gave up after 5\"))" "$D/proposed-state.json"'
t "T8 pending drained"        'jq -e ".pending == []" "$D/proposed-state.json"'
t "T8 conservation"           'conservation_ok "$D"'

# ---- T9: tombstone → immediate dead
D="$WORK/t9"; state "$WORK/t9-state.json" "$SEED_TS"; echo '[]' > "$WORK/t9-comments.json"
jq '{("'"$URL"'"): {fail: "tombstone", reason: "post deleted (test)"}}' -n > "$WORK/t9-stub.json"
mkdir -p "$D"
node "$FAST_DIR/gather-inbox.mjs" --messages-file="$FIX/slack-messages.json" \
  --state-file="$WORK/t9-state.json" --comments-file="$WORK/t9-comments.json" \
  --out-dir="$D" --fetch-stub="$WORK/t9-stub.json" >/dev/null 2>"$D/stderr.log"; echo $? > "$D/exit"
t "T9 immediate dead"         'jq -e ".dead | length == 1 and .[0].reason == \"post deleted (test)\"" "$D/proposed-state.json"'
t "T9 no pending"             'jq -e ".pending == []" "$D/proposed-state.json"'

# ---- T10: dead URL revived by a NEW message
D="$WORK/t10"
state "$WORK/t10-state.json" "$SEED_TS" '[]' "[{\"url\": \"$URL\", \"requests\": [], \"reason\": \"old\", \"died_at\": \"2026-07-20T00:00:00Z\"}]"
echo '[]' > "$WORK/t10-comments.json"
run "$D" "$WORK/t10-state.json" "$WORK/t10-comments.json"
t "T10 revived + drafted"     '[ "$(cg "$D" INBOX_REVIVED)" = 1 ] && [ "$(cg "$D" POSTS_FOUND)" = 1 ]'
t "T10 dead cleared"          'jq -e ".dead == []" "$D/proposed-state.json"'
t "T10 conservation"          'conservation_ok "$D"'

# ---- T11: edited-window replay (msg BELOW watermark, unaccounted link) → processed
D="$WORK/t11"; state "$WORK/t11-state.json" "1784992200.000000"; echo '[]' > "$WORK/t11-comments.json"
run "$D" "$WORK/t11-state.json" "$WORK/t11-comments.json"
t "T11 replay processed"      '[ "$(cg "$D" POSTS_FOUND)" = 1 ]'
t "T11 watermark held"        '[ "$(cg "$D" PROPOSED_WATERMARK)" = "1784992200.000000" ]'

# ---- T12: dead NOT revived by a replayed message
D="$WORK/t12"
state "$WORK/t12-state.json" "1784992200.000000" '[]' "[{\"url\": \"$URL\", \"requests\": [], \"reason\": \"old\", \"died_at\": \"2026-07-20T00:00:00Z\"}]"
echo '[]' > "$WORK/t12-comments.json"
run "$D" "$WORK/t12-state.json" "$WORK/t12-comments.json"
t "T12 no rows, no revival"   '[ "$(cg "$D" POSTS_FOUND)" = 0 ] && [ "$(cg "$D" INBOX_REVIVED)" = 0 ]'
t "T12 dead retained"         'jq -e ".dead | length == 1" "$D/proposed-state.json"'

# ---- T13: missing state file → exit 23, nothing written
D="$WORK/t13"; mkdir -p "$D"
node "$FAST_DIR/gather-inbox.mjs" --messages-file="$FIX/slack-messages.json" \
  --state-file="$WORK/nonexistent-state.json" --comments-file="$WORK/t1-comments.json" \
  --out-dir="$D" --fetch-stub="$FIX/fetch-stub.json" >/dev/null 2>"$D/stderr.log"; echo $? > "$D/exit"
t "T13 exit 23 on no state"   '[ "$(cat "$D/exit")" = 23 ]'

# ---- T14: second run after T1's full delivery → idempotent no-op
D="$WORK/t14"; state "$WORK/t14-state.json" "$MSG_TS"
jq -n --argjson e "$(entry drafted '"86xyz"' "\"$URL\"")" --argjson v "$DRAFTS" --argjson c "$CMT_IDS" \
  '[$e | .variants = $v | .clickup_comment_ids = $c]' > "$WORK/t14-comments.json"
run "$D" "$WORK/t14-state.json" "$WORK/t14-comments.json"
t "T14 idempotent"            '[ "$(cg "$D" POSTS_FOUND)" = 0 ] && [ "$(cg "$D" PROPOSED_WATERMARK)" = "$MSG_TS" ]'

# ---- T15: cap overflow → durable backlog
D="$WORK/t15"; state "$WORK/t15-state.json" "$SEED_TS"; echo '[]' > "$WORK/t15-comments.json"
jq '.messages += [{ts: "1784992300.000001", user: "US52EFX2S", bot_id: null, subtype: null, text: "and this one <https://www.linkedin.com/posts/other-author_second-post-activity-1234567890123456789-abcd/?utm_source=share>", attachments: []}]' \
  "$FIX/slack-messages.json" > "$WORK/t15-messages.json"
mkdir -p "$D"
node "$FAST_DIR/gather-inbox.mjs" --messages-file="$WORK/t15-messages.json" \
  --state-file="$WORK/t15-state.json" --comments-file="$WORK/t15-comments.json" \
  --out-dir="$D" --fetch-stub="$FIX/fetch-stub.json" --max-links=1 >/dev/null 2>"$D/stderr.log"; echo $? > "$D/exit"
t "T15 one fetched, one queued" '[ "$(cg "$D" POSTS_FOUND)" = 1 ] && [ "$(cg "$D" INBOX_BACKLOG)" = 1 ]'
t "T15 overflow keeps requests" 'jq -e ".pending[0].requests | length == 1" "$D/proposed-state.json"'
t "T15 watermark = newest"      '[ "$(cg "$D" PROPOSED_WATERMARK)" = "1784992300.000001" ]'
t "T15 exit 10 (backlog)"       '[ "$(cat "$D/exit")" = 10 ]'
t "T15 conservation"            'conservation_ok "$D"'

# ---- T16: link carried only in blocks[] rich-text (no <url> in text)
D="$WORK/t16"; state "$WORK/t16-state.json" "$SEED_TS"; echo '[]' > "$WORK/t16-comments.json"
jq --arg u "$URL" '.messages = [.messages[0]] | .messages[0].text = "see the post" | .messages[0].attachments = [] |
  .messages[0].blocks = [{type: "rich_text", elements: [{type: "rich_text_section", elements: [{type: "link", url: ($u + "/?utm_source=share")}]}]}]' \
  "$FIX/slack-messages.json" > "$WORK/t16-messages.json"
mkdir -p "$D"
node "$FAST_DIR/gather-inbox.mjs" --messages-file="$WORK/t16-messages.json" \
  --state-file="$WORK/t16-state.json" --comments-file="$WORK/t16-comments.json" \
  --out-dir="$D" --fetch-stub="$FIX/fetch-stub.json" >/dev/null 2>"$D/stderr.log"; echo $? > "$D/exit"
t "T16 blocks link extracted"  '[ "$(cg "$D" INBOX_LINKS_FOUND)" = 1 ] && [ "$(cg "$D" POSTS_FOUND)" = 1 ]'

# ---- T17: short-link + canonical alias of the SAME post across two messages
D="$WORK/t17"; state "$WORK/t17-state.json" "$SEED_TS"; echo '[]' > "$WORK/t17-comments.json"
jq --arg u "$URL" '.messages += [{ts: "1784992300.000002", user: "US52EFX2S", bot_id: null, subtype: null,
  text: "short form <https://lnkd.in/pALIAS42>", attachments: []}]' \
  "$FIX/slack-messages.json" > "$WORK/t17-messages.json"
jq --arg u "$URL" '. + {"https://lnkd.in/pALIAS42": .[$u]}' "$FIX/fetch-stub.json" > "$WORK/t17-stub.json"
mkdir -p "$D"
node "$FAST_DIR/gather-inbox.mjs" --messages-file="$WORK/t17-messages.json" \
  --state-file="$WORK/t17-state.json" --comments-file="$WORK/t17-comments.json" \
  --out-dir="$D" --fetch-stub="$WORK/t17-stub.json" >/dev/null 2>"$D/stderr.log"; echo $? > "$D/exit"
t "T17 one row from two aliases" '[ "$(cg "$D" POSTS_FOUND)" = 1 ]'
t "T17 alias merged + requests"  'jq -e ".conservation.alias_merged == 1" "$D/manifest.json" && [ "$(cg "$D" POST_1_REQUESTS | jq length)" = 2 ]'
t "T17 conservation"             'conservation_ok "$D"'

# ---- T18: legacy off-topic entry whose key recomputes differently (fuzzy bridge)
D="$WORK/t18"; state "$WORK/t18-state.json" "$SEED_TS"
# Same first-160-normalized-chars (fuzzy id matches) but a different tail
# (whole-body hash differs) — the exact shape of the 75 real legacy entries.
LEGACY_BODY="$(jq -r ".[\"$URL\"].body" "$FIX/fetch-stub.json")

[legacy feed footer noise that changes the hash]"
LEGACY_KEY=$(LB="$LEGACY_BODY" node --input-type=module -e "
import { makeKey } from 'file://$FAST_DIR/keys.mjs';
console.log(makeKey('David Linthicum', process.env.LB));")
jq -n --argjson e "$(entry off-topic null null)" --arg b "$LEGACY_BODY" --arg k "$LEGACY_KEY" \
  '[$e | .post_text = $b | .key = $k]' > "$WORK/t18-comments.json"
run "$D" "$WORK/t18-state.json" "$WORK/t18-comments.json"
t "T18 reprocess via fuzzy"    '[ "$(cg "$D" POST_1_MODE)" = reprocess-off-topic ]'
t "T18 matched legacy key"     '[ "$(cg "$D" POST_1_MATCHED_KEY)" = "$LEGACY_KEY" ] && [ "$(cg "$D" POST_1_KEY)" = "$POST_KEY" ] && [ "$POST_KEY" != "$LEGACY_KEY" ]'

# ---- T19: scan_floor_ts clamp — a message below the deployment floor is never processed
D="$WORK/t19"
jq -n '{last_ts: "'"$SEED_TS"'", scan_floor_ts: "1784992500.000000", updated_at: "x", pending: [], dead: []}' > "$WORK/t19-state.json"
echo '[]' > "$WORK/t19-comments.json"
run "$D" "$WORK/t19-state.json" "$WORK/t19-comments.json"
t "T19 pre-floor msg excluded" '[ "$(cg "$D" INBOX_LINKS_FOUND)" = 0 ] && [ "$(cg "$D" POSTS_FOUND)" = 0 ]'
t "T19 floor survives install" 'jq -e ".scan_floor_ts == \"1784992500.000000\"" "$D/proposed-state.json"'

# ---- T20: clickup-only row from a POST-fetch match uses FETCHED fields, not stale ledger ones
D="$WORK/t20"; state "$WORK/t20-state.json" "$SEED_TS"
jq -n --argjson e "$(entry drafted null null)" \
  --arg b "$(jq -r ".[\"$URL\"].body" "$FIX/fetch-stub.json")" \
  '[$e | .post_text = $b | .author_url = "https://www.linkedin.com/in/davidlinthicum"]' > "$WORK/t20-comments.json"
run "$D" "$WORK/t20-state.json" "$WORK/t20-comments.json"
t "T20 clickup-only post-fetch" '[ "$(cg "$D" POST_1_MODE)" = clickup-only ]'
t "T20 fetched permalink used"  '[ "$(cg "$D" POST_1_URL)" = "$URL" ]'

# ---- T21: pending URL that now matches a drafted-without-task ledger entry
# is completed FETCHLESSLY (the failing stub proves no fetch was attempted)
D="$WORK/t21"
state "$WORK/t21-state.json" "$MSG_TS" "[{\"url\": \"$URL\", \"requests\": [{\"message_ts\": \"$MSG_TS\", \"user\": \"US52EFX2S\"}], \"attempts\": 2, \"last_error\": \"nav\", \"first_seen\": \"2026-07-22T00:00:00Z\"}]"
jq -n --argjson e "$(entry drafted null "\"$URL\"")" --argjson v "$DRAFTS" \
  '[$e | .variants = $v]' > "$WORK/t21-comments.json"
mkdir -p "$D"
node "$FAST_DIR/gather-inbox.mjs" --messages-file="$FIX/slack-messages.json" \
  --state-file="$WORK/t21-state.json" --comments-file="$WORK/t21-comments.json" \
  --out-dir="$D" --fetch-stub="$WORK/t7-stub.json" >/dev/null 2>"$D/stderr.log"; echo $? > "$D/exit"
t "T21 fetchless completion"   '[ "$(cg "$D" POSTS_FOUND)" = 1 ] && [ "$(cg "$D" POST_1_MODE)" = clickup-only ]'
t "T21 no fetch failure"       '[ "$(cg "$D" INBOX_FETCH_FAILED)" = 0 ] && jq -e ".pending == []" "$D/proposed-state.json"'
t "T21 needs comment leg too"  '[ "$(cg "$D" POST_1_NEED_COMMENTS)" = 1 ]'

# ---- T22: /me message subtype is human
D="$WORK/t22"; state "$WORK/t22-state.json" "$SEED_TS"; echo '[]' > "$WORK/t22-comments.json"
jq '.messages = [.messages[0]] | .messages[0].subtype = "me_message"' \
  "$FIX/slack-messages.json" > "$WORK/t22-messages.json"
mkdir -p "$D"
node "$FAST_DIR/gather-inbox.mjs" --messages-file="$WORK/t22-messages.json" \
  --state-file="$WORK/t22-state.json" --comments-file="$WORK/t22-comments.json" \
  --out-dir="$D" --fetch-stub="$FIX/fetch-stub.json" >/dev/null 2>"$D/stderr.log"; echo $? > "$D/exit"
t "T22 me_message processed"   '[ "$(cg "$D" INBOX_MSGS_HUMAN)" = 1 ] && [ "$(cg "$D" POSTS_FOUND)" = 1 ]'

# ---- T23: alias whose post's OPENING was edited — canonical-URL dedup catches it
D="$WORK/t23"; state "$WORK/t23-state.json" "$SEED_TS"
# Ledger holds the post under its canonical URL with both ClickUp legs
# complete, but an OLD body whose first 160 chars differ from today's fetch.
jq -n --argjson e "$(entry drafted '"86xyz"' "\"$URL\"")" --argjson v "$DRAFTS" --argjson c "$CMT_IDS" \
  '[$e | .post_text = "A completely different old opening that shares no prefix with the new body at all." | .variants = $v | .clickup_comment_ids = $c]' > "$WORK/t23-comments.json"
jq '.messages = [.messages[0]] | .messages[0].text = "<https://lnkd.in/pEDITED99>" | .messages[0].attachments = []' \
  "$FIX/slack-messages.json" > "$WORK/t23-messages.json"
jq --arg u "$URL" '{"https://lnkd.in/pEDITED99": .[$u]}' "$FIX/fetch-stub.json" > "$WORK/t23-stub.json"
mkdir -p "$D"
node "$FAST_DIR/gather-inbox.mjs" --messages-file="$WORK/t23-messages.json" \
  --state-file="$WORK/t23-state.json" --comments-file="$WORK/t23-comments.json" \
  --out-dir="$D" --fetch-stub="$WORK/t23-stub.json" >/dev/null 2>"$D/stderr.log"; echo $? > "$D/exit"
t "T23 canonical-url dedup"    '[ "$(cg "$D" POSTS_FOUND)" = 0 ] && [ "$(cg "$D" INBOX_DUPLICATES)" = 1 ]'
t "T23 conservation"           'conservation_ok "$D"'

# ---- T24: drafted entry with a task id but variants never delivered as
#      comments → comment-leg row (the task alone is not completion)
D="$WORK/t24"; state "$WORK/t24-state.json" "$SEED_TS"
jq -n --argjson e "$(entry drafted '"86xyz"' "\"$URL\"")" --argjson v "$DRAFTS" \
  '[$e | .variants = $v]' > "$WORK/t24-comments.json"
run "$D" "$WORK/t24-state.json" "$WORK/t24-comments.json"
t "T24 comment leg re-delivered" '[ "$(cg "$D" POSTS_FOUND)" = 1 ] && [ "$(cg "$D" POST_1_MODE)" = clickup-only ] && [ "$(cg "$D" POST_1_NEED_COMMENTS)" = 1 ]'

# ---- T24b: PARTIAL comment ids (a kill landed mid-delivery loop) still owes
#      the leg — the count must be compared, not merely tested for non-empty
D="$WORK/t24b"; state "$WORK/t24b-state.json" "$SEED_TS"
jq -n --argjson e "$(entry drafted '"86xyz"' "\"$URL\"")" --argjson v "$DRAFTS" \
  '[$e | .variants = $v | .clickup_comment_ids = ["cmt-aaa"]]' > "$WORK/t24b-comments.json"
run "$D" "$WORK/t24b-state.json" "$WORK/t24b-comments.json"
t "T24b partial ids still owed" '[ "$(cg "$D" POSTS_FOUND)" = 1 ] && [ "$(cg "$D" POST_1_NEED_COMMENTS)" = 1 ]'

# ---- T24c: a recorded clickup_comment_error terminates the leg → dup
D="$WORK/t24c"; state "$WORK/t24c-state.json" "$SEED_TS"
jq -n --argjson e "$(entry drafted '"86xyz"' "\"$URL\"")" --argjson v "$DRAFTS" \
  '[$e | .variants = $v | .clickup_comment_error = "addTaskComment 500"]' > "$WORK/t24c-comments.json"
run "$D" "$WORK/t24c-state.json" "$WORK/t24c-comments.json"
t "T24c comment error ends leg" '[ "$(cg "$D" POSTS_FOUND)" = 0 ] && [ "$(cg "$D" INBOX_DUPLICATES)" = 1 ]'

# ---- T24d: a draft-failed entry (no variants) owes no comments — the task
#      alone completes it, so a re-drop is a dup
D="$WORK/t24d"; state "$WORK/t24d-state.json" "$SEED_TS"
jq -n --argjson e "$(entry drafted '"86xyz"' "\"$URL\"")" \
  '[$e | .draft_error = "ERROR=PARSE"]' > "$WORK/t24d-comments.json"
run "$D" "$WORK/t24d-state.json" "$WORK/t24d-comments.json"
t "T24d no variants = no leg"  '[ "$(cg "$D" POSTS_FOUND)" = 0 ] && [ "$(cg "$D" INBOX_DUPLICATES)" = 1 ]'

# ---- T25: fuzzy match DISQUALIFIED when canonical URLs differ (same author
# boilerplate opener on two distinct posts must not collapse into a dup)
D="$WORK/t25"; state "$WORK/t25-state.json" "$SEED_TS"
jq -n --argjson e "$(entry drafted '"86xyz"' "\"https://www.linkedin.com/posts/davidlinthicum_other-post-activity-999-zz\"")" \
  --arg b "$(jq -r ".[\"$URL\"].body" "$FIX/fetch-stub.json")" \
  '[$e | .key = "david-linthicum-aaaaaaaa" | .post_text = ($b + "\n\ncompletely different ending making a different hash")]' > "$WORK/t25-comments.json"
run "$D" "$WORK/t25-state.json" "$WORK/t25-comments.json"
t "T25 not a dup of post A"    '[ "$(cg "$D" POSTS_FOUND)" = 1 ] && [ "$(cg "$D" POST_1_MODE)" = draft ]'
t "T25 conservation"           'conservation_ok "$D"'

# ---- T26: code-formatted (bare, un-tokenized) URL still extracted
D="$WORK/t26"; state "$WORK/t26-state.json" "$SEED_TS"; echo '[]' > "$WORK/t26-comments.json"
jq --arg u "$URL" '.messages = [.messages[0]] | .messages[0].text = ("please handle \u0060" + $u + "/?utm_source=share\u0060 today") | .messages[0].attachments = []' \
  "$FIX/slack-messages.json" > "$WORK/t26-messages.json"
mkdir -p "$D"
node "$FAST_DIR/gather-inbox.mjs" --messages-file="$WORK/t26-messages.json" \
  --state-file="$WORK/t26-state.json" --comments-file="$WORK/t26-comments.json" \
  --out-dir="$D" --fetch-stub="$FIX/fetch-stub.json" >/dev/null 2>"$D/stderr.log"; echo $? > "$D/exit"
t "T26 bare code-styled url"   '[ "$(cg "$D" INBOX_LINKS_FOUND)" = 1 ] && [ "$(cg "$D" POSTS_FOUND)" = 1 ]'

echo
if [ "$FAILURES" -gt 0 ]; then echo "$FAILURES assertion(s) FAILED (work dir kept: $WORK)"; exit 1; fi
echo "ALL PASS"
rm -rf "$WORK"
