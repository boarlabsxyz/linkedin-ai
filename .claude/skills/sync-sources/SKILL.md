---
name: sync-sources
description: Pull the LinkedIn writing instruction docs from ClickUp and overwrite the local files in sources/. One-way ClickUp → repo sync. Use whenever the user says "sync sources", "pull sources", "refresh instructions", "update tone of voice", "pull from clickup", or wants the local sources/ folder to match the canonical ClickUp Docs.
---

# Sync Sources

ClickUp is the source of truth for the LinkedIn writing instructions. This skill pulls the latest content from two ClickUp Docs and overwrites the corresponding local files in `sources/`.

## Configuration

| Local file | ClickUp doc | Doc ID |
|---|---|---|
| `sources/tone-of-voice.md` | LinkedIn — Tone of Voice | `2kyq568v-17915` |
| `sources/post-instructions.md` | LinkedIn — Post Instructions | `2kyq568v-17935` |

Workspace ID: `90151491867`. Parent folder (for reference, not used by sync): `901515356043`.

## Steps

For each doc in the table above:

1. Call `mcp__claude_ai_ClickUP__getDoc` with the workspace ID and doc ID.
2. Extract every page's markdown content from the response.
3. Concatenate page contents in order with a single blank line between pages (most docs are one page; this just future-proofs).
4. Overwrite the target local file with the concatenated content using the Write tool. Do not preserve the previous local content — ClickUp wins.

After both files are written, report which files were updated and how many bytes each.

## Rules

- One-way only: never push local → ClickUp from this skill.
- Always overwrite, even if local has uncommitted edits. Local edits to these files are not the source of truth and will be lost — that is the design.
- If a `getDoc` call fails, stop and report which doc failed. Do not partially update.
- Do not commit. The user runs `common-pr-commit` separately if they want the sync persisted.
