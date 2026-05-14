---
name: common-pr-commit
description: Review changes, commit, push, and update the PR description. Use this skill whenever the user wants to commit code, says "commit this", "push my changes", "commit and push", or wants to save and push their work.
---

# PR Commit

Review changes, create a well-formatted commit, push, and update the PR description to reflect all commits on the branch.

## Steps

### 1. Ensure Working Branch

```bash
git rev-parse --abbrev-ref HEAD
```

If on `main`: create a new branch before proceeding. Derive the branch name from the staged changes (e.g., `feat/add-ebos-research`, `fix/update-skill`). Use kebab-case with a conventional prefix (`feat/`, `fix/`, `chore/`, `docs/`).

```bash
git checkout -b <branch-name>
```

If already on a feature branch: continue as-is.

### 2. Review Changes

```bash
git --no-pager status
git --no-pager diff
```

Review what will be committed.

### 3. Update project memory

Before staging and committing, invoke the `common-update-memory` skill to check if CLAUDE.md needs updating based on the changes. If it modifies CLAUDE.md, it will stage it automatically — the update will be included in this commit.

### 4. Stage and Commit

1. Stage changes: `git add .`
2. Create commit with a proper message (see format below)
3. Push immediately — do not ask for confirmation

## Commit Message Format

- **Title**: One sentence summary, max 120 characters
- Empty line
- **Body**: Bullet list of changes (no blank lines between bullets)

**Example:**
```
Add EBOS research files for EOS:Raw library

- Add 10 web research files covering EOS framework
- Add 6 Google Drive EBOS documents
- Update files to delete list
```

Use a temp file for multi-line messages:
```bash
mkdir -p ./tmp
{
  echo "Your commit title"
  echo ""
  echo "- First change"
  echo "- Second change"
} > ./tmp/commit-msg.txt
git commit -F ./tmp/commit-msg.txt && rm ./tmp/commit-msg.txt && git push origin HEAD
```

### 5. Update PR

After pushing, invoke the `common-pr-update` skill to update the PR title and description to reflect all commits on the branch.

## Rules

- Always push after committing — never leave commits unpushed
- Always update the PR description after pushing
- Never use `git commit --no-verify`
- Use `./tmp/` for any temporary files and clean them up afterwards
- If push fails, resolve immediately
