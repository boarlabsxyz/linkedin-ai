---
name: awesome-sync-tasks
description: >
  Process [AWESOME] Sync call transcripts from Google Drive, extract user stories and tasks,
  and create/update them in ClickUp. Use when user says "process AWESOME sync", "extract tasks
  from AWESOME call", "AWESOME transcript to ClickUp", "create tasks from latest sync", or
  mentions any [AWESOME] Sync meeting — even if they just say "process the latest sync" or
  "what came out of the AWESOME call."
---

# AWESOME Sync → ClickUp Tasks

Read the latest [AWESOME] Sync transcript from Google Drive, extract user stories/tasks, and create or update them in ClickUp with tags and source tracking.

## Constants

- **Google Drive folder ID:** `14I2yIWsoZ5BTJD-Sqk9nVkU23iC11eYJ` (Single Transcripts)
- **Transcript naming pattern:** `[AWESOME] Sync — MM.DD — Transcript`
- **ClickUp Space ID:** `901510520225` (AWESOME)
- **ClickUp List ID:** `901522119783` (Tasks)
- **ClickUp Custom Field "Source" ID:** `3d8e441e-e225-4a1d-9601-5e4bf0cf7851` (Short Text)
- **Transcript language:** Russian/Ukrainian. Translate to English accurately, using standard technical terms. Transliterate names consistently (e.g., always "Petro" not sometimes "Peter").

## Flow

### Step 1: Find the latest transcript

1. Use `listFolderContents(folderId="14I2yIWsoZ5BTJD-Sqk9nVkU23iC11eYJ", includeSharedDrives=true)`.
2. Files follow `[AWESOME] Sync — MM.DD — Transcript`. Sort by date, pick most recent.
3. If the user specifies a date, use that transcript instead.

### Step 2: Read the transcript

Use `readGoogleDoc(documentId=<id>, format="text")`. The transcript has a header (topic, date), body (speaker + timestamp + spoken text in Russian/Ukrainian), and footer (meeting resources — ignore).

### Step 3: Extract user stories and tasks

Analyze the transcript and extract actionable items into two types:

- **Type A: User Stories** — multi-step efforts where 2+ related items form a single initiative. Short title (3-6 words), user story description, subtasks, assignee, tags.
- **Type B: Standalone Tasks** — independent single action items. Short title, description, assignee, tags.

For the full user story writing methodology (Mike Cohn, acceptance criteria, examples of good vs bad), see `references/user-story-guide.md`.

**General rules:**
- Skip non-actionable items (general discussion, opinions, chitchat).
- Prefer user stories over flat tasks when grouping makes sense.
- Assignees: determine from transcript, resolve with `clickup_resolve_assignees`.
- Tags: 1-3 per item. Source: `Sync MM.DD` matching transcript date.

### Step 4: Retrieve existing tags from ClickUp

Search existing tasks in the AWESOME space, collect tags in use. Prefer existing tags for new tasks; only propose new tags when no existing tag fits.

### Step 5: Search for existing related tasks

For each extracted item, use `clickup_search(keywords=<keywords>, filters={location: {projects: ["901510520225"]}})`. If a match covers the same topic, mark as UPDATE. Otherwise, CREATE.

### Step 6: Present tasks for validation

Present each task one by one via `AskUserQuestion`. The validation step prevents noisy transcript artifacts from polluting ClickUp — human judgment is essential for distinguishing real work from discussion noise.

For each item show: title, action (CREATE/UPDATE), assignee, description, subtasks (if Type A), tags (mark existing vs new), source. Options: Approve / Edit / Skip.

Complete validation for all tasks before executing, so the user can redirect or merge items that were miscategorized.

### Step 7: Execute approved tasks

1. Resolve all assignees via `clickup_resolve_assignees`.
2. **CREATE (Type A):** Create parent task with `clickup_create_task` (name, list `901522119783`, description, tags, assignees, custom_fields with Source). Then create each subtask with `parent` set to the new task ID.
3. **CREATE (Type B):** Same as Type A parent, no subtasks.
4. **UPDATE:** Append context under `## Update from Sync MM.DD` heading. Add new tags via `clickup_add_tag_to_task`. Update Source field.

If a ClickUp API call fails, report the error for that task and continue with the rest.

### Step 8: Summary

Present: total created, total updated, total skipped, links to all created/updated tasks.
