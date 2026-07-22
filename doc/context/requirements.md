# Requirements — conversational ledger

Standing requirements and corrections extracted from task transcripts by the
context archivist (`.claude/hooks/context.py`). Append-only; newest at the
bottom. A superseded entry is struck through, never deleted.

## 2026-07-18 — The task explored moving LinkedIn analytics to ClickUp, corrected a task-type naming hallucination, created an MCP gap ticket, migrated comment automation to GitHub Actions, and diagnosed a failed weekly scrape.

_transcript: 20260718-190554-372ee591-next-task-is-it-use-clicku-as-source-of.md_

- The LinkedIn Grafana dashboard’s durable source of truth should move from `./dashboards/li-stats/` to the ClickUp Posts list `901524524871`, including the post data captured at publication time (2026-07-18T19:05:54Z).
- Use the ClickUp MCP-gap ticket format as the template for future connector feature requests: concise User perspective (real query and expected result), LLM perspective (reasoning/tool path), and Technical perspective (API); before creating the ticket, ask Codex whether it aligns with the task and how it can be simplified (2026-07-20T10:12:46Z; confirmed as the template 2026-07-20T10:32:29Z).
- [correction] Never infer a ClickUp custom task type’s name from `custom_item_id`: Peter confirmed that the workspace has no task type named “LI Post,” so live ClickUp structure must be inspected and unresolved names reported as unknown rather than invented (2026-07-20T09:52:57Z).
