---
name: awesome-sync-tasks
description: >
  Process [AWESOME] Sync call transcripts from Google Drive, extract user stories and tasks,
  and push them to ClickUp. Trigger when user mentions AWESOME sync tasks, AWESOME transcript,
  processing AWESOME call, or wants to extract tasks from an AWESOME sync meeting.
---

# AWESOME Sync → ClickUp Tasks

Read the latest [AWESOME] Sync transcript from Google Drive, extract user stories/tasks, and create or update them in ClickUp with tags and source tracking.

## Constants

- **Google Drive folder ID:** `14I2yIWsoZ5BTJD-Sqk9nVkU23iC11eYJ` (Single Transcripts)
- **Transcript naming pattern:** `[AWESOME] Sync — MM.DD — Transcript`
- **ClickUp Space ID:** `901510520225` (AWESOME)
- **ClickUp List ID:** `901522119783` (Tasks)
- **ClickUp Custom Field "Source" ID:** `3d8e441e-e225-4a1d-9601-5e4bf0cf7851` (Short Text)
- **Transcript language:** Russian/Ukrainian

## Full Flow

Execute these steps in order. Do NOT skip the validation step.

### Step 1: Find the latest transcript

1. Use `listFolderContents(folderId="14I2yIWsoZ5BTJD-Sqk9nVkU23iC11eYJ", includeSharedDrives=true)` to list all files.
2. Files follow the pattern `[AWESOME] Sync — MM.DD — Transcript`.
3. Sort by date in the filename (MM.DD) and pick the most recent one.
4. If the user specifies a particular date, use that transcript instead.

### Step 2: Read the transcript

1. Use `readGoogleDoc(documentId=<id>, format="text")` to get the full content.
2. The transcript format is:
   - Header: `Topic: [AWESOME] Sync`, `Date: <date>`, `Transcription`
   - Body: Speaker name + timestamp, then their spoken text in Russian/Ukrainian
   - Footer: Meeting Resources links (ignore these)

### Step 3: Extract user stories and tasks

Analyze the transcript content and extract actionable items. There are TWO types of items:

#### User Story Writing Rules (based on Mountain Goat Software / Mike Cohn)
- Template: `As a <specific user type>, I want <goal> so that <reason>`
- Be specific about the user type — not generic "user" but "developer", "junior consultant", etc.
- Three C's: Card (short description), Conversation (details emerge through discussion), Confirmation (acceptance criteria)
- Keep stories short — they are placeholders for conversations, not full specifications
- Large stories are epics — split them into smaller stories
- Add detail through acceptance criteria, not longer descriptions

#### Type A: User Stories (multi-step efforts)
When multiple related action items form a single effort, combine them into a **user story with subtasks**.

- **Name:** Short, meaningful title (3-6 words, imperative or noun phrase)
  - Good: `CI/CD Pipeline Setup`, `UI Testing Infrastructure`, `Code Quality Automation`
  - Bad: `As a developer, I want a CI/CD pipeline, so that code changes are automatically tested and deployed`
- **Description:** Write in English using markdown. Structure:
  1. **User story line** with bold markers: `**As a** <who>, **I want** <what>, **so that** <why>.`
  2. Context and rationale from the discussion (plain paragraphs).
  3. **Acceptance Criteria** — use markdown checklist (`- [ ]` items). Each criterion is a testable condition that must be true when the story is complete.
- **Assignee:** Determine from the transcript who is responsible for executing this work. Use `clickup_resolve_assignees` to convert their name/email to a ClickUp user ID.
- **Subtasks:** List the individual steps/deliverables that make up this user story. Each subtask should be:
  - A concrete, actionable item (imperative form, e.g. "Consolidate code into one repository")
  - Ordered logically (sequential steps where applicable)
- **Proposed tags:** 1-3 topic/category tags (e.g. `ci-cd`, `testing`, `infrastructure`)
- **Source value:** `Sync MM.DD` matching the transcript date

#### Type B: Standalone Tasks (single action items)
Items that are independent and don't belong to a larger effort stay as individual tasks.

- **Name:** Short, clear task title in English (imperative form, e.g. "Read XP Programming book")
- **Description:** What needs to be done and why. Write in English. Use markdown formatting.
- **Assignee:** Determine from the transcript who is responsible. Use `clickup_resolve_assignees` to convert their name/email to a ClickUp user ID.
- **Subtasks:** None
- **Proposed tags:** 1-3 topic/category tags
- **Source value:** `Sync MM.DD` matching the transcript date

#### General rules:
1. **Skip non-actionable items** — general discussion, opinions, or chitchat without a clear deliverable.
2. **Prefer user stories over flat tasks** — if 2+ action items are related, group them.

### Step 4: Retrieve existing tags from ClickUp

1. Use `clickup_search` to find existing tasks in the AWESOME space.
2. Collect all tags currently in use across those tasks.
3. When proposing tags for new tasks, prefer existing tags where they fit.
4. Only propose new tags when no existing tag is appropriate.

### Step 5: Search ClickUp for existing related tasks

For each extracted user story/task:

1. Use `clickup_search(keywords=<task keywords>, filters={location: {projects: ["901510520225"]}})` to find potentially matching tasks.
2. A task is a match if it covers the same topic/effort (use judgment — exact name match is not required).
3. If a match is found, the action will be "UPDATE" — append new context from this sync call.
4. If no match, the action will be "CREATE".

### Step 6: Present tasks for validation (MANDATORY)

Present EACH task to the user one by one using `AskUserQuestion`. For each task show:

**For user stories (Type A):**
```
User Story: <short title>
Action: CREATE new / UPDATE existing (link: <url>)
Assignee: <name>
Description:
  **As a** <who>, **I want** <what>, **so that** <why>.
  <context paragraph>
  Acceptance Criteria:
  - [ ] <criterion 1>
  - [ ] <criterion 2>
Subtasks:
  1. <subtask 1>
  2. <subtask 2>
  3. <subtask 3>
Tags: <tag1>, <tag2> (existing) | <tag3> (new)
Source: Sync MM.DD
```

**For standalone tasks (Type B):**
```
Task: <name>
Action: CREATE new / UPDATE existing (link: <url>)
Assignee: <name>
Description: <description>
Tags: <tag1>, <tag2> (existing) | <tag3> (new)
Source: Sync MM.DD
```

Options for each task:
- **Approve** — proceed as shown
- **Edit** — user provides changes (then re-present the edited version)
- **Skip** — do not create/update this task

Do NOT proceed to Step 7 until ALL tasks have been validated.

### Step 7: Execute approved tasks

For each approved task, in order:

1. **Create new tags** if any approved task uses a tag that doesn't exist yet. Note: ClickUp tags are created by adding them to a task — there is no separate "create tag" API. The first task that uses a new tag will create it.

2. **Resolve assignees:** Before creating tasks, call `clickup_resolve_assignees` once with all unique assignee names from approved tasks. Cache the resulting user IDs for use in task creation.

3. **For CREATE actions (Type A — User Stories):**
   - First, create the parent task using `clickup_create_task` with:
     - `name`: short task title (3-6 words)
     - `list_id`: `901522119783`
     - `markdown_description`: user story (with bold `**As a**`, `**I want**`, `**so that**`) + context + acceptance criteria (`- [ ]` checklist)
     - `tags`: array of tag names
     - `assignees`: array of resolved user ID strings
     - `custom_fields`: `[{"id": "3d8e441e-e225-4a1d-9601-5e4bf0cf7851", "value": "Sync MM.DD"}]`
   - Then, for each subtask, create it using `clickup_create_task` with:
     - `name`: subtask title (imperative form)
     - `list_id`: `901522119783`
     - `parent`: ID of the parent task just created

4. **For CREATE actions (Type B — Standalone Tasks):**
   - Use `clickup_create_task` with:
     - `name`: task name
     - `list_id`: `901522119783`
     - `markdown_description`: task description
     - `tags`: array of tag names
     - `assignees`: array of resolved user ID strings
     - `custom_fields`: `[{"id": "3d8e441e-e225-4a1d-9601-5e4bf0cf7851", "value": "Sync MM.DD"}]`

5. **For UPDATE actions:**
   - Use `clickup_update_task` with:
     - `task_id`: existing task ID
     - `markdown_description`: existing description + new context appended under a `## Update from Sync MM.DD` heading
   - Add any new tags using `clickup_add_tag_to_task`
   - Update the Source custom field to append the new sync date (e.g. `Sync 02.26, Sync 03.12`)

### Step 8: Summary

After all tasks are processed, present a summary:
- Total tasks created
- Total tasks updated
- Total tasks skipped
- Links to all created/updated tasks
