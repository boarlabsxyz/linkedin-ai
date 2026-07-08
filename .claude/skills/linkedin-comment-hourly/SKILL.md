---
name: linkedin-comment-hourly
description: >
  Every 15 minutes: open Peter's LinkedIn home feed, scroll until 5 posts pass all
  filters (unseen, on-topic per interests.md, not already commented on, not a
  repost), draft 2-3 comment variants per post via the linkedin-comment-ideas
  skill (full pre-work checklist), save one JSON per post under
  ./linkedin-compain/comments/, and post one Slack message per post to channel
  C0BF606R4N7. Use when the user says "run linkedin comment hourly",
  "gather linkedin comment drafts", "draft comments for the feed", or when the
  slack-heartbeat cron fires.
---

# LinkedIn Comment Hourly

Thin orchestrator. Two sub-agents do the heavy work; this skill glues them and posts to Slack.

## Constants

| Resource | ID / Path |
|---|---|
| Output folder | `./linkedin-compain/comments/` |
| Interests file | `.claude/skills/linkedin-comment-hourly/interests.md` |
| Slack channel | `C0BF606R4N7` (https://spdfn.slack.com/archives/C0BF606R4N7) |
| Target posts per fire | `5` |

## Flow

### Step 1 — Gather 5 posts from the home feed

Spawn `linkedin-comment-hourly-gather-feed` via the Agent tool. Its prompt body:

```
SEEN_DIR=./linkedin-compain/comments/
TARGET_COUNT=5
MAX_SCROLL_ITERATIONS=80
INTERESTS_FILE=.claude/skills/linkedin-comment-hourly/interests.md
```

Parse the KEY=VALUE return. Expected keys: `POSTS_FOUND`, `POSTS_OFF_TOPIC`, `POSTS_ALREADY_COMMENTED`, `POSTS_REPOSTS_SKIPPED`, `POSTS_PROMOTED_SKIPPED`, `SCROLL_ITERATIONS`, `FEED_EXHAUSTED`, and `POST_<i>_KEY`, `POST_<i>_URN`, `POST_<i>_URL`, `POST_<i>_AUTHOR`, `POST_<i>_HEADLINE`, `POST_<i>_TIME_AGO`, `POST_<i>_TEXT_B64` for i = 1..`POSTS_FOUND`. `POST_<i>_URN` is `-` when not extractable (LinkedIn strips URNs from the home feed DOM as of 2026-07); `POST_<i>_KEY` is the synthetic `<author-slug>-<body-hash8>` identifier used as filename stem.

If `POSTS_FOUND=0` (or the agent returns `ERROR=<...>`), emit the failure line, do NOT spawn Step 2, and stop. The shell driver's `git diff --quiet` check skips the commit.

### Step 2 — Draft + save + Slack, one post at a time

For each of the `POSTS_FOUND` posts, **sequentially** (never in parallel — GDrive MCP is shared):

1. Spawn `linkedin-comment-hourly-draft` via the Agent tool. Its prompt body:

   ```
   POST_KEY=<synthetic key from Agent 1>
   POST_URN=<urn or "-">
   POST_URL=<author profile url or "-">
   POST_AUTHOR=<author_name>
   POST_HEADLINE=<author_headline>
   POST_TEXT_B64=<base64 post text>
   ```

   Parse the KEY=VALUE return. If `ERROR=<...>`, skip this post (log the failure inline) and continue with the next.

2. Decode each variant's `VARIANT_<i>_COMMENT_B64`. The output filename uses the synthetic key from Agent 1 (`<author-slug>-<body-hash8>`), not the URN, because the home feed strips URNs.

3. Write `./linkedin-compain/comments/<POST_KEY>.json`:

   ```json
   {
     "key": "<POST_KEY>",
     "urn": "<urn or null>",
     "post_url": "<url or null>",
     "author_name": "<name>",
     "author_headline": "<headline>",
     "post_text": "<decoded text>",
     "scraped_at": "<ISO 8601 UTC now>",
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

5. Capture each reply's `ts` and record them all in the JSON file:

   ```json
   {
     ...,
     "slack_ts": "<parent_ts>",
     "slack_thread": {
       "post_reply_ts": "<ts of 4b>",
       "draft_reply_ts": ["<ts of first draft>", "<ts of second draft>", ...]
     },
     "slack_error": null
   }
   ```

   On any failure: patch the JSON file — set `slack_error` to a one-line message. Continue with the next post.

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
- Do **not** run the linkedin-comment-ideas skill directly for a post. Delegating to Agent 2 keeps the ~4 GDrive reads per post out of your context.
- Do **not** parallelize drafting across posts. GDrive MCP is a shared resource.
- Do **not** invent or edit the interest filter here. If the filter needs tuning, edit `interests.md`.
- Do **not** perform any git operations — the shell driver `run-hourly.sh` handles branching, committing, and auto-merging.
