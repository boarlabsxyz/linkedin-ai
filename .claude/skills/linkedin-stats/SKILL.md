---
name: linkedin-stats
description: >
  Gather LinkedIn post links and per-post weekly analytics into local JSON
  files under ./dashboards/li-stats/. Use when the user says "gather linkedin
  stats", "update linkedin statistics", "refresh post analytics", "snapshot
  linkedin posts", or "linkedin weekly stats".
---

# LinkedIn Stats

## Step 0 — fast path (always try this first)

Run the deterministic scraper. It performs ALL five gather steps (post
discovery, per-post metrics, account analytics, outbound comments, and the
`people` engagement phase) in one paced Playwright process over the same
logged-in Chrome profile the MCP uses (~5 min total), and prints the same
KEY=VALUE contracts the agents would, sectioned as `[posts]` / `[metrics]` /
`[account]` / `[comments]` / `[people]` / `[selfcheck]`:

```bash
node .claude/skills/linkedin-stats/fast/scrape-weekly.mjs
```

Notes:
- If `.claude/skills/linkedin-stats/fast/node_modules` is missing, first run
  `(cd .claude/skills/linkedin-stats/fast && npm install --no-audit --silent)`.
- Use a 600000ms Bash timeout (the run needs ~4-5 min).
- The script must own the Chrome profile. If the Playwright MCP browser is
  open in this session, it exits 21 (`ERROR=PROFILE_LOCKED`) — close the MCP
  browser tab-set first, or fall back to the agent flow below.

Exit code decides what happens next:
- **0 or 10** — success (10 = some per-post failures, listed in `FAILED_IDS`).
  Build the final report (step 5 format) from the printed contract sections.
  Do NOT spawn any agents.
- **30** — selector/compat failure (LinkedIn DOM drifted beyond the fast
  parsers; the canary post failed). Fall back to the agent flow (steps 1-4
  below), which improvises selectors per run.
- **21** — profile locked (MCP browser or another job owns Chrome). Either
  close the other browser and re-run, or use the agent flow.
- **20 / 22 / 23** — auth wall / rate-limited / fs failure. Report the error
  verbatim and stop — the agent flow would hit the same wall.

## Step 0.5 — zero-signal self-check (do NOT skip on a green run)

On exit 0 or 10, read `[selfcheck] ZERO_SIGNALS` and `ANOMALY_SIGNALS`. If
either is anything other than `-`, **the run is not reported as clean until you
have looked**.

Four counters are watched — zero new posts (`POSTS_NEW`), zero new outbound
comments (`COMMENTS_NEW`), zero reactors (`REACTORS_SEEN`), zero commenters
(`COMMENTS_SCRAPED_TOTAL`). A zero is the one shape a scraper produces just as
happily when it is broken as when the week was quiet: on 2026-08-17 the per-post
comment scrape returned empty for all 50 posts — 85 comments the week before —
and the run exited 0, auto-merged and published.

`ANOMALY_SIGNALS` is the mirror image: a non-zero counter that should be zero.
Today that is `roster_unresolved` — an engager LinkedIn displayed that the
parser could not turn into a profile link.

Follow `references/zero-revalidation.md` in this session. Each probe is one
`browser_navigate` + one `browser_evaluate` via the Playwright MCP, so the whole
check is ~4 navigations. State a verdict per signal, and obey the same honesty
rule the headless session gets: **a confirmed-real zero is a result, reported as
real — never edit code to make a real zero non-zero.**

In CI this runs automatically: `run-weekly.sh` dispatches a bounded session
before the merge decision, and a zero that is not confirmed real leaves the PR
open instead of publishing.

## The `people` phase — WHO engaged, and what it scores

Everything else in this skill counts engagement; this phase records the people
behind it and tiers them, so the dashboard can show a weighted engagement
score. It runs last, alone, on its own page, and writes
`dashboards/li-stats/engagement.json` (`{people, events, targets}`) through
`fast/merge.py` like every other li-stats file.

**Dating.** LinkedIn timestamps comments but NOT reactions:
- a comment carries its own URN, which decodes to an exact UTC ms, so comment
  and reply events are dated exactly and retroactively;
- a reaction carries nothing, so it is dated by DIFFING this week's reactor set
  against the set already recorded for that target. The first scan of a target
  is therefore a **baseline**: its reactors are stored with `backfill: true`
  and excluded from weekly scores. Real weekly reaction numbers start with the
  **second** weekly run. Reactions are attributed to `ATTRIBUTED_WEEK` — the
  ISO Monday *before* the run, i.e. the week that just ended.

**Scope per run** (bounded so this never eats the analytics 429 budget): posts
published in the last 30 days, posts whose reaction/comment counts changed
since the previous snapshot, plus never-scanned posts as baseline backlog —
capped by `--people-max-posts` (25); and Peter's own comments younger than 30
days, capped by `--people-max-comments` (25). Anything dropped by a cap is
reported in `TARGETS_DROPPED`, never silently skipped.

**Per-week rosters.** Counts alone do not say WHO, so each week snapshot also
carries the engagers themselves — on every post file and on every
`comments.json` entry:

```json
"2026-08-17": {
  "snapshot_at": "…", "metrics": {…}, "demographics": {…}, "comments": [ … ],
  "reactors":   ["https://www.linkedin.com/in/a", …],
  "commenters": ["https://www.linkedin.com/in/c", …]
}
```

Canonical profile URLs, deduped and sorted; each resolves to a file under
`dashboards/profiles/`. On an outbound comment, `commenters` means the people
who **replied** to it. Three rules:
- **`null` = not measured, `[]` = measured and nobody.** The phase harvests
  commenters for every post but opens the reaction overlay only for its
  selected targets, so most posts get `commenters: […], reactors: null`.
- **A person who cannot be given a URL breaks the run** — there is no "and N
  others we could not name" counter (Peter, 2026-08-19: "let's just drop them.
  if face such stuff, just break pipeline and fix during self-improving
  stuff"). A roster is a list of profile links; carrying a hole-count next to
  it forever just normalizes the hole. `ROSTER_UNRESOLVED > 0` raises the
  `roster_unresolved` anomaly, which blocks the merge and goes to the
  revalidation session. Expected to be 0 always — private "LinkedIn Member"
  profiles render no anchor at all, so they never reach the parser (12 of 12
  resolved on the first real corpus) — which is why a non-zero reads as "a
  parser stopped finding links", not "someone was shy".
- **Union, never overwrite** — a partial re-read of a lazily-paged dialog must
  not shrink a good list, the same reason events are append-only.

Written by `merge.py`'s `week_people` mode as a read-modify-write (the metrics
phase writes `weeks[WEEK]` before this phase runs). A target with no
`weeks[WEEK]` gets one created carrying `people_only: true` and NO `metrics`
— `build-stats-json.mjs` skips metrics-less entries so they never become a
fabricated all-zero week in Grafana. While on the post page for the reaction
overlay, the phase also scrapes the top-level commenters itself, at zero extra
navigations: that decouples the roster from the metrics phase, which returned
zero comments for all 50 posts on 2026-08-17.

**Profiles.** Every person the phase sees gets one file under
`dashboards/profiles/` (`pipeline-shared/profile-store.mjs`) — name, headline,
profile link, first-seen and last-updated dates — SHARED with
linkedin-comment-hourly. **This phase never opens a profile page** (Peter,
2026-08-19); it records only what the reaction overlay and comment cards hand
it. The store drops a write whose record is unchanged, so re-seeing the same
people cannot churn git.

**Tiering.** `sources/icp.md` (synced from the ClickUp ICP Doc by the
`sync-sources` skill) is the rubric; `fast/classify-icp.mjs` classifies each
person once from their name + headline via a batched, tool-free pinned-haiku
`claude -p` call and caches the verdict in that person's profile file, stamped
with the rubric hash it was reached under.
`.claude/skills/linkedin-stats/vip-people.md` is the hand-curated 4× list.
Weights live in `.claude/skills/linkedin-stats/scoring.json`. **Scores are
computed at build time** by `.github/scripts/build-stats-json.mjs`, never
stored — so retuning a weight, adding a VIP, or a late ICP verdict rescores
all history with no re-scrape.

**Contract keys:** `PEOPLE_STATUS` (OK / PARTIAL / SELECTOR_DRIFT / FAILED /
AUTH / RATE / DEADLINE), `WEEK`, `ATTRIBUTED_WEEK`, `POST_TARGETS`,
`POST_TARGETS_SCANNED`, `COMMENT_TARGETS_SCANNED`, `TARGETS_FAILED`,
`TARGETS_DROPPED`, `REACTORS_SEEN`, `REACTORS_EXPECTED`, `TARGETS_SHORT_READ`,
`COMMENT_EVENTS`, `REPLY_EVENTS`, `COMMENTS_UNDATED`, `COMMENTERS_RECOVERED`,
`PEOPLE_NEW`, `EVENTS_NEW`, `PROFILES_WRITTEN`, `ROSTER_POSTS`,
`ROSTER_COMMENTS`, `ROSTER_WEEKS_CREATED`, `ROSTER_MISSING`, `REACTOR_URLS`,
`COMMENTER_URLS`, `ROSTER_UNRESOLVED`, `REPLIES_UNMEASURED`, `ICP_PENDING`,
`ICP_CLASSIFIED`, `ICP_UNCLASSIFIED`.

**This phase is ADVISORY on purpose.** It never emits a phase-level `ERROR=`
line and never escalates the exit code past `partial` (10), so a drifted
reactor overlay cannot demote a run whose metrics and account data are good,
nor block the Pages publish. Its health shows up in `PEOPLE_STATUS` and in the
run manifest. Promote it to a hard canary only once it has proven itself over
several fires. One exception is already provable rather than advisory:
`REACTORS_SEEN=0` while `REACTORS_EXPECTED>0` means the dialog told us the
count and we read nobody — that sets `SELECTOR_DRIFT` and rides the normal
exit-10 heal path.

Flags: `--no-icp` (skip classification), `--icp-max=<n>` (cap classifications
per run, default 200), `--people-recent-days=<n>`, `--people-recent-only`
(drop the never-scanned backlog and scan only the recency window — what the
roster backfill uses), `--profiles-dir=<dir>`.

Regression suites (browser-free):
```bash
node .claude/skills/linkedin-stats/fast/test-people.mjs
node .claude/skills/linkedin-stats/fast/test-week-people.mjs
node .claude/skills/pipeline-shared/test-profile-store.mjs
```

**Known DOM facts (verified live 2026-08-17)** — LinkedIn's 2026 obfuscation
reached the post page, so these are the only handles that work:
- the reactor overlay is a native `<dialog data-testid="dialog">`, NOT
  `[role="dialog"]` and NOT `.artdeco-modal`;
- the counts row has no semantic class and no aria-label — the reaction list is
  opened by clicking the anchor whose text reads `"<n> reactions <n>"`;
- the overlay lazy-loads ~10 people per page and responds to REAL input events,
  not `scrollTop` (measured: scrollTop 10→19, mouse wheel →58, End key →68 of
  70), so paging is driven from node with `mouse.wheel` + `End`;
- a couple of reactors are private profiles with no link and can never be
  identified — a shortfall under 10% of `REACTORS_EXPECTED` is treated as
  normal, anything larger sets `TARGETS_SHORT_READ`.

## Agent flow (fallback only)

1. Spawn the `linkedin-stats-gather-posts` agent via the Agent tool. It scrolls Peter's recent-activity feed, decodes URN timestamps, and creates one file per post under `./dashboards/li-stats/posts/<YYYY-MM-DD>-<slug>.json` with `text: null` and an empty `weeks: {}` map. The metrics agent (step 2) backfills `text` — the full post body scraped from the public post page — on its next pass over any file where it's still null.
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

   Engagement people (fast path only — no agent fallback exists)
   - Status:            <PEOPLE_STATUS>
   - Attributed week:   <ATTRIBUTED_WEEK>
   - Targets scanned:   <POST_TARGETS_SCANNED> posts / <COMMENT_TARGETS_SCANNED> comments
   - Reactors:          <REACTORS_SEEN> of <REACTORS_EXPECTED>
   - New events:        <EVENTS_NEW> (comments <COMMENT_EVENTS>, replies <REPLY_EVENTS>)
   - Undated comments:  <COMMENTS_UNDATED>
   - Rosters written:   <ROSTER_POSTS> posts / <ROSTER_COMMENTS> comments
                        (<REACTOR_URLS> reactor + <COMMENTER_URLS> commenter urls)
   - Profiles written:  <PROFILES_WRITTEN>
   - ICP classified:    <ICP_CLASSIFIED> (pending <ICP_PENDING>)

   Selfcheck
   - Zero signals:    <ZERO_SIGNALS>
   - Anomaly signals: <ANOMALY_SIGNALS>
   - Verdict:         <per signal: confirmed real — evidence | BUG — what is broken>
   ```
   The `people` phase exists **only** on the fast path: there is no fifth
   gather agent, because the CI pipeline self-heals rather than falling back,
   and the phase is advisory (a failure there never blocks the run). On the
   agent flow, report `[people] SKIPPED=agent_flow`.

   The agent flow has no `[selfcheck]` section — compute the same four numbers
   from the step aggregates (`POSTS_NEW`, `COMMENTS_NEW`,
   `COMMENTS_SCRAPED_TOTAL`; `REACTORS_SEEN` is fast-path only) and apply
   step 0.5 to them.

   Steps run sequentially. If step 1 or step 3's agent returns `ERROR=<...>`, include the error line verbatim and stop without spawning subsequent steps. If step 4's agent returns `ERROR=<...>`, include it verbatim in the report — the snapshot from step 3 is already persisted, so don't roll anything back. Per-post `ERROR=` returns inside step 2 are aggregated into `POSTS_FAILED` / `FAILED_IDS` and do NOT abort the skill.
