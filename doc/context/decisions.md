# Decisions — conversational ledger

Choices made in conversation — what was chosen, why, and what was rejected —
extracted from task transcripts by the context archivist (`.claude/hooks/context.py`).
Append-only; newest at the bottom. A superseded entry is struck through, never
deleted.

## 2026-07-20 — The task implemented and live-tested a self-healing weekly LinkedIn stats pipeline, repaired the runner architecture, and merged the healed scrape and watchdog cleanup.

_transcript: 20260720-114324-f671ba95-i-want-also-to-create-make-the-workflow.md_

- Use the native `osx-arm64` package for the Mac Studio’s self-hosted GitHub Actions runner rather than retaining a persistent `arch -arm64` scraper wrapper; Peter chose the permanent reinstall after the old runner was proven to execute under Rosetta (2026-07-20T14:10:46Z).
