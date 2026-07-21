# Facts — conversational ledger

Dated empirical discoveries about external systems, extracted from task
transcripts by the context archivist (`.claude/hooks/context.py`). Append-only;
newest at the bottom.

## 2026-07-21 — The task ran the LinkedIn comment-hourly drafting and Slack-delivery stages from an existing gather contract without repeating feed gathering.

_transcript: 20260721-075639-a8bbd0c0-run-linkedin-comment-hourly-using-the-pr.md_

- The Google Drive REST bridge returned `500 unauthorized_client` for all prep-refs downloads across fresh tokens and multiple documents; this was verified as systemic rather than document-specific, so drafting fell back to the existing local cache and kept its manifest unchanged for retry (2026-07-21T08:19:17Z).
