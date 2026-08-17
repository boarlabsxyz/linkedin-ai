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
- ~~Complete and verify the live end-to-end test of `run-hourly.sh`, confirming both the Slack-thread output and ClickUp-task creation for the human-posted LinkedIn link; Peter confirmed the previously blocking link was posted, so the test is no longer waiting on him (2026-07-27T19:19:31Z).~~ _(superseded 2026-07-25)_
- ~~Implement the requested `linkedin-comment-hourly` delivery change: suppress per-post Slack parent/thread messages, keep the final status message, and format it with links to the created ClickUp tickets; no implementation occurred before the transcript stopped at clarification (requested 2026-08-13T07:47:42Z; still pending 2026-08-13T08:35:11Z).~~ _(superseded 2026-07-25)_
- Pending Peter’s authorization, run `DRY_RUN=1 run-hourly.sh` to complete live end-to-end verification of the ClickUp-only delivery change, confirming that drafting invokes `addTaskComment` and that a second run adopts the existing task without duplicating comments; unit checks did not cover these paths, and the run creates real tickets (reported 2026-08-13T09:28:18Z).
- ~~Prepare the six requested Slack feature-request ticket drafts from ClickUp template `86cau7dc5`; the transcript ended before any drafts were produced (requested 2026-08-14T06:44:36Z).~~ _(superseded 2026-07-25)_
- The requested Slack feature-request tickets now exist in ClickUp with their tags and corrected descriptions verified, so the earlier ticket-drafting follow-up is complete (verified 2026-08-14T06:55:05Z).
- Gather the transcript through Playwright as Peter explicitly requested; the delivered transcript was obtained with yt-dlp, and the assistant confirmed Playwright was never used (requested 2026-08-15T08:12:44Z; omission confirmed 2026-08-15T08:23:52Z).
- Identify the owning email or username for the Soniox API key through a path other than the tested 404 API endpoints; Peter explicitly requested it, but the batch completed without resolving it because a paid probe showed the account was funded (requested 2026-08-16T10:19:54Z; unresolved 2026-08-16T11:06:41Z).
- ~~Manually rename the TrueBDD Doc at `https://app.clickup.com/90151491867/v/dc/2kyq568v-29695` from `Инвестиційний ресерч: TrueBDD (pre-seed, spec-as-source AI-розробка)` to `Инвестиционный ресерч: TrueBDD (pre-seed, spec-as-source AI-разработка)`; its body is correct, but the available ClickUp connector had no rename tool (deferred 2026-08-16T12:03:03Z).~~ _(superseded 2026-07-25)_
- ~~Complete and verify the final Module 5 page in the replacement AgriTech Doc `https://app.clickup.com/90151491867/v/dc/2kyq568v-30235`; the transcript ended while that page was still appending (requested 2026-08-17T17:00:56Z; incomplete 2026-08-17T18:38:20Z).~~ _(superseded 2026-07-25)_
- After validating the replacement copies, manually delete the two pages prefixed `DELETE ME —` from the new TrueBDD Doc `https://app.clickup.com/90151491867/v/dc/2kyq568v-30255` and delete the obsolete AgriTech and TrueBDD Docs `2kyq568v-29675` and `2kyq568v-29695`; the connector could not delete or move Docs/pages, so deleting the old TrueBDD Doc replaces renaming it (deferred 2026-08-17T18:38:20Z).
- Diagnose and repair the existing `linkedin-stats` comment scraper so comment metrics and engagement events are populated again; the `/feed/update/<urn>/` rendering failure was explicitly left unfixed in this task (deferred 2026-08-17T18:38:20Z).
- The replacement AgriTech Doc at `https://app.clickup.com/90151491867/v/dc/2kyq568v-30235` is complete and independently verified: every page, including Module 5, matched its source, closing the earlier completion follow-up (verified 2026-08-17T18:50:43Z).
