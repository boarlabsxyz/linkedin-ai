---
name: weekly-priorities
description: >
  Process meeting transcripts from the previous week to extract and update personal priorities
  in ClickUp. Use whenever the user mentions weekly priorities, weekly review, "process last
  week's calls", "update my priorities from meetings", "what should I focus on this week",
  "sync priorities with ClickUp", processing weekly transcripts, or wants to turn last week's
  meetings into actionable priorities — even if they don't say "weekly priorities" explicitly.
---

# Weekly Priorities from Transcripts

Download previous week's meeting transcripts, extract priority-relevant topics, and update/create priorities in ClickUp — with human validation at every step.

## Constants

- **ClickUp Priorities List ID:** `901522189872`
- **Transcript download folder:** `./weekly-priorities/raw/` (gitignored)
- **Priority title format:** `Problem statement → Solution direction`
- **Transcript language:** Russian/Ukrainian (output in English). Translate substance accurately; use English technical terms when they exist.

For priority writing rules (NVC, title format, filtering heuristics), see `references/priority-writing-guide.md`.

## Flow

### Step 1: Determine date range

Compute the previous Monday–Sunday range based on the current date.
- If today is Monday, "previous week" = the Mon–Sun that just ended (7–13 days ago).
- Otherwise, go back to the most recent completed Mon–Sun.

Present the range to the user via `AskUserQuestion` and confirm before proceeding.

### Step 2: Fetch calendar events

1. Use `gcal_list_events(timeMin, timeMax, maxResults=250)`. Paginate with `pageToken` if needed.
2. Filter locally:
   - **Accepted only:** User's response is `accepted` or user is organizer.
   - **Already finished:** `end.dateTime` is in the past.
   - **Exclude all-day events** (holidays/OOO).
   - **Exclude solo events** (no other attendees).
3. Present filtered list and ask user to confirm or remove events.

### Step 3: Find and download transcripts

Search Google Drive for each event's transcript, match, and download. For detailed matching rules (fuzzy matching, date tolerance, bracket handling), see `references/transcript-matching.md`.

Report how many transcripts were found vs missing, then proceed with available ones.

### Step 4: Load existing priorities from ClickUp

1. Use `clickup_search(query="", filters={location: {lists: ["901522189872"]}})` to get current priorities.
2. For each task, `clickup_get_task(task_id)` to get the full description.
3. Present the numbered list to the user for context.

### Step 5: Process transcripts

For each transcript, identify discussion topics focusing on:
- What **problems** are being discussed (what's going wrong, what needs to change)?
- What initiatives or projects are being worked on?
- What decisions were made?

For each topic, extract: a short label, the core problem, key evidence, and which existing priority it maps to (if any). Skip operational items, chitchat, and items outside the user's responsibility.

After processing all transcripts, aggregate findings and output two categories:

**Category A: Updates to existing priorities** — which priority, new information, source transcripts.
**Category B: Potential new priorities** — problem statement, evidence, preliminary title.

### Step 6: Human validation (one by one)

Present each finding via `AskUserQuestion`. This step catches false positives and ensures only real priorities reach ClickUp — auto-generated priorities are often noisy, so human judgment is essential.

**Category A** (existing updates): Show the priority, source transcripts, new findings, and proposed additions. Options: Approve / Edit / Skip.

**Category B** (potential new): Show the problem, evidence, and ask if it's a real priority or operational noise. Options: Priority / Operational (skip) / Part of existing priority / Need more context.

For new priorities, iterate on the title and description until approved. Use `Problem → Solution` format per `references/priority-writing-guide.md`.

Complete validation for all items before executing — the user needs the full picture before any ClickUp writes happen.

### Step 7: Execute approved changes

**Updates:** Append new findings under a `## Update from week of MM.DD–MM.DD` heading using `clickup_update_task`.

**Creates:** Use `clickup_create_task` with the approved title, list ID `901522189872`, and markdown description. No ClickUp subtasks — everything stays in the description.

If a ClickUp API call fails, report the error for that specific task and continue with the remaining approved changes.

### Step 8: Summary

Present: transcripts processed, events with no transcript, priorities updated (with links), new priorities created (with links), items skipped.
