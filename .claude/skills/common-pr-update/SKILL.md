---
name: common-pr-update
description: Create or update a pull request with conventional commit formatting and GitHub issue integration. Use this skill whenever the user wants to create a PR, update a PR, open a pull request, says "make a PR", "create PR", "update the PR", or is ready to submit their branch for review. Handles title formatting, body generation, issue linking, and bidirectional PR-issue references.
---

# PR Update

Create or update a pull request following conventional commit guidelines, with automatic GitHub issue integration.

## Analysis

1. Check current changes:
   ```bash
   git --no-pager status
   git --no-pager diff origin/main...HEAD
   ```
2. Analyze the changes to understand their purpose and impact
3. Search project documentation for GitHub issue references (format: `**Issue Reference**: [#<number>](...)`)

## PR Format

### Title
- One sentence, max 120 characters
- Use conventional commit prefix: `fix:`, `feat:`, `docs:`, `chore:`, `refactor:`, `perf:`, `test:`, `ci:`, `build:`, `style:`
- `BREAKING CHANGE` for breaking API changes

### Body
- Bullet list of changes (no blank lines between bullets, no introductory text)
- `**Related Issue**: #<number>: <issue_title>` if an issue reference was found
- Brief explanation of why the PR is needed
- Do not repeat the title in the body

**Example with issue:**
```
feat: Add user authentication to login page

- Add password validation function
- Create JWT token generation
- Add error handling for invalid credentials

**Related Issue**: #37: GitHub Reader Step Implementation

This feature is necessary to secure user accounts and prevent unauthorized access.
```

## Creating the PR

Use `--body-file` to avoid escape issues:
```bash
mkdir -p ./tmp
cat > ./tmp/pr-body.md << 'EOF'
- First change
- Second change

**Related Issue**: #42: Some issue title

Brief explanation of why.
EOF

gh pr create --title "feat: your title" --body-file ./tmp/pr-body.md
rm ./tmp/pr-body.md
```

Or update an existing PR:
```bash
gh pr edit --title "feat: updated title" --body-file ./tmp/pr-body.md
```

## Post-PR Actions (when issue reference found)

After creating or updating the PR:

1. Check if the PR link is already in the issue body
2. If not, update the issue body to include: `**Related PR**: #<pr_number>: <pr_title>`
3. If already mentioned, update the existing PR link with the current title
4. Apply appropriate labels (e.g., `in-progress`, `has-pr`)

## Rules

- Use `./tmp/` for temporary files and clean up afterwards
- Always use `--body-file` instead of `--body` with `gh pr create`
- Check if a PR already exists for the current branch before creating a new one
