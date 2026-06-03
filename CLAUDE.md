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
├── dashboards/                   # Static-site dashboard + the data it reads
│   ├── li-stats/                 # Raw LinkedIn analytics JSON (git-tracked, written by linkedin-stats agents)
│   └── observable/               # Observable Framework project (JS + Observable Plot)
├── prompts/                      # Ad-hoc prompt drafts (e.g., plan-mode prompts) — checked in for reuse, not consumed by Claude Code automatically
├── .claude/
│   ├── settings.json             # Permission allowlist (git, gh, mkdir, rm ./tmp/*, cat, echo)
│   ├── skills/                   # Project skills (see below)
│   └── agents/                   # Sub-agents spawned by skills via the Agent tool
├── .github/workflows/            # GitHub Actions (linkedin-stats-weekly runs on self-hosted macOS)
├── .mcp.json                     # MCP servers: context7, terminal, playwright
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
| `linkedin-stats` | Snapshot Peter's LinkedIn posts + per-post + account-level weekly analytics into JSON files under `./dashboards/li-stats/` (git-tracked). Spawns `linkedin-stats-gather-posts` (URN discovery), then one `linkedin-stats-gather-metrics` agent **per post** sequentially (post-summary + 6 demographic breakdowns → `weeks[WEEK]`), then `linkedin-stats-gather-account` (dashboard + 4 creator-analytics pages → `account.json`). Parallel fan-out across sub-agents is unsafe with the shared Playwright MCP (no per-call tab targeting). Driven weekly (Mon 00:00 UTC) by `.github/workflows/linkedin-stats-weekly.yml` via the colocated `run-weekly.sh`, which calls `claude -p --dangerously-skip-permissions`, rebuilds the Observable dashboard, then chains `common-pr-commit` + `common-pr-update` + `common-pr-merge` (auto-merge keeps weekly snapshots from piling up into conflicts). |

## Dashboard

The Observable Framework dashboard at `dashboards/observable/` visualises the LinkedIn analytics that the `linkedin-stats` skill collects into `dashboards/li-stats/`. Local dev: `npm --prefix dashboards/observable run dev`. Observable's TS data loader at `dashboards/observable/src/data/stats.json.ts` reads the JSON files in `dashboards/li-stats/` directly at build time — no intermediate flattening step.

The site is published to GitHub Pages at `https://boarlabsxyz.github.io/linkedin-ai/` by the `linkedin-stats-weekly` workflow (`actions/upload-pages-artifact` after the build step + a separate `deploy` job running `actions/deploy-pages`). A second workflow, `.github/workflows/pages-deploy.yml` (manual `workflow_dispatch` only), builds and republishes from current `main` without scraping — use it for ad-hoc re-publishes. Both share the same `pages` concurrency group. The site is served under the `/linkedin-ai/` subpath, set via `base` in `dashboards/observable/observablehq.config.js` — both `npm run dev` and the production build honor it. Pages source must be set to **GitHub Actions** in repo settings.

## External systems

- **ClickUp** — source of truth for the LinkedIn writing docs (workspace `90151491867`), for AWESOME tasks (list `901522119783` in space `901510520225`), and for personal priorities (list `901522189872`). Skill files contain the specific IDs.
- **Google Drive** — meeting transcripts. AWESOME single transcripts folder: `14I2yIWsoZ5BTJD-Sqk9nVkU23iC11eYJ`.
- **Google Calendar** — used by `weekly-priorities` to scope the previous week's meetings.
- **MCP servers** (in `.mcp.json`): `context7` (library docs), `terminal` (interactive terminal), `playwright` (browser automation).

## Conventions

- **Skill scope:** if a workflow has more than ~50 lines of detail, split sub-guidance into `references/` files next to the SKILL.md. Keep SKILL.md focused on flow + constants.
- **Bundled scripts in skills:** PR skills (`common-pr-commit`, `common-pr-merge`, `common-pr-update`) keep their bash logic in colocated `.sh` files (e.g., `commit.sh`, `merge.sh`, `pr-update.sh`), allowlisted by path in `.claude/settings.json` to avoid permission prompts on compound-bash parsing. `commit.sh` and `pr-update.sh` invoke `claude -p` internally to generate the commit message and PR copy from the diff.
- **`*-shared/` skill folders:** folders under `.claude/skills/` with a `-shared` suffix (e.g., `utilities-shared/`) hold scripts referenced by other skills rather than being invocable skills themselves — no `SKILL.md`, just shared utilities.
- **Sub-agents:** thin orchestrator skills can spawn sub-agents from `.claude/agents/<name>.md` via the Agent tool. Each agent's frontmatter declares its `tools:` allowlist and `model:`. Examples: `utilities-youtube-transcript` spawns `utilities-youtube-transcript-vtt` and `utilities-youtube-transcript-playwright`; `linkedin-stats` spawns `linkedin-stats-gather-posts`, `linkedin-stats-gather-metrics`, and `linkedin-stats-gather-account`.
- **Transcript language:** AWESOME Sync and weekly meeting transcripts are in Russian/Ukrainian; ClickUp output is always in English with consistent transliteration (e.g., always "Petro", not sometimes "Peter").
- **Temp files:** use `./tmp/` and clean up afterward. Listed in `.gitignore`.
- **ClickUp writes need validation:** AWESOME and weekly-priorities both validate every extracted item one-by-one before writing — auto-generated tasks/priorities are noisy and require human judgment.

## Git workflow rules

- **Never** create branches, switch branches, commit, push, or create PRs unless explicitly requested in the user's prompt, plan, or instructions.
- Git operations are user-initiated only — do not proactively perform any git actions.
- **When the user says "commit", "commit changes", "push", or any variation** — always use the `common-pr-commit` skill via the Skill tool. Do NOT follow manual git commit steps.
