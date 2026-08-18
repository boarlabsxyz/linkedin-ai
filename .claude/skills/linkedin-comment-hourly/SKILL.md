---
name: linkedin-comment-hourly
description: >
  On each scheduled fire: read LinkedIn post links Peter dropped in Slack
  channel C0BF606R4N7 since the last fire (deterministic read-slack-inbox.sh +
  fast/gather-inbox.mjs, watermark in ./linkedin-compain/slack-inbox.json),
  gather 5 home-feed posts that pass all filters (unseen, on-topic per
  interests.md, AUTHOR inside the ICP per sources/icp.md + icp-filter.md, not
  already commented on, not a repost) via the deterministic
  fast/gather-feed.mjs scraper, draft 2-3 comment variants per post
  via the linkedin-comment-ideas skill (full pre-work checklist), append one
  entry per post to the single ./linkedin-compain/comments.json array, and
  create one ClickUp task per accepted post (the source post itself) in list
  901524736848 with the drafts attached as one task comment per variant.
  Slack gets nothing per-post — the channel receives only the run bookends
  that run-hourly.sh posts.
  Use when the user says "run linkedin comment hourly", "gather linkedin
  comment drafts", "draft comments for the feed", "process the slack inbox
  links", or when the linkedin-comment-hourly workflow cron fires.
---

# LinkedIn Comment Hourly

Thin orchestrator. The gather step is a **deterministic fast script** (`fast/gather-feed.mjs` — scrape + classify + permalink recovery + filtered-entry appends, <5 min); two sub-agents do the drafting work — `prep-refs` (refresh the local reference cache once) and `draft` (fan out in parallel, one per post) — this skill glues them and delivers to ClickUp. The `gather-feed` agent survives only as the selector-drift fallback.

**Everything ships to ClickUp.** One task per accepted post holds the source post; the drafts land on that task as one comment per variant. You post **nothing** to Slack — the channel gets only the 🟢/✅ run bookends that `run-hourly.sh` posts around you.

## Constants

| Resource | ID / Path |
|---|---|
| Comments file | `./linkedin-compain/comments.json` (single JSON array — every post, drafted or filtered, is one object) |
| Interests file | `.claude/skills/linkedin-comment-hourly/interests.md` — gate 1 (topic) |
| ICP rubric | `sources/icp.md` — gate 2 (author), the canonical ClickUp-synced doc, shared verbatim with `linkedin-stats` |
| ICP gate rules | `.claude/skills/linkedin-comment-hourly/icp-filter.md` — how to judge the rubric from a card, plus the `## Always accept` / `## Never accept` profile-URL lists |
| ICP author cache | `./dashboards/li-stats/icp-authors.json` — **shared with `linkedin-stats`** (implementation in `.claude/skills/pipeline-shared/icp-cache.mjs`); one entry per author profile holding the **scraped profile text** plus the verdict derived from it. A profile read once is **not re-opened for 10 days** (`--icp-cache-ttl-days`), whatever changes about the person. Verdicts also carry the `rubric_hash` they were judged under: retune `icp-filter.md` or re-sync `sources/icp.md` and every cached author is **re-judged from the stored text, with no page loads**. Written by the gather; hand-editable. |
| Reference cache | `$HOME/.cache/linkedin-ai-refs` (local mirror of ICP / True BDD / Posted / Transcripts; **outside the worktree** so `git clean -fd` can't wipe it) |
| Slack channel | `C0BF606R4N7` (https://spdfn.slack.com/archives/C0BF606R4N7) — **read-only for you**: the inbox stage reads Peter's links from it, and `run-hourly.sh` posts the run bookends to it. You never post here. |
| Target posts per fire | `5` (feed) + up to 5 slack-inbox posts |
| ClickUp Comments list | `901524736848` (workspace `90151491867`) — one task per accepted post: the SOURCE POST itself (author, link, full text) in the description, and the drafts as **one task comment per variant** |
| ClickUp Source field | custom field id `3d8e441e-e225-4a1d-9601-5e4bf0cf7851` (short_text) — set to the post permalink |
| Inbox state file | `./linkedin-compain/slack-inbox.json` (watermark + pending/dead link queues; written ONLY by `run-hourly.sh`/`gather-inbox.mjs` — never edit it in this skill) |

`comments.json` is the single source of truth **and** the cross-fire seen-set. Each element is one post: drafted posts carry `variants` + their ClickUp task/comment ids; filtered posts (`off-topic` / `already-commented`) carry a `reason` and empty `variants`. The gather step (fast script, or the fallback agent) appends the filtered entries; you (the orchestrator) append the drafted ones. Never hand-write JSON — always mutate the array with `jq`.

## Flow

### Step 1 — Gather 5 posts from the home feed (fast script, agent only as fallback)

The gather is deterministic: `fast/gather-feed.mjs` scrapes the feed on the shared `mcp-chrome-linkedin-ai` Chrome profile, classifies candidates via batched tool-free `claude -p` haiku calls, appends the filtered entries to `comments.json` itself, recovers permalinks, and writes the contract to a run-scoped `tmp/gather-feed/<ts>/` dir.

**A post is accepted only when BOTH gates pass** (Peter, 2026-08-17 — "selects posts from my ICP only"):

1. **Topic** — on-topic per `interests.md`, as before.
2. **Author** — the author is inside the ICP (`sources/icp.md`, judged by `icp-filter.md`). Precedence: `## Never accept` list → `## Always accept` list → a cached verdict still matching today's rubric → the classifier's card verdict → **re-judge from cached profile text** (no page load) → a **profile probe** (open the author's LinkedIn profile, ≤20 per fire). If none of those can settle it, the post is left **unseen** rather than guessed either way.

The cache stores **scraped data, not just answers**: the ICP definition moves, the profile text does not. A profile is opened at most once per 10 days; within that window a stale verdict is refreshed from the stored text instead of a second page load, and a page read that failed to classify still counts as read (it is banked with `verdict: null`) so a classifier hiccup can't cost a second visit.

There is **no backfill**: a fire that can't find 5 ICP authors ships fewer posts (or none) instead of filling the gap with off-target ones. That is why the gather budget is 900s / 250 scrolls, and why `GATHER_END_REASON=deadline` with `POSTS_FOUND<5` is a normal outcome, not a failure.

ICP rejects are appended to `comments.json` as ordinary `off-topic` entries whose `reason` starts with `off-icp: ` — so a wrongly-rejected post is revived through the normal inbox `reprocess-off-topic` path when Peter drops its link in Slack. To repair a miss permanently, add the author to `icp-filter.md`.

Pick ONE of three paths:

1. **Pre-gathered (cron).** If your invocation prompt names a contract path (run-hourly.sh already ran the script), Read that `contract.env` and parse it. Do NOT re-run the script and do NOT spawn the gather agent.
2. **Run it yourself (interactive).** No contract in the prompt → run via Bash (**timeout 1200000** — the ICP gate needs up to ~15-18 min):
   ```bash
   [ -d .claude/skills/linkedin-comment-hourly/fast/node_modules/playwright-core ] || (cd .claude/skills/linkedin-comment-hourly/fast && npm install --no-audit --no-fund --silent)
   node .claude/skills/linkedin-comment-hourly/fast/gather-feed.mjs --deadline-secs=900
   ```
   The contract is printed on stdout (and written to `<OUT_DIR>/contract.env`). Exit 0/10 → parse it. Exit 20 (auth) / 21 (profile locked — close the Playwright MCP browser or another Chrome on the profile) / 22 (rate-limited) / 23 (fs) / 31 (classifier down) → report the failure and stop.
3. **Legacy agent fallback.** ONLY when the script exits 30 (selector drift) or the prompt explicitly says to use the legacy gather: spawn `linkedin-comment-hourly-gather-feed` via the Agent tool with prompt body:
   ```
   COMMENTS_FILE=./linkedin-compain/comments.json
   TARGET_COUNT=5
   MAX_SCROLL_ITERATIONS=250
   INTERESTS_FILE=.claude/skills/linkedin-comment-hourly/interests.md
   ICP_FILE=sources/icp.md
   ICP_FILTER_FILE=.claude/skills/linkedin-comment-hourly/icp-filter.md
   ```
   (The agent returns `POST_<i>_TEXT_B64` instead of `POST_<i>_TEXT_FILE` — decode via `base64 -d` to a temp file and treat that as the text file — and its legacy contract has no `GATHER_END_REASON` / `OUT_DIR`; treat those as absent.)

Contract keys: `POSTS_FOUND`, `POSTS_OFF_TOPIC`, `POSTS_OFF_ICP` (on-topic posts rejected because their author is outside the ICP — written to the ledger as `off-topic` entries with an `off-icp: ` reason, and counted into the driver's filtered total), `POSTS_ICP_UNDECIDED` (on-topic posts left unseen because the ICP question stayed unresolved — nothing was written, a later fire retries), `ICP_PROBES` / `ICP_CACHE_HITS` / `ICP_REJUDGED` (page loads spent, verdicts reused outright, and authors re-judged offline from cached profile text — `ICP_REJUDGED` spikes the first fire after the ICP rubric is retuned, which is exactly when it should), `POSTS_ALREADY_COMMENTED`, `POSTS_REPOSTS_SKIPPED`, `POSTS_PROMOTED_SKIPPED`, `SCROLL_ITERATIONS`, `FEED_EXHAUSTED`, `GATHER_END_REASON`, `PERMALINKS_MISSING` (count of accepted posts whose permalink capture failed end-to-end; >0 demotes the exit to 10 and makes the scheduled driver flag the fire ⚠️ + run a post-landing heal — a ticket shipping without its post link is an error, not a cosmetic gap; user-mandated 2026-07-21), `PERMALINKS_UNVERIFIED` (count of accepted posts whose `POST_<i>_URL` is a raw captured link kept without positive page verification — not an error, but a count that grows across fires means the verifier is broken and the keeps are masking it; added 2026-07-24), `OUT_DIR`, and `POST_<i>_KEY`, `POST_<i>_URN`, `POST_<i>_URL`, `POST_<i>_AUTHOR_URL`, `POST_<i>_AUTHOR`, `POST_<i>_HEADLINE`, `POST_<i>_TIME_AGO`, `POST_<i>_TEXT_FILE` for i = 1..`POSTS_FOUND`. `POST_<i>_TEXT_FILE` is an absolute path to the full post body — **post bodies travel as files, never as inline base64** (large inline blobs poisoned agent contexts and got generations refused, 2026-07-16 fire). `POST_<i>_URL` is the **post permalink**, in one of exactly two shapes: a `https://www.linkedin.com/posts/<slug>/` URL — verified (the copy-link payload's resolution target, which the script OPENED and confirmed renders the right post via author/body match — the normal case) or, when positive verification failed, kept raw from the copy-link payload with the tracking query stripped (the desktop copy-link sometimes writes the full canonical URL directly instead of a short link, first seen 2026-07-24) — or the raw `https://lnkd.in/p/<code>` short link when that is what the copy-link wrote and the resolved page couldn't be positively verified. Unverified keeps are counted in `PERMALINKS_UNVERIFIED` (rare; unverified but LinkedIn-issued, never rebuilt). It's `-` only when capture failed entirely. **Never emit `/feed/update/<urn>/` URLs or rebuild a permalink from a URN** — those internal routes render unreliably outside the full web app (user-verified 2026-07-16), and the urn type is load-bearing anyway (`activity` names the thread, `ugcPost`/`share` name the post — same post, different digits; guessing shipped 4 broken links). `POST_<i>_AUTHOR_URL` is the **author profile link**. `POST_<i>_URN` is best-effort metadata from the verified `/posts/` slug (the thread's activity id); `-` when ambiguous — a `-` URN does **not** imply a `-` URL. `POST_<i>_KEY` is the synthetic `<author-slug>-<body-hash8>` identifier. The script has already appended the off-topic / already-commented posts to `comments.json`; the `POST_<i>_*` entries are the relevant ones still needing drafts.

If `POSTS_FOUND=0`, emit the failure line (include `GATHER_END_REASON`), do NOT spawn Step 1.5 / Step 2, and stop. The shell driver's porcelain check still commits any filtered appends. **Exception:** when an inbox contract (Step 1b) has posts, Steps 1.5/2 still run for those.

### Step 1b — The slack-inbox contract (when the prompt names one)

Peter drops LinkedIn post links into the Slack channel; the deterministic `read-slack-inbox.sh` + `fast/gather-inbox.mjs` pair (run by `run-hourly.sh` BEFORE the feed gather, or by you interactively — same invocation shape, state file `./linkedin-compain/slack-inbox.json`) turns them into a second contract with the same `POST_<i>_*` keys plus:

- `POST_<i>_SOURCE=slack-inbox`, `POST_<i>_SOURCE_TS` / `POST_<i>_SOURCE_USER` / `POST_<i>_REQUESTS` — provenance (Peter's message ts/user; `REQUESTS` is a JSON list when several messages asked for the same post).
- `POST_<i>_MODE` — how to treat the post:
  - `draft` — full flow: draft variants, ledger entry, ClickUp task, draft comments on that task.
  - `reprocess-off-topic` — the post was previously auto-filtered off-topic, but Peter explicitly requested it: full flow, except the ledger write **updates the existing entry in place** at `POST_<i>_MATCHED_KEY` (set `disposition` to `drafted`, fill `variants`/`source`/`slack_request_ts`, keep the original `scraped_at`).
  - `clickup-only` — the post was already drafted in an earlier fire but one or both delivery legs never completed (a kill can land between the ledger write and the ClickUp calls): do **only** the completion work — the ClickUp task sub-step (adopt-or-create; the entry may already hold a task id, then adoption just confirms it), and, **when `POST_<i>_NEED_COMMENTS=1`**, the draft-comment sub-step run off the entry's **stored `variants`** (adopt any comment already carrying this post's marker, post only the missing ones). Record the ids into the entry exactly like a fresh draft. No draft agent either way.

Inbox posts are Peter-curated: NO interest filtering, NO **ICP** filtering, NO repost filtering — never second-guess an inbox post's topicality or its author.

### Step 1.5 — Refresh the local reference cache

Spawn `linkedin-comment-hourly-prep-refs` via the Agent tool (once, before any drafting). Its prompt body:

```
REF_CACHE=$HOME/.cache/linkedin-ai-refs
POSTED_FOLDER=1J_c1cWZ_kzPd_WrKsO_5fh-ud68seGOy
TRANSCRIPTS_FOLDER=13edYDnaAbHJN28gr9p-WK5dz-Qhi1th7
ICP_DOC=145BAhw3s8MYv7zozKTgP4uJ2is-TUQgpsWzWvgm28VE
TRUE_BDD_DOC=1Fn6-ElFqHHyGFg500InkB85MKpCzPhZT5N3GLVWdMYc
```

This agent does the fire's only Google Drive reads — it downloads the four reference sources into the local cache **once** (re-fetching only the docs whose Drive modified-date changed). Parse its return for `REF_CACHE` (and the individual paths); you pass `REF_CACHE` to every draft agent so drafting reads local files and needs zero GDrive access. If it returns `ERROR=<...>`, still proceed — the draft agents degrade gracefully on a missing cache file — but note it in the final report.

### Step 2 — Draft ALL posts in PARALLEL, then write + ClickUp

Because drafting now reads only the local `REF_CACHE` (no shared MCP), the draft agents are independent and **must be launched concurrently**.

**2a-0. Cross-source dedup gate (both contracts present).** Before fanning out, drop any FEED post that matches an inbox row in `keys.json` (`<inbox OUT_DIR>/keys.json`, a `[{key, fuzzy, url}]` array) on ANY of: `POST_<i>_KEY`, fuzzy identity (normalized author + first 160 chars of normalized body), or **normalized permalink** (`POST_<i>_URL`, query/trailing-slash stripped — catches the same post when its body was edited so key and fuzzy both differ). The inbox wins; note the skip in the report. The fast gather already dedups keys via `--extra-seen-file`, so this matters mainly on the legacy-fallback path and for the URL check — but always run it.

**2a. Fan out — spawn every draft agent in a single message.** For all feed posts plus every inbox post with `MODE=draft` or `MODE=reprocess-off-topic` (NOT `clickup-only`) at once, issue one message containing one `linkedin-comment-hourly-draft` Agent call per post (this runs them in parallel). Each call's prompt body:

```
POST_KEY=<synthetic key from the contract>
POST_URN=<urn or "-">
POST_AUTHOR_URL=<POST_<i>_AUTHOR_URL — author profile url or "-">
POST_AUTHOR=<author_name>
POST_HEADLINE=<author_headline>
POST_TEXT_FILE=<POST_<i>_TEXT_FILE — absolute path to the full post body>
REF_CACHE=<REF_CACHE from Step 1.5>
```

Collect all returns. A post whose draft agent returned `ERROR=<...>` is **not dropped**: it still gets its ledger entry and ClickUp task in Step 2b (with empty `variants` and `draft_error` naming the draft failure) — the post itself is a deliverable, and inbox posts would be permanently lost otherwise (the watermark advances past their message). Name every such post in the final report.

**2b. Write + ClickUp — sequentially, once all drafts are back.** Iterate ALL Step-2a posts plus the inbox `clickup-only` posts **one at a time** (the ClickUp calls and the `comments.json` read-modify-write must not interleave). Before the loop, fetch the ClickUp list's existing tasks ONCE (`mcp__claude_ai_ClickUP__listTasks` on `901524736848`, `includeClosed: true`, paginate while full pages return) — this is the search-first index for sub-step 2. For each post, in THIS order (ledger first, so a kill at any point leaves a durable record):

1. Decode each variant's `VARIANT_<i>_COMMENT_B64` (via `base64 -d` — never decode by hand). The entry is keyed by the synthetic key from the contract (`<author-slug>-<body-hash8>`), not the URN, because the home feed strips URNs. (`clickup-only` posts skip this — they have no new variants.)

2. **Ledger write.** For `MODE=reprocess-off-topic` / `clickup-only`, UPDATE the existing entry at `POST_<i>_MATCHED_KEY` in place (jq `(.[] | select(.key==$k)) |= …`); both set `source`/`slack_request_ts`/`slack_request_user`. **Reprocess additionally REPLACES the entry's identity with this contract row's**: `.key = POST_<i>_KEY`, `.post_text` = the contract's text file, `.post_url`/`.urn`/`.author_url` from the contract, `disposition = "drafted"`, `variants` filled — the old feed-scraped body often hashes to a DIFFERENT key than the post-page body, and every later step (the ClickUp footer, the comment markers, the driver's delivery gate) uses the NEW key, so leaving the old key in place would block the watermark. **Clickup-only** keeps the entry's key but backfills **every fresher contract field**: `.post_url`/`.urn`/`.author_url` when the entry's are null or point at a profile instead of the post, AND `.post_text`/`.author_name`/`.author_headline` whenever the contract row came from a fresh fetch (its text file differs from the entry's `post_text`) — a stale truncated legacy body would otherwise end up in the eventual ClickUp task and defeat future fuzzy dedup. Otherwise **append a `drafted` entry** to `./linkedin-compain/comments.json`. Build the object with `jq -n` (decode the base64 comments into `--arg` values so newlines/quotes are safe; read the post body with `--rawfile text "<POST_<i>_TEXT_FILE>"` — never paste it inline), then append with `jq '. + [$e]'` — same read-modify-write discipline the gather script uses. The entry shape:

   ```json
   {
     "key": "<POST_KEY>",
     "urn": "<urn or null>",
     "post_url": "<verified public permalink from POST_<i>_URL — always the /posts/<slug>/ form, or (rare) the lnkd.in short link; null only when POST_<i>_URL is '-'>",
     "author_url": "<author profile url — from POST_<i>_AUTHOR_URL, or null>",
     "author_name": "<name>",
     "author_headline": "<headline>",
     "time_ago": "<e.g. 2d or null>",
     "post_text": "<decoded text>",
     "scraped_at": "<ISO 8601 UTC now>",
     "disposition": "drafted",
     "reason": null,
     "variants": [
       { "strategy_label": "<label>", "comment": "<decoded comment>", "rationale": "<one line>" }
     ],
     "draft_error": null,
     "source": "<'feed' or 'slack-inbox' — POST_<i>_SOURCE, default feed>",
     "slack_request_ts": "<POST_<i>_SOURCE_TS for inbox posts, else null>",
     "slack_request_user": "<POST_<i>_SOURCE_USER for inbox posts, else null>",
     "clickup_task_id": null,
     "clickup_url": null,
     "clickup_adopted": null,
     "clickup_comment_ids": [],
     "clickup_comment_error": null,
     "clickup_error": null
   }
   ```

   Filtered entries the gather writes are a prefix of this shape — through `variants`, then nothing. They are seen-set only: no `source`, no delivery fields, because a filtered post never gets a task.

   **Retired fields.** Entries written before 2026-08-13 also carry `slack_summary` / `slack_ts` / `slack_thread` / `slack_error` from when the drafts were delivered as Slack threads. Never write them on a new entry and never edit them on an old one — they are historical record. Any read of the new fields must tolerate their absence on legacy entries (`.clickup_comment_ids? // []`, `.draft_error? // null`).

3. **ClickUp task — search-first create** (every post: feed and inbox, drafted or draft-failed). The task's *description* is the SOURCE POST; the drafts arrive separately as task comments in sub-step 4:
   - **Adopt, don't duplicate.** Identity checks, in order (a name match alone is NOT identity — two posts by one author can share an opening):
     1. A task in the pre-fetched index whose **Source custom field equals this post's `post_url`** (the index output shows custom fields) → adopt its id.
     2. For index candidates with a matching name but no Source value (the create-then-crash window): fetch the FULL description via the REST proxy — `mcp__claude_ai_ClickUP__mintRestBearerForCurl` then `curl -H "Authorization: Bearer <t>" <baseUrl>/clickup/tasks/<id>` — and adopt if it contains the line `key: <POST_KEY>`. (The MCP `getTask` output TRUNCATES descriptions and ClickUp strips markdown styling — grep the plain `key: …` line, never `_key: …_`, and never through the truncated MCP view; verified live 2026-07-25.)
   - If the index fetch or an identity check itself failed, **create nothing** — record `clickup_error: "identity check failed — deferred to reconciliation"` and move on (fail closed; never risk a duplicate behind a broken search).
   - **Create:** `mcp__claude_ai_ClickUP__createTask` with `listId: "901524736848"`, `name: "<author_name> — <first ~60 chars of the post body>"`, and `markdownContent`:

     ```
     **Author:** [<author_name>](<author_url>) — <author_headline>
     **Post:** <post_url, or "(no stable permalink)" when null>
     **Source:** <feed | Slack request by <slack_request_user> at <slack_request_ts>>
     **Scraped:** <scraped_at>

     ---

     <full post text verbatim>

     ---
     key: <POST_KEY>
     ```

     The `key:` footer (plain text — ClickUp strips markdown styling, so styled variants would be unfindable) is the task's durable identity — the create call itself must carry it (a later crash must not leave an identity-less task).
   - Then `mcp__claude_ai_ClickUP__setCustomFieldValue` field `3d8e441e-e225-4a1d-9601-5e4bf0cf7851` (Source) = `post_url` (best-effort — a failure here is not an error).
   - **Record the outcome** in the entry: `clickup_task_id` + `clickup_url` + `clickup_adopted` (`true` when you adopted an existing task, `false` when you created one) on success, `clickup_error` (one line) on failure — then continue with the next sub-step regardless. The driver's finish bookend counts created-vs-adopted off `clickup_adopted`, so set it on every success.

4. **Deliver the drafts as ClickUp task comments — one comment per variant.** This is the second delivery leg (it replaced the Slack thread on 2026-08-13), and the inbox watermark will not advance without it.

   Skip the whole sub-step when there is nothing to deliver: `variants` is empty (a draft-failed post — the task itself is still the deliverable), or sub-step 3 recorded a `clickup_error` and left `clickup_task_id` null (nothing to comment on; reconciliation retries the task, and a later fire delivers the comments).

   **Resume first, then post.** Comments are the leg most likely to be cut in half by a kill, so never post blind:
   - If `clickup_comment_ids` already has one id per variant → the leg is done, skip.
   - If the task was **adopted** (`clickup_adopted: true`) or the ids are partial → call `mcp__claude_ai_ClickUP__getTaskComments` ONCE for that task and adopt every comment whose text contains `draft <n> · key: <POST_KEY>`, recording its id. Post only the variants still missing.
   - A freshly created task (`clickup_adopted: false`) with no ids needs no read — nothing can be there yet.

   For each variant still owed, `mcp__claude_ai_ClickUP__addTaskComment` with `taskId: "<clickup_task_id>"`, `notifyAll: false` (2-3 notifications per task is noise), and `commentText`:

   ```
   **Draft <n> — <strategy_label>**

   <comment text — ready to paste, no truncation>

   _Rationale: <one line>_
   draft <n> · key: <POST_KEY>
   ```

   The final line is the **resume marker**. Keep it plain text: ClickUp strips markdown styling, so a styled marker would be unfindable on the next read — the same reason the description's `key:` footer is unstyled.

5. **Journal each comment id immediately** — update this post's entry in `comments.json` (match on `.key == "<POST_KEY>"`) after EACH `addTaskComment` call, never batched at the end of the post. A kill between calls must leave the ledger reflecting exactly what reached ClickUp, or the next fire re-posts comments that already landed:

   ```bash
   tmp=$(mktemp)
   jq --arg k "<POST_KEY>" --arg id "<comment id just returned>" \
      '(.[] | select(.key==$k)).clickup_comment_ids += [$id]' \
      ./linkedin-compain/comments.json > "$tmp" && mv "$tmp" ./linkedin-compain/comments.json
   ```

   On any failure in this sub-step: set the entry's `clickup_comment_error` to a one-line message (`(.[] | select(.key==$k)).clickup_comment_error=$msg`) and continue with the next post. A recorded error terminates the leg — it does not block the watermark, and the failure is named in the final report.

### Step 2c — ClickUp reconciliation (every fire; the whole job in RECONCILE-ONLY mode)

After the Step 2b loop (or as the only work when the driver's prompt says RECONCILE-ONLY): find ledger entries still owed their task —

```bash
jq '[.[] | select(.source != null and .disposition == "drafted" and .clickup_task_id == null)] | length' ./linkedin-compain/comments.json
```

Take up to **5**, oldest `scraped_at` first — but **skip any key you already attempted in this session's Step 2b loop**: its create outcome is ambiguous against the one-shot task index fetched before the loop (a create that succeeded with a lost response would be invisible), and re-creating against a stale index is how duplicates happen. Those keys reconcile on the NEXT fire, whose fresh index adopts them by key. When a create in this session confirmed an id, add that task to your in-memory index so later posts in the same loop see it. For each reconciled entry, run the same search-first create as Step 2b-3 (the entry has everything needed: author, urls, `post_text`, `key`) and update the entry. Entries with a `clickup_error` from a lost-response crash are exactly what the adopt-by-key path exists for.

### Step 3 — Emit the final report

```
### LinkedIn Comment Ideas — <ISO 8601 UTC now>
Posts drafted:            <n> / 5 feed + <m> inbox
Off-topic skipped:        <POSTS_OFF_TOPIC>
Already-commented skipped: <POSTS_ALREADY_COMMENTED>
Reposts skipped:          <POSTS_REPOSTS_SKIPPED>
Promoted skipped:         <POSTS_PROMOTED_SKIPPED>
Feed exhausted:           <FEED_EXHAUSTED>
Inbox posts processed:    <n> (<draft>/<reprocess>/<clickup-only>) — or "no inbox contract"
Draft-agent failures:     <n> (<keys>)
ClickUp tasks:            <created> created, <adopted> adopted, <failed> failed, <reconciled> reconciled
Draft comments posted:    <n> (<adopted> already present)
Draft-comment failures:   <n> (<keys>)
```

## What you must not do

- Do **not** open Playwright yourself — the fast script drives its own browser, and the fallback agent has its own tool allowlist. If the gather fails, do not fall back to a direct MCP scrape.
- Do **not** run the linkedin-comment-ideas skill directly for a post. Delegating to the draft agent keeps the reference reads out of your context.
- Do **not** run the draft agents sequentially — they read only the local `REF_CACHE` (no shared MCP), so launch them **all in one message** (Step 2a). Sequential drafting is the old, slow behavior.
- Do **not**, however, interleave the **ClickUp calls or the `comments.json` writes** — those stay strictly sequential (Step 2b) to avoid a read-modify-write race on the single file.
- Do **not** post anything to Slack. Not a per-post message, not a thread, not a summary — the channel receives only the 🟢/✅ bookends `run-hourly.sh` posts around you. (Until 2026-08-13 this skill posted one thread per post; that is gone, and the drafts ship as ClickUp task comments instead.)
- Do **not** skip Step 1.5 (prep-refs) — without the local cache, the draft agents have no reference material (they have no GDrive tools).
- Do **not** invent or edit either filter here. Topic tuning goes in `interests.md`; ICP tuning goes in `icp-filter.md` (or upstream in the ClickUp ICP Doc that `sync-sources` pulls into `sources/icp.md`). Inbox posts bypass **both** gates entirely — never re-filter a Peter-curated link.
- Do **not** treat a fire that accepted fewer than 5 feed posts as a failure. The ICP gate has no backfill; shipping 2 on-target tickets is the intended outcome, and padding the fire with off-ICP posts is exactly what this change removed.
- Do **not** put the comment variants in the task **description** — the description is the source post, and its plain `key:` footer is the task's identity. Drafts go in task **comments**, one per variant, each carrying its `draft <n> · key: <POST_KEY>` marker.
- Do **not** create a ClickUp task without the plain-text `key:` footer, and never create one when the search-first index could not be fetched (record `clickup_error` and let reconciliation retry).
- Do **not** post draft comments without checking for existing ones first when the task was adopted — a duplicate comment set on every re-drop is exactly what the marker prevents.
- Do **not** edit `./linkedin-compain/slack-inbox.json` — the driver owns the watermark; your ledger writes are what its postcondition checks.
- Do **not** perform any git operations — the shell driver `run-hourly.sh` handles branching, committing, and auto-merging. Interactive (non-cron) runs: remind the user at the end that the seen-set/state changes are uncommitted and the next scheduled fire will re-process them if not landed.
