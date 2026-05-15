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
3. Print a final report combining both agents' KEY=VALUE contracts. Format:
   ```
   ### LinkedIn Stats — <YYYY-MM-DD>

   Gather posts
   - Discovered: <POSTS_DISCOVERED>
   - New:        <POSTS_NEW>
   - Cutoff:     <CUTOFF>
   - Oldest new: <OLDEST_NEW>
   - Newest new: <NEWEST_NEW>

   Gather metrics
   - Week:       <WEEK>
   - Measured:   <POSTS_MEASURED>
   - Failed:     <POSTS_FAILED>
   - Failed ids: <FAILED_IDS>
   ```
   If either agent returns `ERROR=<...>`, include the error line verbatim and stop without spawning the next step.
