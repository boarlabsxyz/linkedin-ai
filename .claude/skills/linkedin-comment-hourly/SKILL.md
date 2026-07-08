---
name: linkedin-comment-hourly
description: >
  Every 15 minutes: open Peter's LinkedIn home feed, scroll until 5 posts pass all
  filters (unseen, on-topic per interests.md, not already commented on, not a
  repost), draft 2-3 comment variants per post via the linkedin-comment-ideas
  skill (full pre-work checklist), append one entry per post to the single
  ./linkedin-compain/comments.json array, and post one Slack message per post to
  channel C0BF606R4N7. Use when the user says "run linkedin comment hourly",
  "gather linkedin comment drafts", "draft comments for the feed", or when the
  slack-heartbeat cron fires.
---

# LinkedIn Comment Hourly

Thin orchestrator. Three sub-agents do the heavy work — `gather-feed` (scrape + classify), `prep-refs` (refresh the local reference cache once), and `draft` (fan out in parallel, one per post) — this skill glues them and posts to Slack.

## Constants

| Resource | ID / Path |
|---|---|
| Comments file | `./linkedin-compain/comments.json` (single JSON array — every post, drafted or filtered, is one object) |
| Interests file | `.claude/skills/linkedin-comment-hourly/interests.md` |
| Reference cache | `$HOME/.cache/linkedin-ai-refs` (local mirror of ICP / True BDD / Posted / Transcripts; **outside the worktree** so `git clean -fd` can't wipe it) |
| Slack channel | `C0BF606R4N7` (https://spdfn.slack.com/archives/C0BF606R4N7) |
| Target posts per fire | `5` |

`comments.json` is the single source of truth **and** the cross-fire seen-set. Each element is one post: drafted posts carry `variants` + Slack timestamps; filtered posts (`off-topic` / `already-commented`) carry a `reason` and empty `variants`. Agent 1 appends the filtered entries; you (the orchestrator) append the drafted ones. Never hand-write JSON — always mutate the array with `jq`.

## Flow

### Step 1 — Gather 5 posts from the home feed

Spawn `linkedin-comment-hourly-gather-feed` via the Agent tool. Its prompt body:

```
COMMENTS_FILE=./linkedin-compain/comments.json
TARGET_COUNT=5
MAX_SCROLL_ITERATIONS=80
INTERESTS_FILE=.claude/skills/linkedin-comment-hourly/interests.md
```

Parse the KEY=VALUE return. Expected keys: `POSTS_FOUND`, `POSTS_OFF_TOPIC`, `POSTS_ALREADY_COMMENTED`, `POSTS_REPOSTS_SKIPPED`, `POSTS_PROMOTED_SKIPPED`, `SCROLL_ITERATIONS`, `FEED_EXHAUSTED`, and `POST_<i>_KEY`, `POST_<i>_URN`, `POST_<i>_URL`, `POST_<i>_AUTHOR`, `POST_<i>_HEADLINE`, `POST_<i>_TIME_AGO`, `POST_<i>_TEXT_B64` for i = 1..`POSTS_FOUND`. `POST_<i>_URN` is `-` when not extractable (LinkedIn strips URNs from the home feed DOM as of 2026-07); `POST_<i>_KEY` is the synthetic `<author-slug>-<body-hash8>` identifier. Agent 1 has already appended the off-topic / already-commented posts to `comments.json`; the `POST_<i>_*` entries it returns are the relevant ones still needing drafts.

If `POSTS_FOUND=0` (or the agent returns `ERROR=<...>`), emit the failure line, do NOT spawn Step 1.5 / Step 2, and stop. The shell driver's `git diff --quiet` check skips the commit.

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

### Step 2 — Draft ALL posts in PARALLEL, then write + Slack

Because drafting now reads only the local `REF_CACHE` (no shared MCP), the draft agents are independent and **must be launched concurrently**.

**2a. Fan out — spawn every draft agent in a single message.** For all `POSTS_FOUND` posts at once, issue one message containing one `linkedin-comment-hourly-draft` Agent call per post (this runs them in parallel). Each call's prompt body:

```
POST_KEY=<synthetic key from Agent 1>
POST_URN=<urn or "-">
POST_URL=<author profile url or "-">
POST_AUTHOR=<author_name>
POST_HEADLINE=<author_headline>
POST_TEXT_B64=<base64 post text>
REF_CACHE=<REF_CACHE from Step 1.5>
```

Collect all returns. For any that returned `ERROR=<...>`, drop that post (note it in the report) and keep the rest.

**2b. Write + Slack — sequentially, once all drafts are back.** Iterate the successful results **one at a time** (Slack posting and the `comments.json` read-modify-write must not interleave). For each post:

1. Decode each variant's `VARIANT_<i>_COMMENT_B64` (via `base64 -d` — never decode by hand). The entry is keyed by the synthetic key from Agent 1 (`<author-slug>-<body-hash8>`), not the URN, because the home feed strips URNs.

2. **Append a `drafted` entry** to `./linkedin-compain/comments.json`. Build the object with `jq -n` (decode the base64 comments into `--arg` values so newlines/quotes are safe), then append with `jq '. + [$e]'` — same read-modify-write discipline Agent 1 uses. The entry shape:

   ```json
   {
     "key": "<POST_KEY>",
     "urn": "<urn or null>",
     "post_url": "<url or null>",
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
     "slack_summary": null,
     "slack_ts": null,
     "slack_thread": {
       "post_reply_ts": null,
       "draft_reply_ts": []
     },
     "slack_error": null
   }
   ```

   The `drafted` entry shares the exact field set as Agent 1's filtered entries — only `disposition`, `reason`, and `variants` differ — so the array stays uniform.

4. **Post a compact summary to the main channel**, then thread the details underneath. First compose a one-line summary of the post yourself (what is this post about? — ≤150 chars, plain English, no marketing words). Then:

   **4a. Main-channel message** — `mcp__claude_ai_Slack__postMessage` with `channel_id=C0BF606R4N7`, body:

   ```
   📌 *<author_name>* — <author_headline>
   _<one-line summary of the post>_
   ```

   Capture the returned `ts` — call it `parent_ts`. Store it in the JSON as `slack_ts`.

   **4b. Thread reply — the post itself** — `mcp__claude_ai_Slack__replyInThread` (or `postMessage` with `thread_ts=parent_ts`) with body:

   ```
   🔗 <post_url or author_profile_url>

   > <full post_text — no truncation; wrap in a quote block>
   ```

   **4c. Thread reply — one message per draft** — for each variant, post a separate thread reply:

   ```
   *Draft <i> — <strategy_label>*
   <comment text>
   _Rationale: <one line>_
   ```

5. Capture each reply's `ts` and record them by **updating this post's entry in `comments.json`** (match on `.key == "<POST_KEY>"`), e.g.:

   ```bash
   tmp=$(mktemp)
   jq --arg k "<POST_KEY>" --arg summary "<one-line summary>" \
      --arg ts "<parent_ts>" --arg pr "<ts of 4b>" \
      --argjson drafts '["<ts draft1>","<ts draft2>", ...]' \
      '(.[] | select(.key==$k)) |= (.slack_summary=$summary | .slack_ts=$ts
         | .slack_thread.post_reply_ts=$pr | .slack_thread.draft_reply_ts=$drafts)' \
      ./linkedin-compain/comments.json > "$tmp" && mv "$tmp" ./linkedin-compain/comments.json
   ```

   On any failure: update the same entry's `slack_error` to a one-line message (`(.[] | select(.key==$k)).slack_error=$msg`). Continue with the next post.

### Step 3 — Emit the final report

```
### LinkedIn Comment Ideas — <ISO 8601 UTC now>
Posts drafted:            <n> / 5
Off-topic skipped:        <POSTS_OFF_TOPIC>
Already-commented skipped: <POSTS_ALREADY_COMMENTED>
Reposts skipped:          <POSTS_REPOSTS_SKIPPED>
Promoted skipped:         <POSTS_PROMOTED_SKIPPED>
Feed exhausted:           <FEED_EXHAUSTED>
Slack messages posted:    <n>
Slack failures:           <n>
```

## What you must not do

- Do **not** open Playwright yourself — that lives inside Agent 1's tool allowlist. If Agent 1 fails, do not fall back to a direct scrape.
- Do **not** run the linkedin-comment-ideas skill directly for a post. Delegating to the draft agent keeps the reference reads out of your context.
- Do **not** run the draft agents sequentially — they read only the local `REF_CACHE` (no shared MCP), so launch them **all in one message** (Step 2a). Sequential drafting is the old, slow behavior.
- Do **not**, however, interleave the **Slack posts or the `comments.json` writes** — those stay strictly sequential (Step 2b) to avoid a read-modify-write race on the single file.
- Do **not** skip Step 1.5 (prep-refs) — without the local cache, the draft agents have no reference material (they have no GDrive tools).
- Do **not** invent or edit the interest filter here. If the filter needs tuning, edit `interests.md`.
- Do **not** perform any git operations — the shell driver `run-hourly.sh` handles branching, committing, and auto-merging.
