# Priority Writing Guide

## Title Format: Problem → Solution

Every priority title starts with the problem being solved, then the solution direction after `→`.

**Good examples:**
- `Team velocity declining due to unclear ownership → Define RACI for each workstream`
- `Customer churn spiking in first 30 days → Redesign onboarding flow`
- `Deploy pipeline takes 45 min → Parallelize CI stages`

**Bad examples:**
- `Fix onboarding` (no problem statement)
- `Blocked by team` (blame, not a problem description)
- `Work on CI/CD` (too vague, no problem or direction)

## Non-Violent Communication (NVC)

Describe problems as unmet needs, not blame. This matters because priorities are shared artifacts — accusatory framing creates resistance instead of alignment.

| Instead of... | Write... |
|---|---|
| "Blocked by the design team" | "Product iterations stalling due to async handoff gaps between design and engineering" |
| "QA is too slow" | "Release cadence limited by manual testing bottleneck" |
| "Management won't approve" | "Initiative stalled — decision criteria unclear to stakeholders" |

## Filtering: What Counts as a Priority?

**Keep** items where the user is:
- Driving the initiative or decision
- Directly contributing to the outcome
- Accountable for results

**Skip** items that are:
- Purely operational (status updates, scheduling, routine delegation)
- Social/chitchat
- Someone else's responsibility with no action needed from the user

When in doubt, present it to the user in the validation step — they decide what's noise vs signal.

## Description Format

- Use markdown in the task description
- All subtasks live in the markdown description (no ClickUp subtasks) — this keeps priorities scannable as single cards
- Group related findings under the meeting they came from
