#!/usr/bin/env bash
# Generic cron entrypoint for launchd LaunchAgents that need to always run the
# latest origin/main of this repo.
#
# Usage:  cron-wrapper.sh <target-script> [args...]
# Assumes CWD is set (by launchd's WorkingDirectory) to the worker/ clone root.
#
# Invariant: every fire hard-resets the working copy to origin/main. Any local
# edits under worker/ are silently discarded. Peter should never edit worker/
# directly — it's a runtime mirror, not a workspace.
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $0 <target-script> [args...]" >&2
    exit 64
fi

TARGET=$1
shift

# Sync to origin/main. If the working tree is on a different branch, or dirty,
# or ahead/behind — all replaced by origin/main HEAD.
git fetch origin main --quiet
git checkout -q -B main origin/main 2>/dev/null || git checkout -q main
git reset --hard origin/main --quiet

# Chain to the requested job. Fresh copy is now on disk.
exec "$TARGET" "$@"
