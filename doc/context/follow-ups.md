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

## 2026-07-25 — The task pulled main and began retesting LinkedIn post generation’s Slack intake and dual Slack/ClickUp delivery, but the human-message path remained blocked pending a new link from Peter.

_transcript: 20260725-150058-15284ba4-the-linkedin-post-generation-i-need-two.md_

- ~~Complete the live end-to-end retest after Peter posts a previously unused LinkedIn post link as a human-authored message in Slack channel `C0BF606R4N7`, verifying both the Slack-thread output and ClickUp-task creation; the test remained blocked because bot-authored test messages are intentionally filtered (requested 2026-07-27T11:46:55Z; blocked 2026-07-27T11:50:43Z).~~ _(superseded 2026-07-25)_
- ~~Complete the pending live end-to-end retest by exercising `run-hourly.sh` itself, rather than only its component stages, after Peter posts a previously unused LinkedIn post link as a human-authored message in Slack channel `C0BF606R4N7`; verify both the Slack-thread output and ClickUp-task creation (Peter clarified the required test target 2026-07-27T19:10:49Z; still awaiting the human test link as of 2026-07-27T19:16:31Z).~~ _(superseded 2026-07-25)_
- Complete and verify the live end-to-end test of `run-hourly.sh`, confirming both the Slack-thread output and ClickUp-task creation for the human-posted LinkedIn link; Peter confirmed the previously blocking link was posted, so the test is no longer waiting on him (2026-07-27T19:19:31Z).
