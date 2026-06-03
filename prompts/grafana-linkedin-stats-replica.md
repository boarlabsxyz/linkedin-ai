# Research prompt — replicate the Observable LinkedIn Stats dashboard inside Grafana Cloud

Paste the block at the bottom into a fresh Claude Code session. It tells another
agent to design (and, if approved, execute) a 1:1 replica of the Observable
dashboard at https://boarlabsxyz.github.io/linkedin-ai/ inside the existing
empty Grafana dashboard at https://boarlabs.grafana.net/d/kiqz2fk/linkedin-stats,
**driving Grafana via the `mcp__grafana__*` tools** rather than clicking the UI.

The findings below were verified live on 2026-06-03:

- Observable site fetched via Playwright (both `/` and `/posts`).
- Grafana dashboard inspected via `mcp__grafana__get_dashboard_summary` (uid `kiqz2fk`) and via Playwright on the public-dashboard URL `https://boarlabs.grafana.net/public-dashboards/cccb02628ff5408b8420881b184d5001`.
- Plugin inventory checked via `mcp__grafana__get_plugin`.
- Datasource inventory checked via `mcp__grafana__list_datasources`.

## Findings recap

### What the Observable dashboard renders (the target)

Two pages, all charts driven from `dashboards/li-stats/` JSON files (one per post + one account file). The data loader at `dashboards/observable/src/data/stats.json.ts` flattens everything into:

```ts
{
  posts:                PostMeta[]            // {id, posted_date, type, preview, post_url}
  post_weeks:           PostWeek[]            // {id, week, impressions, members_reached, reactions, comments, reposts, saves, sends, profile_viewers, followers_gained, engagement_rate}
  post_demographics:    PostDemo[]            // {id, week, dimension, label, pct}
  account_weeks:        AccountWeek[]         // {week, followers, post_impressions_7d, profile_viewers_90d, search_appearances_previous_week, followers_delta_pct_7d}
  account_demographics: AccountDemo[]         // {week, dimension, label, pct}
}
```

`week` is an ISO Monday date string (e.g. `"2026-05-25"`); demographic `dimension` ∈ {`seniority`, `job_title`, `location`, `industry`, `company`, `company_size`}.

**Page 1 — Account view (`src/index.md`):**
1. 4 KPI cards (latest week): Followers / Post impressions 7d / Profile viewers 90d / Search appearances (prev week).
2. 4 trend line charts over `account_weeks`: Followers / Post impressions 7d / Profile viewers 90d / Search appearances.
3. 3 horizontal bar charts of `account_demographics` (latest week): Seniority / Top 10 job titles / Top 10 locations. Sorted desc by `pct`, labelled with `${pct}%`.
4. 1 stacked bar chart "Posts published per month" — counts of `posts` grouped by `posted_date.slice(0,7)`, with reposts as a second series.

**Page 2 — Per-post view (`src/posts.md`):**
5. `Inputs.select` post picker, options = `posts` sorted by `posted_date` desc, formatted as `"${posted_date} — ${preview.slice(0,80)}"`.
6. Selected-post preview card: posted_date + type + preview text + `Open on LinkedIn ↗` link.
7. 4 trend line charts over the selected post's `post_weeks`: Impressions / Engagement actions (multi-series: reactions, comments, reposts, saves, sends) / Engagement rate / Profile viewers & followers gained.
8. `Inputs.table` of the selected post's weekly rows (10 columns).
9. 6 horizontal bar charts of `post_demographics` for the latest week of the selected post: Seniority / Top 10 job titles / Top 10 industries / Company size / Top 10 locations / Top 10 companies.

### What the Grafana dashboard currently is

- UID `kiqz2fk`, title "LinkedIn Stats", folder `General`, version 2, public sharing enabled.
- **0 panels** (empty `New dashboard` placeholder confirmed via screenshot).
- Default time range `now-6h .. now` — wrong for week-grained data; needs to be widened in the rebuilt JSON.
- A public-dashboard token is already provisioned: `cccb02628ff5408b8420881b184d5001` (URL `/public-dashboards/<token>`).

### Grafana Cloud capabilities already in place

Datasources (from `list_datasources`):

| UID | Name | Type | Useful for this dashboard? |
| --- | --- | --- | --- |
| `grafanacloud-prom` | grafanacloud-boarlabs-prom | prometheus | only if metrics are pushed to Prom (not currently) |
| `grafanacloud-logs` | grafanacloud-boarlabs-logs | loki | only if snapshots are pushed as logs (not currently) |
| `grafanacloud-infinity` | grafanacloud-infinity | yesoreyeram-infinity-datasource (v3.8.0, **installed + enabled**) | **primary path — reads JSON via URL** |
| `grafanacloud-graphite`, `-traces`, `-profiles`, `-k6`, `-usage`, etc. | … | … | not relevant |

Plugins:
- `yesoreyeram-infinity-datasource` v3.8.0 — installed, enabled. The right tool for "read JSON files at a URL".
- `marcusolsson-dynamictext-panel` (Business Text) — **not installed**. Would help replicate the post-preview card with Markdown rendered against query data. Optional; can be installed via `mcp__grafana__install_plugin` if approved.
- `volkovlabs-form-panel` — not installed; not needed.
- Stat, Time series, Bar chart, Table, Text are all core panels — no install required.

### Data delivery problem

Infinity reads JSON over HTTPS. Three viable feeders for the data Grafana needs:

| Option | URL Grafana would hit | Effort | Trade-off |
| --- | --- | --- | --- |
| **A. GitHub raw, per file** | `https://raw.githubusercontent.com/boarlabsxyz/linkedin-ai/main/dashboards/li-stats/account.json`, plus one URL per post under `…/posts/<file>.json` | low | 36+ separate Infinity queries; cumbersome and slow; brittle when new posts appear |
| **B. Publish a single flat `stats.json` to GitHub Pages** | `https://boarlabsxyz.github.io/linkedin-ai/stats.json` | low | adds a tiny post-build copy step to `.github/workflows/linkedin-stats-weekly.yml` (or the Observable build) that writes the flattened payload to a stable path; one URL, identical shape to what `stats.json.ts` already produces |
| **C. Push to Prometheus/Loki on Grafana Cloud** | (no URL — push via remote_write / OTLP) | high | requires a new push pipeline; treats weekly snapshots as time series the "right" way but is overkill for ~36 posts × 4 weeks |

**Recommended: Option B.** Reuses the existing flattening logic, single HTTPS URL, no auth, plays well with Infinity's `URL` parser, and one CI change keeps Observable and Grafana fed from the same payload.

### Observable → Grafana panel mapping

Each row is **one Grafana panel**. All non-Demographics queries should use a single shared `stats` Infinity query (URL = the Option-B flat JSON), then drive each panel's shape via `root_selector`/`columns` + Transformations.

| # | Observable element | Grafana panel | Query / transform notes |
| --- | --- | --- | --- |
| 1a-d | 4 account KPI cards | **Stat** ×4 | Infinity `root_selector=account_weeks`, single column, transform `Sort by week asc` → `Reduce → Last (not null)`. One panel per field. |
| 2a-d | 4 account trend line charts | **Time series** ×4 | Same Infinity query. Need `week` as time. Set column type `Time` (format `YYYY-MM-DD`) inside Infinity, OR transform `Convert field type → week → Time`. One panel per field. |
| 3a-c | 3 account demographic bars (latest week) | **Bar chart** (horizontal, sorted) ×3 | Infinity `root_selector=account_demographics`. Transform: `Filter by value: dimension == seniority` (etc.), then `Filter data by query: week == ${account_latest_week}` (computed via a separate Infinity query that returns max(week)), then `Sort by pct desc`, then `Limit 10` for job_title/location. |
| 4 | "Posts published per month" stacked bar | **Bar chart** | Infinity `root_selector=posts`. Transform: `Add field from calculation → Binary op` to derive `month = posted_date[0:7]`, then `Group by → month + type`, `Count`, then `Pivot` so `type` becomes series. Stack on x. |
| 5 | Post picker | **Dashboard variable** `$post` (type `Query`) | Infinity Variable query: `root_selector=posts`, display = `${posted_date} — ${preview}`, value = `id`. Sort desc by `posted_date`. |
| 6 | Selected-post preview card | **Text panel** (Markdown) — best-effort | Native Text doesn't bind to query data. Two options: (a) define three more variables (`$post_date`, `$post_preview`, `$post_url`) backed by per-field Infinity Variable queries filtered by `$post` and reference them in Markdown; (b) install `marcusolsson-dynamictext-panel` (Business Text) which renders templates against query rows — cleaner, one panel, one query. **Decision needed (Q4).** |
| 7a-d | 4 per-post trend line charts | **Time series** ×4 | Infinity `root_selector=post_weeks`, filter `id == $post`, week → Time. "Engagement actions" needs all 5 metric columns kept as separate series; the others keep a single column. |
| 8 | Per-post weekly table | **Table** | Same query as #7 without the field filter; `Organize fields` to reorder + rename headers to match the Observable column titles. |
| 9a-f | 6 per-post demographic bars (latest week of the selected post) | **Bar chart** ×6 | Infinity `root_selector=post_demographics`, filter `id == $post` + `dimension == seniority|job_title|…` + `week == ${post_latest_week}`. `$post_latest_week` is a separate variable backed by `max(week)` for the chosen post. Sort desc, limit 10 where applicable. |

### Implementation path (Grafana MCP tools)

The rebuild **must not use the Grafana UI**. Drive everything through these MCP tools so the dashboard is reproducible and reviewable in PR diffs:

- `mcp__grafana__update_dashboard` — primary tool. Use **full JSON** mode (`dashboard: {...}`) to create the dashboard from scratch with all panels, variables, and time range in one call. Pass `uid: "kiqz2fk"` and `overwrite: true` so the existing empty dashboard is replaced rather than duplicated.
- `mcp__grafana__list_datasources` — to look up the `grafanacloud-infinity` UID at build time (do not hardcode IDs; UIDs are stable, IDs are not).
- `mcp__grafana__install_plugin` — only if Business Text is chosen (Q4).
- `mcp__grafana__get_dashboard_summary` and `mcp__grafana__get_dashboard_panel_queries` — to verify the result after writing.
- `mcp__grafana__generate_deeplink` (resourceType `dashboard`, `shorten: true`) — to return a clickable URL to the user when done.

After writing, verify each panel's query actually returns data:
- For Infinity queries there is no Prometheus-style `query_*` MCP helper; instead, re-`get_dashboard_panel_queries` and confirm the JSON shape; then take a Playwright screenshot of the rendered dashboard at `/d/kiqz2fk/linkedin-stats` (logged-in session via Peter's browser is available) for a visual smoke test.

### Decisions you need from the user before coding

Q1. **Data feed.** Confirm Option B (publish `stats.json` to GitHub Pages root) is acceptable. If yes, where to place the copy step — inside `dashboards/observable/observablehq.config.js` post-build, or as a `cp`/`jq` step in `.github/workflows/linkedin-stats-weekly.yml` after the Observable build? Recommended: workflow step, so the Observable dev server is unaffected.

Q2. **URL.** Confirm publish target. Default: `https://boarlabsxyz.github.io/linkedin-ai/stats.json`. (If Q1 puts the copy step inside Observable's `dist/`, the URL is the same.)

Q3. **Folder / dashboard placement.** Keep the rebuilt dashboard at uid `kiqz2fk` in folder `General`, or move into a new "LinkedIn" folder (`mcp__grafana__create_folder`)? Default: keep `kiqz2fk` + `General`.

Q4. **Post preview card (panel #6).** Pick one:
   - (a) Native Text panel + three extra `$post_*` variables. Zero installs, slightly clunky variable plumbing.
   - (b) Install `marcusolsson-dynamictext-panel` (Business Text). Cleaner Markdown templating against query rows; needs `install_plugin` approval.
   - (c) Skip the card; rely on the post picker's display label instead.

Q5. **Time range default.** The current `now-6h` is wrong. Default to `now-180d/d .. now/d` (covers the data we currently have, with day-bucketed snapping)? Or fix to `from = first known week, to = now`?

Q6. **Variable scope on Page 2.** Observable splits Account vs Per-post across two pages. Grafana has one canvas. Option: a "View" variable (`account` / `per-post`) used in panel `repeat`/`hide` rules to mimic two views; or one long single-page dashboard with row dividers. Default: single page with two collapsible **Rows** (`Account` / `Per-post`).

Q7. **Auto-refresh.** Snapshots land once a week. Default: refresh = `Off`, dashboard-level annotation that lists the latest `snapshot_at` from `account_weeks` (Infinity query). OK?

Q8. **Public dashboard.** Keep the existing public link (`/public-dashboards/cccb02628ff5408b8420881b184d5001`) active? It currently exposes nothing useful. If the rebuild should be public, the answer is yes and we keep the same token; if it shouldn't, we revoke via `DELETE /api/dashboards/uid/kiqz2fk/public-dashboards/<uid>`.

### Known gotchas

- Infinity's "JSON" type vs "JSON Backend" — backend parsing is required for variable interpolation inside `filter`/`computed_columns`. Use **Backend** for all queries that depend on `$post` etc.
- Bar chart `direction = horizontal` lives under `fieldConfig.defaults.custom.orientation = "horizontal"` in panel JSON.
- The Observable bars are labelled with `${pct}%` at bar-end — in Grafana, set `Show values: Always` and `Unit: percent (0-100)` on the bar chart.
- Engagement actions multi-series: pass `columns` to Infinity as `[reactions, comments, reposts, saves, sends]`, transform `Rows to fields` is **not** what you want — leave as columns and let the Time series panel auto-generate one series per field. Set series display names via `Field overrides`.
- Multi-page Observable layout becomes single-page in Grafana; the link "Per-post detail →" between Observable pages becomes a Row toggle (or a dashboard link if Q6 picks the variable approach).
- The Grafana Time series panel needs a true time field. Infinity's column type must be `time` with `format: "YYYY-MM-DD"` (or transform `Convert field type → week → Time → YYYY-MM-DD`).

## The prompt

```
You are continuing work on the LinkedIn AI repo (cwd: /Users/peterovchinnikov/work/ai/linkedin-ai). Goal: build a Grafana dashboard at uid kiqz2fk that visually and functionally replicates the existing Observable dashboard at https://boarlabsxyz.github.io/linkedin-ai/ . The Grafana dashboard exists but is empty (0 panels). You must drive Grafana via the `mcp__grafana__*` MCP tools, not the web UI.

Authoritative reference for the visual target: dashboards/observable/src/index.md and dashboards/observable/src/posts.md (Observable Framework + Observable Plot). Authoritative data shape: dashboards/observable/src/data/stats.json.ts (the loader that flattens dashboards/li-stats/account.json + dashboards/li-stats/posts/*.json).

Read prompts/grafana-linkedin-stats-replica.md in this repo for the full panel-by-panel mapping, the data-feed decision, the verified Grafana state, and the gotchas. Use it as your spec. Do not duplicate the research; trust the findings recap unless you have a concrete reason to re-verify a specific claim.

Before writing any dashboard JSON, get explicit answers from the user to Q1–Q8 in that doc. Do NOT proceed past Q4 without an answer to that question (it changes whether you install a plugin). For each Q, restate the default + the recommendation, then ask. Group Q1+Q2 together (data feed + URL).

Once Q1–Q8 are resolved:

1. If Q1 = Option B (default): write the GitHub Actions step that copies the flat stats.json into the published site. Match the existing workflow conventions in .github/workflows/linkedin-stats-weekly.yml — same checkout step, same `claude -p` cadence, same auto-merge. Use the existing `dashboards/observable/src/data/stats.json.ts` logic (consider extracting it into a standalone Node script under `.github/scripts/` so both the workflow and Observable's loader call the same code; OR keep it inline as a workflow `run:` block that emits to `dashboards/observable/dist/stats.json`). Verify the resulting URL is reachable via `curl -I` after a fresh deploy.

2. Look up the Infinity datasource UID at run time via `mcp__grafana__list_datasources` and keep it in a variable; do not hardcode `grafanacloud-infinity` in JSON if a UID lookup is cleaner.

3. Construct the dashboard JSON in memory. Required structure:
   - title: "LinkedIn Stats", uid: "kiqz2fk", overwrite: true
   - time: { from: <Q5 answer>, to: "now" }, refresh: <Q7 answer>
   - templating.list: variables in this order — post (Query, Infinity), post_latest_week (Query, Infinity), account_latest_week (Query, Infinity), plus any $post_preview / $post_date / $post_url / $post_type if Q4 = (a)
   - panels: ordered to mirror the Observable layout: KPI row (4 stat panels) → trend row (4 time series) → demographic row (3 bar charts) → posts-per-month bar → ROW: Per-post → preview card → trend row (4 time series) → table → demographic row (6 bar charts)
   - Use Grafana's "Row" panels (`type: "row"`) with `collapsed: true` if Q6 = single-page rows.

4. Write the dashboard via `mcp__grafana__update_dashboard({uid: "kiqz2fk", dashboard: {...}, overwrite: true, message: "Replicate Observable LinkedIn Stats dashboard via MCP"})`. Read it back with `mcp__grafana__get_dashboard_summary` and `mcp__grafana__get_dashboard_panel_queries` to confirm panel count matches expectation (24 total panels by my count: 4 KPI + 4 acct trend + 3 acct demo + 1 posts/month + 1 preview + 4 post trend + 1 table + 6 post demo, plus rows).

5. Smoke test:
   - Use Playwright (the user is logged in as Peter) to open https://boarlabs.grafana.net/d/kiqz2fk/linkedin-stats?orgId=1 .
   - Take a full-page screenshot and visually diff it against tmp/observable-account.png and tmp/observable-posts.png (or re-screenshot the Observable site if those don't exist).
   - Confirm every panel actually rendered data (no "No data" placeholders). If any panel shows No data, fix the query / transform, write back, and re-screenshot.

6. When done:
   - Call `mcp__grafana__generate_deeplink({resourceType: "dashboard", dashboardUid: "kiqz2fk", shorten: true})` and report the URL.
   - Summarize panel-by-panel: what got built, any deviations from the Observable layout, any panels where the JSON-feed shape forced a compromise.
   - DO NOT commit. The user will run `common-pr-commit` separately.

Conventions to honor (from CLAUDE.md):
- Touch dashboards/li-stats/ only if necessary; treat it as data, not source.
- If a new shared script is added under .github/scripts/, document it in CLAUDE.md per the auto-memory rules.
- Temp artefacts (screenshots, scratch JSON) go in ./tmp/ which is gitignored.

Hard constraints:
- No clicking through the Grafana UI. Every dashboard change must be in the audit log as a `mcp__grafana__update_dashboard` call.
- Do not push, do not open a PR, do not branch. The user handles git.
- If you hit an "Infinity returns string instead of number" or "week parsed as string not time" issue, fix it inside the Infinity column type configuration first; only resort to a transform if the type override fails.

Output as you work: short status updates after each step (1 sentence). Final report: panel count, dashboard URL, list of unresolved compromises, screenshot path.
```
