---
name: linkedin-stats
description: >
  Gather LinkedIn post links and per-post weekly analytics into local JSON
  files under ./dashboards/li-stats/. Use when the user says "gather linkedin
  stats", "update linkedin statistics", "refresh post analytics", "snapshot
  linkedin posts", or "linkedin weekly stats".
---

# LinkedIn Stats

1. Spawn the `linkedin-stats-gather-posts` agent via the Agent tool. It scrolls Peter's recent-activity feed, decodes URN timestamps, and creates one file per post under `./dashboards/li-stats/posts/<YYYY-MM-DD>-<slug>.json` with an empty `weeks: {}` map.
2. Compute the week key once:
   ```bash
   WEEK=$(date -u -v-Mon "+%Y-%m-%d" 2>/dev/null || date -u -d "last monday" "+%Y-%m-%d")
   ```
   List `./dashboards/li-stats/posts/*.json` (sorted, oldest first). Initialize counters `measured=0 failed=0 skipped=0 failed_ids=[] comments_scraped_total=0`.

   For each post file, spawn the `linkedin-stats-gather-metrics` agent via the Agent tool, sequentially (one at a time — parallel browser access across sub-agents is not safe with the shared Playwright MCP). The agent's prompt body must contain exactly:
   ```
   POST_FILE=<path>
   WEEK=<WEEK>
   ```

   Parse the agent's KEY=VALUE return and aggregate:
   - `STATUS=OK`              → `measured++`, add `COMMENTS_SCRAPED` to `comments_scraped_total`
   - `STATUS=SKIPPED_REPOST`  → `skipped++`
   - `STATUS=FAIL`            → `failed++`, append `POST_ID` to `failed_ids`
   - `ERROR=...`              → `failed++`, append filename stem to `failed_ids`. Do NOT abort the skill — the next post is independent.

   After all posts complete, the final report uses these aggregates as `POSTS_MEASURED`, `POSTS_FAILED`, `POSTS_SKIPPED`, `FAILED_IDS` (comma-joined, or `-` if empty), and `COMMENTS_SCRAPED_TOTAL`.
3. Spawn the `linkedin-stats-gather-account` agent via the Agent tool. It opens Peter's dashboard + four creator-analytics pages (content / audience / search-appearances / profile-views) and appends a week-keyed snapshot to `./dashboards/li-stats/account.json`.
4. Print a final report combining all three agents' KEY=VALUE contracts. Format:
   ```
   ### LinkedIn Stats — <YYYY-MM-DD>

   Gather posts
   - Discovered: <POSTS_DISCOVERED>
   - New:        <POSTS_NEW>
   - Cutoff:     <CUTOFF>
   - Oldest new: <OLDEST_NEW>
   - Newest new: <NEWEST_NEW>

   Gather post metrics
   - Week:             <WEEK>
   - Measured:         <POSTS_MEASURED>
   - Failed:           <POSTS_FAILED>
   - Skipped:          <POSTS_SKIPPED>
   - Failed ids:       <FAILED_IDS>
   - Comments scraped: <COMMENTS_SCRAPED_TOTAL>

   Gather account
   - Week:                  <WEEK>
   - Followers:             <FOLLOWERS>
   - Post impressions 7d:   <POST_IMPRESSIONS_7D>
   - Profile viewers 90d:   <PROFILE_VIEWERS_90D>
   - Search appearances 7d: <SEARCH_APPEARANCES_7D>
   - Pages failed:          <PAGES_FAILED>
   ```
   Steps run sequentially. If step 1 or step 3's agent returns `ERROR=<...>`, include the error line verbatim and stop without spawning subsequent steps. Per-post `ERROR=` returns inside step 2 are aggregated into `POSTS_FAILED` / `FAILED_IDS` and do NOT abort the skill.
