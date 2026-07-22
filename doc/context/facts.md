# Facts — conversational ledger

Dated empirical discoveries about external systems, extracted from task
transcripts by the context archivist (`.claude/hooks/context.py`). Append-only;
newest at the bottom.

## 2026-07-21 — The task ran the LinkedIn comment-hourly drafting and Slack-delivery stages from an existing gather contract without repeating feed gathering.

_transcript: 20260721-075639-a8bbd0c0-run-linkedin-comment-hourly-using-the-pr.md_

- The Google Drive REST bridge returned `500 unauthorized_client` for all prep-refs downloads across fresh tokens and multiple documents; this was verified as systemic rather than document-specific, so drafting fell back to the existing local cache and kept its manifest unchanged for retry (2026-07-21T08:19:17Z).

## 2026-07-16 — The task audited the LinkedIn comment-generation workflow, backfilled full post text into analytics and Grafana, and investigated missing July 2026 dashboard data.

_transcript: 20260716-130906-3b7e2b57-i-wanto-change-way-to-create-comments-to.md_

- The cached ICP reference was nearly identical to the True BDD factsheet, so the comment pipeline's intended ICP-fit check provided no independent audience signal; whether the configured Google Doc ID was wrong or the upstream ICP document had been overwritten remained unresolved (2026-07-16T13:11:28Z).

## 2026-07-18 — The task mapped the artifacts used for LinkedIn comment drafting and verified whether ClickUp’s API can create custom fields on the Posts list.

_transcript: 20260718-063319-58efb3a9-lets-take-a-look-at-what-artifacts-are-u.md_

- As of 2026-07-18, ClickUp’s public API could read existing custom-field definitions and set or remove field values on tasks, but could not create or edit custom-field definitions; new fields therefore had to be created in the ClickUp UI first (2026-07-18T07:00:50Z).

## 2026-07-18 — The task explored moving LinkedIn analytics to ClickUp, corrected a task-type naming hallucination, created an MCP gap ticket, migrated comment automation to GitHub Actions, and diagnosed a failed weekly scrape.

_transcript: 20260718-190554-372ee591-next-task-is-it-use-clicku-as-source-of.md_

- As of 2026-07-20, ClickUp task payloads exposed only a numeric `custom_item_id`, while the available ClickUp MCP tools and REST proxy exposed no workspace task-type registry lookup, so those tools could distinguish types by ID but could not resolve their actual names (2026-07-20T10:00:35Z).
- ClickUp has no composite/object custom-field type; nested weekly analytics must therefore be modeled as related tasks or stored as opaque JSON in a Text Area field (verified 2026-07-20T09:49:52Z).
- ClickUp’s Custom Fields by task type beta allows fields to be scoped to a custom task type instead of exposing every field across the list; Formula and List-to-List Relationship fields cannot be type-scoped (verified 2026-07-20T09:49:52Z).

## 2026-07-20 — The task implemented and live-tested a self-healing weekly LinkedIn stats pipeline, repaired the runner architecture, and merged the healed scrape and watchdog cleanup.

_transcript: 20260720-114324-f671ba95-i-want-also-to-create-make-the-workflow.md_

- The Mac Studio’s previous GitHub Actions runner binaries were x86_64-only and live Runner and Chrome processes carried Rosetta’s `P_TRANSLATED` flag; after reinstalling the arm64 runner, job Chrome ran natively and the in-job A/B confirmed the runner-only scrape slowdown disappeared (binary/process verification 2026-07-20T14:07:37Z; A/B confirmation 2026-07-20T14:30:07Z).
