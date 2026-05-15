---
name: linkedin-stats
description: >
  Gather LinkedIn post links and per-post weekly analytics into local JSON
  files under ./tmp/li-stats/. Use when the user says "gather linkedin
  stats", "update linkedin statistics", "refresh post analytics", "snapshot
  linkedin posts", or "linkedin weekly stats".
---

# LinkedIn Stats

1. Spawn the `linkedin-stats-gather-posts` agent via the Agent tool. It scrolls Peter's recent-activity feed, decodes URN timestamps, and creates one file per post under `./tmp/li-stats/posts/<YYYY-MM-DD>-<slug>.json` with an empty `weeks: {}` map.
2. Spawn the `linkedin-stats-gather-metrics` agent via the Agent tool. It opens the post-summary + demographic-detail analytics pages for every post file and adds the current ISO-week's snapshot under that post's `weeks` map.
3. Spawn the `linkedin-stats-gather-account` agent via the Agent tool. It opens Peter's dashboard + four creator-analytics pages (content / audience / search-appearances / profile-views) and appends a week-keyed snapshot to `./tmp/li-stats/account.json`.
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
   - Week:       <WEEK>
   - Measured:   <POSTS_MEASURED>
   - Failed:     <POSTS_FAILED>
   - Skipped:    <POSTS_SKIPPED>
   - Failed ids: <FAILED_IDS>

   Gather account
   - Week:                  <WEEK>
   - Followers:             <FOLLOWERS>
   - Post impressions 7d:   <POST_IMPRESSIONS_7D>
   - Profile viewers 90d:   <PROFILE_VIEWERS_90D>
   - Search appearances 7d: <SEARCH_APPEARANCES_7D>
   - Pages failed:          <PAGES_FAILED>
   ```
   Steps run sequentially. If any agent returns `ERROR=<...>`, include the error line verbatim and stop without spawning the next step.
