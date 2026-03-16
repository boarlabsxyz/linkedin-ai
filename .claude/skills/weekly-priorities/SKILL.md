---
name: weekly-priorities
description: >
  Process meeting transcripts from the previous week to update personal priorities in ClickUp.
  Trigger when user mentions weekly priorities, weekly review, priority processing,
  processing weekly transcripts, updating priorities from meetings, or "what am I working on."
---

# Weekly Priorities from Transcripts

Download previous week's meeting transcripts, extract priority-relevant topics, and update/create priorities in ClickUp — with human validation at every step.

## Constants

- **ClickUp Priorities List ID:** `901522189872`
- **Transcript download folder:** `./weekly-priorities/raw/` (gitignored)
- **Priority title format:** `Problem statement → Solution direction`
- **Transcript language:** Russian/Ukrainian (output in English)

## Rules

1. **Non-violent communication** — describe problems as unmet needs, not blame. Say "not growing due to tensions between…" NOT "blocked by team."
2. **Problem → Solution title format** — every priority title starts with the problem being solved, then the solution direction after `→`.
3. **No ClickUp subtasks** — all subtasks live in the markdown description only.
4. **Human decides what's a priority vs operational noise** — the skill proposes, user disposes.
5. **Multiple transcripts can feed one priority** — aggregate findings before presenting.
6. **Transcripts with no relevant content** — report briefly, move on.
7. **Identify the PROBLEM from transcripts** — not just the topic. What is going wrong or what needs to change?

## Full Flow

Execute these steps in order. Do NOT skip the validation step (Step 6).

### Step 1: Determine date range

Compute the previous Monday–Sunday range based on the current date.

- If today is Monday, "previous week" = the Mon–Sun that just ended (7–13 days ago).
- Otherwise, go back to the most recent completed Mon–Sun.

Store as ISO strings: `timeMin = "YYYY-MM-DDT00:00:00Z"` and `timeMax = "YYYY-MM-DDT23:59:59Z"`.

Present the range to the user and confirm before proceeding using `AskUserQuestion`:
```
Date range: Monday <date> – Sunday <date>
Is this correct?
Options: Yes / Adjust dates
```

### Step 2: Fetch calendar events

1. Use `gcal_list_events(timeMin=<timeMin>, timeMax=<timeMax>, maxResults=250)` to get ALL events for the week.
2. Paginate with `pageToken` if there are more results.
3. Filter results locally:
   - **Accepted only:** User's response status is `accepted` OR user is the organizer.
   - **Already finished:** `end.dateTime` is in the past relative to now.
   - **Exclude all-day events:** No `dateTime` in `start` (these are usually holidays/OOO).
   - **Exclude solo events:** Events with no other attendees (personal blocks, focus time).
4. Present the filtered event list to the user:
   ```
   Found <N> calls you attended last week:
   1. <event summary> — <date, time>
   2. <event summary> — <date, time>
   ...
   ```
5. Ask user to confirm or remove any events before searching for transcripts.

### Step 3: Find and download transcripts

For each event from Step 2:

1. Search Google Drive with multiple naming patterns:
   - `searchGoogleDocs(searchQuery="<event summary> Transcript", searchIn="name", maxResults=10)`
   - `searchGoogleDocs(searchQuery="<event summary> Transcription", searchIn="name", maxResults=10)`
   - If event summary contains brackets like `[Project]`, also try without the brackets.

2. Match transcripts to events:
   - Fuzzy-match event summary against document name.
   - Date in document name should be within 1 day of event date.
   - If multiple transcripts match one event, pick the one with the closest date match.

3. Download each matched transcript:
   - `readGoogleDoc(documentId=<id>, format="text")`
   - Save to `./weekly-priorities/raw/<YYYY-MM-DD>-<event-slug>.txt`

4. Report to user:
   ```
   Transcripts found: <Y> out of <N> events

   Missing transcripts for:
   - <event name> (<date>)
   - <event name> (<date>)

   Proceeding with <Y> transcripts.
   ```

### Step 4: Load existing priorities from ClickUp

1. Use `clickup_search(query="", filters={location: {lists: ["901522189872"]}})` to retrieve all current priority tasks from the list.
2. For each task found, use `clickup_get_task(task_id=<id>)` to get the full description.
3. Build an in-memory priority registry:
   ```
   Priority 1: <title>
     URL: <clickup url>
     Description: <current markdown description>

   Priority 2: <title>
     ...
   ```
4. Present the numbered list to the user so they have context:
   ```
   Current priorities in ClickUp:
   1. <priority title> — <clickup link>
   2. <priority title> — <clickup link>
   ...
   ```

### Step 5: Process transcripts one by one

For EACH downloaded transcript:

1. Read the local file from `./weekly-priorities/raw/`.
2. Identify discussion topics — focus on:
   - What PROBLEMS are being discussed (what's going wrong, what needs to change)?
   - What initiatives or projects are being worked on?
   - What decisions were made?
3. For each topic, extract:
   - A short topic label
   - The core problem being discussed
   - Key evidence (quotes or paraphrases from transcript)
   - Which existing priority (from Step 4) this maps to, if any
4. Apply filtering rules:
   - **Skip** purely operational items (status updates, scheduling, delegated tasks with no strategic content)
   - **Skip** chitchat and social discussion
   - **Skip** items that are not the user's personal responsibility
   - **Keep** items where the user is driving, deciding, or directly contributing
5. After processing ALL transcripts, aggregate findings:
   - If the same topic appears across multiple transcripts, merge under one entry
   - Track which transcripts contributed (for source attribution)

Output two categories:

**Category A: Updates to existing priorities**
- Which priority it maps to (from Step 4 registry)
- What new information or subtasks were found
- Which transcripts contributed

**Category B: Potential new priorities**
- The problem statement as extracted
- Evidence from transcripts
- A preliminary "Problem → Solution" title formulation

### Step 6: Human validation — priority by priority (MANDATORY — do NOT skip)

Present findings one by one using `AskUserQuestion`. Process Category A first, then Category B.

#### For Category A (existing priority updates):

```
Priority Update: <existing priority title>
ClickUp: <task URL>
Source transcripts: <meeting name 1> (<date>), <meeting name 2> (<date>)

New findings:
- <finding 1>
- <finding 2>

Proposed addition to description:
- <new subtask or insight>

Options: Approve / Edit / Skip
```

- If **Approve:** Mark for execution in Step 7.
- If **Edit:** Ask what to change, apply edits, re-present until approved or skipped.
- If **Skip:** Move to next item.

#### For Category B (potential new priorities):

```
New Topic Detected
Source transcripts: <meeting name 1> (<date>), <meeting name 2> (<date>)

Problem identified: <problem statement>
Evidence: "<key quote or paraphrase>"

Is this a real priority or operational?
Options: Priority / Operational (skip) / Part of existing priority / Need more context
```

- If **Priority:**
  1. Propose a title in "Problem statement → Solution direction" format.
  2. Ask user to approve or reword (iterate until approved).
  3. Propose initial description with markdown subtask list.
  4. Ask user to approve or edit (iterate until approved).
  5. Mark for creation in Step 7.

- If **Operational (skip):** Move to next item.

- If **Part of existing priority:** Ask which one, then treat as Category A update for that priority.

- If **Need more context:** Show more details from the transcript (longer quotes, surrounding discussion), then re-ask.

**CRITICAL:** Do NOT proceed to Step 7 until ALL items have been validated.

### Step 7: Execute approved changes

**For existing priority UPDATES:**
1. Use `clickup_get_task(task_id=<id>)` to get current description.
2. Append new findings under a `## Update from week of MM.DD–MM.DD` heading.
3. Use `clickup_update_task(task_id=<id>, markdown_description=<updated description>)`.

**For new priority CREATES:**
1. Use `clickup_create_task` with:
   - `name`: the approved "Problem → Solution" title
   - `list_id`: `901522189872`
   - `markdown_description`: the approved description (markdown subtask list)
   - No ClickUp subtasks — everything stays in the description

### Step 8: Summary

Present a final report:
```
Weekly Priority Processing Complete
Week of: <MM.DD> – <MM.DD>

Transcripts processed: <N>
Events with no transcript: <list>

Priorities updated: <count>
- <priority title> — <clickup link>

New priorities created: <count>
- <priority title> — <clickup link>

Items skipped as operational: <count>
Items skipped by user: <count>
```
