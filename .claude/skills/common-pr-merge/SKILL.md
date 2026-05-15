---
name: common-pr-merge
description: Merge the current branch's PR using squash merge, delete the remote branch, switch to main, pull latest, and clean up the local branch. Use this skill whenever the user wants to merge a PR, finish a branch, land changes, or says things like "merge this", "land it", "ship it", "merge the PR", or "we're done with this branch".
---

# PR Merge

Merge the current branch's pull request and clean up afterwards. This is a squash merge workflow that keeps the main branch history clean.

## Steps

1. Get the current branch name so you can clean it up later
2. Run `gh pr merge --squash --delete-branch` to squash-merge and delete the remote branch
3. Detect whether the main branch is called `main` or `master`
4. Check out the main branch and pull latest changes
5. Delete the local feature branch

## Implementation

Run the bundled merge script from the project root:

```bash
./.claude/skills/common-pr-merge/merge.sh
```

The script does all of the steps above and exits non-zero if the merge itself fails. "Local branch already deleted" is treated as success — `gh pr merge --delete-branch` may have already removed the local feature branch if you were sitting on it.

The script is checked in at `.claude/skills/common-pr-merge/merge.sh`; the logic lives there rather than inline so Claude Code's bash parser sees a single command (matchable against the allowlist) instead of a multi-line script with command substitution.

## Requirements

- GitHub CLI (`gh`) must be installed and authenticated
- The current branch must have an open pull request
