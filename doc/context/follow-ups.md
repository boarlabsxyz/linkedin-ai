# Follow-ups — conversational ledger

Work explicitly deferred or requested but not done in its task, extracted from
task transcripts by the context archivist (`.claude/hooks/context.py`).
Append-only; newest at the bottom. Strike through or remove items once done.

## 2026-07-18 — The task explored moving LinkedIn analytics to ClickUp, corrected a task-type naming hallucination, created an MCP gap ticket, migrated comment automation to GitHub Actions, and diagnosed a failed weekly scrape.

_transcript: 20260718-190554-372ee591-next-task-is-it-use-clicku-as-source-of.md_

- Complete the ClickUp-as-source-of-truth migration: the transcript stopped after schema exploration and a proof of concept, without implementing the scraper-to-ClickUp synchronization or rewiring the stats build to consume ClickUp (requested 2026-07-18T19:05:54Z; still at design/PoC stage 2026-07-20T09:24:57Z).

## 2026-07-21 — The task designed, implemented, and live-tested a Codex-powered context archivist, then moved toward transferring the work out of the GitHub runner checkout.

_transcript: 20260721-211138-f69df0df-we-have-a-history-hooks-what-is-great-i.md_

- Restore the self-hosted GitHub Actions runner checkout to an absolutely clean state after transferring the context-archivist changes, including removing its `.env`; completion was not confirmed before the transcript ended (requested 2026-07-21T21:49:56Z).
