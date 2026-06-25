---
name: task-define
description: >
  Turn a one-line idea into a comprehensive, self-contained task definition
  for this project, written to ./tasks/<slug>.md. Use whenever the user says
  "define a task", "create a task definition", "draft a task", "task spec",
  "spec out X", "new task for...", or supplies a one-line idea and asks for
  a comprehensive plan/brief. The skill scouts the repo for relevant context
  via an Explore subagent, then synthesizes goal, scope, approach, acceptance
  criteria, and file pointers.
---

# Task Definition

Turn a one-line idea into a thorough, self-contained markdown plan at `./tasks/<slug>.md`. The plan should give a future Claude session (or a human) everything needed to start the work without re-asking the user.

## Input

The user gives a **one-line idea** — e.g. "add a per-post sentiment chart to the dashboard" or "rework comment scraping to handle pagination edge cases."

If no idea was provided with the invocation, ask one short question: "What's the task idea, in one line?"

## Flow

### Step 1 — Derive the slug

Make a kebab-case slug from the seed words of the user's idea. 3–6 words max. Drop articles, lower-case everything, replace spaces with `-`.

| Input | Slug |
|---|---|
| "add a per-post sentiment chart to the dashboard" | `per-post-sentiment-chart` |
| "rework comment scraping to handle pagination" | `comment-scraping-pagination` |
| "switch li-stats publish job to ubuntu" | `li-stats-publish-ubuntu` |

If `./tasks/<slug>.md` already exists, stop and ask the user whether to overwrite, append, or pick a new slug.

### Step 2 — Explore the repo (Agent: Explore)

Spawn the `Explore` subagent with breadth `"very thorough"` and this brief:

> Scout the LinkedIn AI repo for everything relevant to: **\<the user's one-line idea verbatim\>**.
> Report back:
> - Files and folders directly related (with file:line pointers for key symbols)
> - Existing skills, sub-agents, or scripts that overlap
> - Conventions in the relevant area (naming, structure, persistence, CI)
> - Any existing partial implementation or prior attempt
> - External systems involved (ClickUp lists, Google Drive folders, MCP servers, Grafana dashboards)
>
> Keep the report under ~400 words, but cite specific paths.

Wait for the report before drafting. Do NOT skip this step — the report is what makes the task definition "comprehensive."

### Step 3 — Draft the task definition

Synthesize the report into a markdown file using the template below. Fill every section. If a section genuinely doesn't apply, write `_n/a_` with a one-line reason — never leave a section blank.

```markdown
# <Title — one-line restating the goal in clean prose>

## Goal & Why

<2-4 sentences: what success looks like and why this matters now. Lift hints
from the user's input and any motivation surfaced by the Explore report.>

## Context

<5-10 bullets describing what already exists in this area of the repo.
Cite specific paths with file:line pointers when naming a function/symbol.
This is the "current state" the work mutates.>

## Scope

**In scope:**
- <concrete deliverable>
- <concrete deliverable>

**Out of scope:**
- <thing a reader might assume is included but isn't>

## Approach

<3-8 bullets sketching the high-level plan. Not a step-by-step. Name the
files that will change, the new files/folders that will be created, and any
external systems touched. Call out the order of work when sequencing matters.>

## Acceptance criteria

- [ ] <observable outcome — what would prove this is done>
- [ ] <observable outcome>
- [ ] <observable outcome>

## Open questions / Risks

- <question the user should answer before starting, or a risk worth naming>
- <question / risk>

## References

- <repo path> — <one-line why it's relevant>
- <repo path> — <one-line why it's relevant>
- <external URL or doc, if any> — <one-line why>
```

### Step 4 — Write the file

Use the Write tool to create `./tasks/<slug>.md`. If `./tasks/` does not exist, create it first with `mkdir -p tasks` via Bash.

### Step 5 — Report

Output a 3-line summary to the user:
- Path written
- The Title line from the file
- A one-sentence summary of what the task asks for

## Conventions

- **Language:** English.
- **No invention:** every claim about "what already exists" must come from the Explore report or a tool call you made yourself — do not infer from training data or guess at paths.
- **No code in the plan:** the plan describes work, it doesn't implement it. Tiny snippets (1–3 lines) showing a current pattern are fine; anything longer belongs in the implementation PR.
- **Slugs are stable:** if the user later asks to "update the task definition for X", reuse the existing slug — don't generate a new one.
- **`tasks/` is checked into the repo** — durable artifact, not a scratchpad. Commit it like any other source file when the user asks to commit.

## DO NOT

- Do not skip the Explore step. A task definition without a repo scout is just a glorified restatement of the user's input.
- Do not write code beyond the tiny inline snippets described above. The plan is the deliverable, not the implementation.
- Do not overwrite an existing `./tasks/<slug>.md` without explicit user confirmation.
- Do not create the file under any path other than `./tasks/<slug>.md`.
- Do not auto-commit. Git operations are user-initiated only (per CLAUDE.md).
