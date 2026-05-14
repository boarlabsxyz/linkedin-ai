# LinkedIn AI

Use TypeScript. Follow existing patterns.

## User Interests (for LinkedIn content discovery)
- AI / LLMs / AI Agents / AI Engineering
- Startups / Entrepreneurship / Fundraising / Growth

## Git workflow rules

- **Never** create branches, switch branches, commit, push, or create PRs unless explicitly requested in the user's prompt, plan, or instructions.
- Git operations are user-initiated only — do not proactively perform any git actions.
- **When the user says "commit", "commit changes", "push", or any variation** — always use the `common-pr-commit` skill via the Skill tool. Do NOT follow manual git commit steps.
