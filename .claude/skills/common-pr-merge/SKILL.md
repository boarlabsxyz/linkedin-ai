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

Run these commands in sequence. Stop and report if the merge itself fails — but treat "local branch already deleted" as success (not an error). `gh pr merge --delete-branch` may delete the local feature branch if you're sitting on it, so check before deleting.

```bash
CURRENT_BRANCH=$(git branch --show-current)

gh pr merge --squash --delete-branch

MAIN_BRANCH="main"
if git show-ref --verify --quiet refs/heads/master; then
    MAIN_BRANCH="master"
fi

git checkout $MAIN_BRANCH
git pull origin $MAIN_BRANCH

if git show-ref --verify --quiet "refs/heads/$CURRENT_BRANCH"; then
    git branch -D $CURRENT_BRANCH
else
    echo "Local branch '$CURRENT_BRANCH' already deleted"
fi
```

## Requirements

- GitHub CLI (`gh`) must be installed and authenticated
- The current branch must have an open pull request
