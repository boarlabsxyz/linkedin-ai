# Requirements — conversational ledger

Standing requirements and corrections extracted from task transcripts by the
context archivist (`.claude/hooks/context.py`). Append-only; newest at the
bottom. A superseded entry is struck through, never deleted.

## 2026-07-18 — The task explored moving LinkedIn analytics to ClickUp, corrected a task-type naming hallucination, created an MCP gap ticket, migrated comment automation to GitHub Actions, and diagnosed a failed weekly scrape.

_transcript: 20260718-190554-372ee591-next-task-is-it-use-clicku-as-source-of.md_

- The LinkedIn Grafana dashboard’s durable source of truth should move from `./dashboards/li-stats/` to the ClickUp Posts list `901524524871`, including the post data captured at publication time (2026-07-18T19:05:54Z).
- Use the ClickUp MCP-gap ticket format as the template for future connector feature requests: concise User perspective (real query and expected result), LLM perspective (reasoning/tool path), and Technical perspective (API); before creating the ticket, ask Codex whether it aligns with the task and how it can be simplified (2026-07-20T10:12:46Z; confirmed as the template 2026-07-20T10:32:29Z).
- [correction] Never infer a ClickUp custom task type’s name from `custom_item_id`: Peter confirmed that the workspace has no task type named “LI Post,” so live ClickUp structure must be inspected and unresolved names reported as unknown rather than invented (2026-07-20T09:52:57Z).

## 2026-07-25 — The task began planning changes to LinkedIn post generation so completed posts go to ClickUp and LinkedIn links shared by humans in Slack are also processed, using iterative Codex review and testing.

_transcript: 20260725-150058-15284ba4-the-linkedin-post-generation-i-need-two.md_

- Generated outputs must be completed LinkedIn posts—not post ideas—and must be written to ClickUp list/view `901524736848` at `https://app.clickup.com/90151491867/v/l/6-901524736848-1` (requested 2026-07-25T15:22:48Z).
- On each call, the process must read new messages since the previous call in Slack channel `C0BF606R4N7`, process messages authored by users rather than bots, and extract and parse any LinkedIn-post links they contain (requested 2026-07-25T15:22:48Z).
- Before implementation, create a plan and run up to three Codex gap-review iterations, incorporating relevant recommendations and telling Codex which earlier recommendations were implemented or rejected and why; stop early when no relevant recommendations remain (requested 2026-07-25T15:22:48Z).
- Implement and test the solution, keep fixing it until all issues are resolved, save both the original and actual/as-built plans under `doc/context/plans/`, then run up to five Codex solution-critique rounds using both plans and implement every relevant improvement, stopping early when none remain (requested 2026-07-25T15:22:48Z).
- Monthly LinkedIn comment analytics must show an explicit `0` for a calendar month in which Peter posted no comments, rather than omitting that month from the dashboard (requested 2026-08-09T19:06:12Z).
