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
4. Compute the three `_MS` inputs and spawn the `linkedin-stats-gather-comments-out` agent. It scrolls Peter's `/recent-activity/comments/` page, harvests every Peter-authored comment going back to `DISCOVERY_CUTOFF_MS`, and merges them into `./dashboards/li-stats/comments.json` keyed by comment URN. Each comment carries static metadata plus a `weeks[WEEK]` snapshot of public reactions + replies — but only if the comment is younger than 30 days at WEEK midnight UTC.
   ```bash
   WEEK=$(date -u -v-Mon "+%Y-%m-%d" 2>/dev/null || date -u -d "last monday" "+%Y-%m-%d")
   WEEK_MIDNIGHT_MS=$(python3 -c 'import datetime,sys; w=sys.argv[1]; d=datetime.datetime.strptime(w,"%Y-%m-%d").replace(tzinfo=datetime.timezone.utc); print(int(d.timestamp()*1000))' "$WEEK")
   DISCOVERY_CUTOFF_MS=$(python3 - "$WEEK_MIDNIGHT_MS" <<'PY'
import datetime, glob, json, sys
fallback = int(sys.argv[1])
oldest_ms = None
for path in glob.glob("./dashboards/li-stats/posts/*.json"):
    try:
        with open(path) as f:
            posted = json.load(f).get("posted_date")
    except Exception:
        continue
    if not posted:
        continue
    try:
        d = datetime.datetime.strptime(posted, "%Y-%m-%d").replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        continue
    ms = int(d.timestamp() * 1000)
    if oldest_ms is None or ms < oldest_ms:
        oldest_ms = ms
print(oldest_ms if oldest_ms is not None else fallback)
PY
)
   RECENT_FLOOR_MS=$(python3 - "$DISCOVERY_CUTOFF_MS" <<'PY'
import datetime, json, os, sys
fallback = int(sys.argv[1])
path = "./dashboards/li-stats/comments.json"
if not os.path.exists(path):
    print(fallback); sys.exit(0)
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    print(fallback); sys.exit(0)
comments = data.get("comments", {}) if isinstance(data, dict) else {}
newest = None
for entry in comments.values():
    iso = entry.get("commented_at") if isinstance(entry, dict) else None
    if not iso:
        continue
    try:
        d = datetime.datetime.strptime(iso.replace("Z","+0000"), "%Y-%m-%dT%H:%M:%S%z")
    except ValueError:
        continue
    ms = int(d.timestamp() * 1000)
    if newest is None or ms > newest:
        newest = ms
print((newest - 86400000) if newest is not None else fallback)
PY
)
   SNAPSHOT_CUTOFF_MS=$((WEEK_MIDNIGHT_MS - 30 * 86400 * 1000))
   ```
   The agent's prompt body must contain exactly these four lines:
   ```
   WEEK=<WEEK>
   DISCOVERY_CUTOFF_MS=<DISCOVERY_CUTOFF_MS>
   RECENT_FLOOR_MS=<RECENT_FLOOR_MS>
   SNAPSHOT_CUTOFF_MS=<SNAPSHOT_CUTOFF_MS>
   ```
5. Print a final report combining all four agents' KEY=VALUE contracts. Format:
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

   Gather outbound comments
   - Week:               <WEEK>
   - Discovered:         <COMMENTS_DISCOVERED>
   - New:                <COMMENTS_NEW>
   - Snapshotted:        <COMMENTS_SNAPSHOTTED>
   - Discovery cutoff:   <DISCOVERY_CUTOFF>
   - Oldest visible:     <OLDEST_VISIBLE>
   - Scroll iterations:  <SCROLL_ITERATIONS>
   ```
   Steps run sequentially. If step 1 or step 3's agent returns `ERROR=<...>`, include the error line verbatim and stop without spawning subsequent steps. If step 4's agent returns `ERROR=<...>`, include it verbatim in the report — the snapshot from step 3 is already persisted, so don't roll anything back. Per-post `ERROR=` returns inside step 2 are aggregated into `POSTS_FAILED` / `FAILED_IDS` and do NOT abort the skill.
