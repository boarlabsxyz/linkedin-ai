# User Story Writing Guide

Based on Mountain Goat Software / Mike Cohn methodology.

## Core Principles

- **Template:** `As a <specific user type>, I want <goal> so that <reason>`
- **Be specific** about the user type — not generic "user" but "developer", "junior consultant", etc.
- **Three C's:** Card (short description), Conversation (details emerge through discussion), Confirmation (acceptance criteria)
- **Keep stories short** — they are placeholders for conversations, not full specifications
- **Large stories are epics** — split them into smaller stories
- **Add detail through acceptance criteria**, not longer descriptions

## Title Format

Short, meaningful title (3-6 words, imperative or noun phrase).

**Good:** `CI/CD Pipeline Setup`, `UI Testing Infrastructure`, `Code Quality Automation`
**Bad:** `As a developer, I want a CI/CD pipeline, so that code changes are automatically tested and deployed` (the full story goes in the description, not the title)

## Description Structure

Write in English using markdown:

1. **User story line** with bold markers: `**As a** <who>, **I want** <what>, **so that** <why>.`
2. Context and rationale from the discussion (plain paragraphs).
3. **Acceptance Criteria** — use markdown checklist (`- [ ]` items). Each criterion is a testable condition that must be true when the story is complete.

## Type A: User Stories (multi-step efforts)

When multiple related action items form a single effort, combine them into a user story with subtasks.

- **Assignee:** Determine from the transcript who is responsible. Use `clickup_resolve_assignees` to convert name to ClickUp user ID.
- **Subtasks:** Concrete, actionable items in imperative form (e.g., "Consolidate code into one repository"). Order logically.
- **Tags:** 1-3 topic/category tags (e.g., `ci-cd`, `testing`, `infrastructure`)
- **Source:** `Sync MM.DD` matching the transcript date

## Type B: Standalone Tasks (single action items)

Independent items that don't belong to a larger effort stay as individual tasks.

- **Title:** Imperative form (e.g., "Read XP Programming book")
- **Description:** What needs to be done and why. English, markdown.
- **No subtasks**
- **Tags and Source:** Same rules as Type A

## Classification Heuristic

- If 2+ action items from the transcript are related, group them as Type A
- Skip non-actionable items — general discussion, opinions, chitchat without a clear deliverable
- Prefer user stories over flat tasks when grouping makes sense
