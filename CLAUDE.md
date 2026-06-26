# LinkedIn AI

LinkedIn post generation and workflow automation. The repo currently holds writing instructions, Claude Code skills, and MCP configuration — no application code yet. If application code is added, use TypeScript and follow existing patterns.

## User Interests (for LinkedIn content discovery)
- AI / LLMs / AI Agents / AI Engineering
- Startups / Entrepreneurship / Fundraising / Growth

## Repository structure

```
.
├── sources/                      # LinkedIn writing guidance (canonical copies pulled from ClickUp)
│   ├── tone-of-voice.md          # Tone, taboos, sentence rhythm (Ukrainian)
│   └── post-instructions.md      # Post structure, mini-brief format, quality formula (Ukrainian)
├── dashboards/                   # LinkedIn analytics data + Grafana dashboard snapshots
│   ├── li-stats/                 # Raw LinkedIn analytics JSON (git-tracked, written by linkedin-stats agents)
│   └── grafana/                  # Exported Grafana dashboard JSONs (linkedin-stats.json + linkedin-stats-posts.json) — source-of-truth snapshots
├── prompts/                      # Ad-hoc prompt drafts (e.g., plan-mode prompts) — checked in for reuse, not consumed by Claude Code automatically
├── doc/                          # Project documentation
│   └── history/                  # Auto-captured conversation transcripts written by the hooks below (one .md per session, named <UTC-ts>-<slug>.md)
├── .claude/
│   ├── settings.json             # Permission allowlist + hooks config (SessionStart / UserPromptSubmit / Stop)
│   ├── hooks/                    # Conversation-history hooks: prompt-submit.sh, assistant-stop.sh, session-start.sh, lib.sh
│   ├── skills/                   # Project skills (see below)
│   └── agents/                   # Sub-agents spawned by skills via the Agent tool
├── .github/workflows/            # GitHub Actions (linkedin-stats-weekly runs on self-hosted macOS)
├── .github/scripts/              # CI helper scripts (build-stats-json.mjs: flattens li-stats/*.json into Pages-hosted stats.json for Grafana Infinity)
├── .mcp.json                     # MCP servers: context7, terminal, playwright, grafana
├── start.sh                      # Local launcher: sources .env then execs `claude --dangerously-skip-permissions`
├── .env.example                  # Template for the gitignored .env that start.sh loads
└── CLAUDE.md                     # This file
```

`sources/` is the source-of-truth content for generating Peter's LinkedIn posts. It is overwritten by the `sync-sources` skill — local edits to those files are intentionally not preserved.

## Skills

Skills live in `.claude/skills/<name>/SKILL.md`. Multi-step skills with detailed sub-guidance keep that detail in `references/` next to the SKILL.md.

| Skill | Purpose |
|---|---|
| `common-pr-commit` | Branch + commit + push + update PR. Invokes `common-update-memory` before staging. |
| `common-pr-update` | Create or edit the PR with conventional-commit title and bullet body. |
| `common-pr-merge` | Squash-merge current branch's PR, clean up local + remote branches. |
| `common-update-memory` | Reviews staged diff and updates CLAUDE.md if structural/conceptual changes need to be reflected. Auto-called by `common-pr-commit`. |
| `sync-sources` | One-way pull of LinkedIn writing docs from ClickUp into `sources/`. |
| `awesome-sync-tasks` | Process `[AWESOME] Sync` Google Drive transcripts → create/update ClickUp tasks. |
| `weekly-priorities` | Process last week's meeting transcripts → update/create personal priorities in ClickUp. |
| `utilities-youtube-transcript` | Download a YouTube video's transcript via yt-dlp; falls back to Playwright agent on HTTP 429. Spawns `utilities-youtube-transcript-vtt` / `-playwright` sub-agents. |
| `linkedin-comment-ideas` | Generate 2-3 ready-to-paste LinkedIn comment variants in Petro's voice for a given post. Loads the post via Playwright (or accepts pasted text), runs a pre-work checklist against the Posted folder, Transcripts folder, ICP doc, and True BDD factsheet in Google Drive, then applies ONE of seven strategies per variant. Strategies live in `references/strategies.md`. |
| `linkedin-stats` | Snapshot Peter's LinkedIn posts + per-post + account-level weekly analytics into JSON files under `./dashboards/li-stats/` (git-tracked). Spawns `linkedin-stats-gather-posts` (URN discovery), then one `linkedin-stats-gather-metrics` agent **per post** sequentially (post-summary + 6 demographic breakdowns + top-level commenters from the public post URL → `weeks[WEEK].{metrics,demographics,comments}`), then `linkedin-stats-gather-account` (dashboard + 4 creator-analytics pages → `account.json`), then `linkedin-stats-gather-comments-out` (Peter's outbound comments from `/recent-activity/comments/`, URN-decoded for exact timestamps → `comments.json` keyed by `comments[urn]` with static metadata + `weeks[WEEK]` reactions/replies snapshots; discovery floor = oldest tracked post's `posted_date` with an incremental `RECENT_FLOOR_MS` shortcut on subsequent runs; weekly snapshot only for comments younger than 30 days at WEEK midnight UTC). Parallel fan-out across sub-agents is unsafe with the shared Playwright MCP (no per-call tab targeting). Driven weekly (Mon 00:00 UTC) by `.github/workflows/linkedin-stats-weekly.yml` via the colocated `run-weekly.sh`, which calls `claude -p --dangerously-skip-permissions`, then chains `common-pr-commit` + `common-pr-update` + `common-pr-merge` (auto-merge keeps weekly snapshots from piling up into conflicts). |

## Dashboard

LinkedIn analytics are visualised in two Grafana Cloud dashboards on `https://boarlabs.grafana.net`. The data is collected by the `linkedin-stats` skill into JSON under `dashboards/li-stats/`, flattened to a single payload by `.github/scripts/build-stats-json.mjs`, and published to GitHub Pages as the sole file at `https://boarlabsxyz.github.io/linkedin-ai/stats.json`. Grafana reads it via the Infinity datasource (`grafanacloud-infinity`).

Two workflows publish the file (both share the `pages` concurrency group, both require Pages source = **GitHub Actions** in repo settings):
- `.github/workflows/linkedin-stats-weekly.yml` — Mon 00:00 UTC. Two jobs: `scrape` runs on the self-hosted Mac and ends after `run-weekly.sh` lands the new JSONs on `main`; `publish` (`needs: scrape`) runs on `ubuntu-latest`, checks out fresh `main`, builds `stats.json`, uploads via `actions/upload-pages-artifact`, deploys via `actions/deploy-pages`. The Mac runner no longer runs `actions/upload-pages-artifact` (which requires `gtar`).
- `.github/workflows/pages-deploy.yml` — manual `workflow_dispatch`: republishes `stats.json` from current `main` without scraping.

The two Grafana dashboards:
- **`linkedin-stats`** (uid `kiqz2fk`, `/d/kiqz2fk/linkedin-stats`) — Account view: KPIs, trends, audience demographics, posts-per-month, comments-per-month (count + reactions + impressions), plus a full-width Plotly scatter (`ae3e-plotly-panel`, requires plugin install) of "posts published that month" (X) vs "post's latest-snapshot impressions" (Y) that fits a quadratic curve via in-browser Gaussian elimination on the normal equations (R² in the legend). No variables. `posts_per_month` entries include `total_impressions` (sum of each post's latest-snapshot `impressions`) and `avg_impressions_per_post`; both pull from the latest weekly snapshot, so the trailing month reads low until posts accumulate impressions. `correlation_points` (one entry per post: `posts_in_month`, `impressions`, `id`, `posted_date`, `type`) feeds the scatter panel; `correlation_trend` in `stats.json` (2 endpoints of an OLS line) is now unused — the panel fits its own curve in-browser. A second full-width Plotly panel ("Impressions per post over time") plots the same per-post points with `posted_date` on X and overlays an IRLS median (L1) regression line plus a 200-resample percentile bootstrap 95% band (deterministic LCG seeded by N so the band doesn't shimmer on refresh) — the robust alternative the cadence research recommended for heavy-tailed creator data, with pseudo-R² (1 − Σ\|y−ŷ\| / Σ\|y−median\|) in the legend.
- **`LinkedIn Stats — Per-post`** (uid `linkedin-post`, `/d/linkedin-post/...`) — Per-post view: `$post` Custom variable picker, selected-post text panel, 4 weekly bar charts (Impressions / Engagement actions / Engagement rate / Profile viewers & followers gained), weekly metrics table, 6 audience demographic bars. Per-post charts cap at the first 12 weekly snapshots via `sortBy(week asc) + limit 12`.

Source-of-truth JSONs for both dashboards live in `dashboards/grafana/`. Dashboards are built/updated via the `mcp__grafana__*` MCP tools (no UI clicks); the original research spec lives in `prompts/grafana-linkedin-stats-replica.md`. Notable Infinity gotchas: backend-mode queries ignore the `filters:[]` array — use `filterExpression: "id == \"${post}\""` and include every filtered field in `columns`. Variable resolution requires Custom variable type with `query` in `display : value, display : value, …` format (the Query variable type silently fails to populate options in Grafana 12 v0alpha1 dashboards). Date strings break `==` parsing — use `contains(week, "2026-06")` instead of `week == "2026-06-01"`.

## External systems

- **ClickUp** — source of truth for the LinkedIn writing docs (workspace `90151491867`), for AWESOME tasks (list `901522119783` in space `901510520225`), and for personal priorities (list `901522189872`). Skill files contain the specific IDs.
- **Google Drive** — meeting transcripts. AWESOME single transcripts folder: `14I2yIWsoZ5BTJD-Sqk9nVkU23iC11eYJ`.
- **Google Calendar** — used by `weekly-priorities` to scope the previous week's meetings.
- **MCP servers** (in `.mcp.json`): `context7` (library docs), `terminal` (interactive terminal), `playwright` (browser automation), `grafana` (Grafana Cloud — `https://boarlabs.grafana.net`; reads `GRAFANA_SERVICE_ACCOUNT_TOKEN` from the launching shell's env).

## Local launch

Launch Claude Code via `./start.sh` — it sources the gitignored `.env` (env vars referenced by `.mcp.json`, e.g. `GRAFANA_SERVICE_ACCOUNT_TOKEN`) and execs `claude --dangerously-skip-permissions`. On first checkout, `cp .env.example .env` and fill in the values. Additional CLI args pass through (`./start.sh /some-skill`).

## Conventions

- **Skill scope:** if a workflow has more than ~50 lines of detail, split sub-guidance into `references/` files next to the SKILL.md. Keep SKILL.md focused on flow + constants.
- **Bundled scripts in skills:** PR skills (`common-pr-commit`, `common-pr-merge`, `common-pr-update`) keep their bash logic in colocated `.sh` files (e.g., `commit.sh`, `merge.sh`, `pr-update.sh`), allowlisted by path in `.claude/settings.json` to avoid permission prompts on compound-bash parsing. `commit.sh` and `pr-update.sh` invoke `claude -p` internally to generate the commit message and PR copy from the diff.
- **`*-shared/` skill folders:** folders under `.claude/skills/` with a `-shared` suffix (e.g., `utilities-shared/`) hold scripts referenced by other skills rather than being invocable skills themselves — no `SKILL.md`, just shared utilities.
- **Sub-agents:** thin orchestrator skills can spawn sub-agents from `.claude/agents/<name>.md` via the Agent tool. Each agent's frontmatter declares its `tools:` allowlist and `model:`. Examples: `utilities-youtube-transcript` spawns `utilities-youtube-transcript-vtt` and `utilities-youtube-transcript-playwright`; `linkedin-stats` spawns `linkedin-stats-gather-posts`, `linkedin-stats-gather-metrics`, `linkedin-stats-gather-account`, and `linkedin-stats-gather-comments-out`.
- **Transcript language:** AWESOME Sync and weekly meeting transcripts are in Russian/Ukrainian; ClickUp output is always in English with consistent transliteration (e.g., always "Petro", not sometimes "Peter").
- **Temp files:** use `./tmp/` and clean up afterward. Listed in `.gitignore`.
- **ClickUp writes need validation:** AWESOME and weekly-priorities both validate every extracted item one-by-one before writing — auto-generated tasks/priorities are noisy and require human judgment.
- **Conversation-history hooks:** `.claude/hooks/` auto-writes every session's transcript to `doc/history/<UTC-ts>-<slug>.md` — one `## user` block per prompt, one `## claude` block per assistant text block, plus `## claude (asked)` / `## user (answered)` for AskUserQuestion exchanges (parsed from the JSONL transcript since `PostToolUse` doesn't fire for that tool — see [#12605](https://github.com/anthropics/claude-code/issues/12605)). Tool calls (Bash/Read/Edit/Write/…) are intentionally skipped to keep the file a Q&A transcript. `tmp/history-current` is the sentinel naming the active file.

## Git workflow rules

- **Never** create branches, switch branches, commit, push, or create PRs unless explicitly requested in the user's prompt, plan, or instructions.
- Git operations are user-initiated only — do not proactively perform any git actions.
- **When the user says "commit", "commit changes", "push", or any variation** — always use the `common-pr-commit` skill via the Skill tool. Do NOT follow manual git commit steps.
