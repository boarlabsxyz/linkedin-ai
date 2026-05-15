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
├── .claude/
│   ├── settings.json             # Permission allowlist (git, gh, mkdir, rm ./tmp/*, cat, echo)
│   ├── skills/                   # Project skills (see below)
│   └── agents/                   # Sub-agents spawned by skills via the Agent tool
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
| `linkedin-stats` | Snapshot Peter's LinkedIn posts + per-post weekly analytics into JSON files under `./tmp/li-stats/`. Spawns `linkedin-stats-gather-posts` (URN discovery) then `linkedin-stats-gather-metrics` (post-summary + 6 demographic breakdowns) sub-agents. |

## External systems

- **ClickUp** — source of truth for the LinkedIn writing docs (workspace `90151491867`), for AWESOME tasks (list `901522119783` in space `901510520225`), and for personal priorities (list `901522189872`). Skill files contain the specific IDs.
- **Google Drive** — meeting transcripts. AWESOME single transcripts folder: `14I2yIWsoZ5BTJD-Sqk9nVkU23iC11eYJ`.
- **Google Calendar** — used by `weekly-priorities` to scope the previous week's meetings.
- **MCP servers** (in `.mcp.json`): `context7` (library docs), `terminal` (interactive terminal), `playwright` (browser automation).

## Conventions

- **Skill scope:** if a workflow has more than ~50 lines of detail, split sub-guidance into `references/` files next to the SKILL.md. Keep SKILL.md focused on flow + constants.
- **Bundled scripts in skills:** PR skills (`common-pr-commit`, `common-pr-merge`, `common-pr-update`) keep their bash logic in colocated `.sh` files (e.g., `commit.sh`, `merge.sh`, `pr-update.sh`), allowlisted by path in `.claude/settings.json` to avoid permission prompts on compound-bash parsing. `commit.sh` and `pr-update.sh` invoke `claude -p` internally to generate the commit message and PR copy from the diff.
- **`*-shared/` skill folders:** folders under `.claude/skills/` with a `-shared` suffix (e.g., `utilities-shared/`) hold scripts referenced by other skills rather than being invocable skills themselves — no `SKILL.md`, just shared utilities.
- **Sub-agents:** thin orchestrator skills can spawn sub-agents from `.claude/agents/<name>.md` via the Agent tool. Each agent's frontmatter declares its `tools:` allowlist and `model:`. Examples: `utilities-youtube-transcript` spawns `utilities-youtube-transcript-vtt` and `utilities-youtube-transcript-playwright`; `linkedin-stats` spawns `linkedin-stats-gather-posts` and `linkedin-stats-gather-metrics`.
- **Transcript language:** AWESOME Sync and weekly meeting transcripts are in Russian/Ukrainian; ClickUp output is always in English with consistent transliteration (e.g., always "Petro", not sometimes "Peter").
- **Temp files:** use `./tmp/` and clean up afterward. Listed in `.gitignore`.
- **ClickUp writes need validation:** AWESOME and weekly-priorities both validate every extracted item one-by-one before writing — auto-generated tasks/priorities are noisy and require human judgment.

## Git workflow rules

- **Never** create branches, switch branches, commit, push, or create PRs unless explicitly requested in the user's prompt, plan, or instructions.
- Git operations are user-initiated only — do not proactively perform any git actions.
- **When the user says "commit", "commit changes", "push", or any variation** — always use the `common-pr-commit` skill via the Skill tool. Do NOT follow manual git commit steps.
