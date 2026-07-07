#!/usr/bin/env bash
# One-shot installer for the slack-heartbeat LaunchAgent under the
# ~/cron_workers/linkedin-ai/{logs,worker} layout.
#
# Idempotent: safe to re-run to pick up plist changes or repair a broken worker.
# Runs from any clone of this repo — it clones a *fresh* copy into worker/ so
# the runtime is independent of Peter's development workspace.
set -euo pipefail

LABEL=xyz.boarlabs.slack-heartbeat
REPO_URL=${REPO_URL:-git@github.com:boarlabsxyz/linkedin-ai.git}

WORKER_ROOT="$HOME/cron_workers/linkedin-ai"
LOGS_DIR="$WORKER_ROOT/logs"
WORKER_DIR="$WORKER_ROOT/worker"

# 1. Layout
mkdir -p "$LOGS_DIR"

# 2. worker/ is a git clone. Create it or refresh it.
if [ ! -d "$WORKER_DIR/.git" ]; then
    echo "→ cloning $REPO_URL into $WORKER_DIR"
    git clone "$REPO_URL" "$WORKER_DIR"
else
    echo "→ worker/ exists; fetching + hard-resetting to origin/main"
    git -C "$WORKER_DIR" fetch origin main
    git -C "$WORKER_DIR" checkout -B main origin/main
    git -C "$WORKER_DIR" reset --hard origin/main
fi

# 3. Ensure scripts are executable
chmod +x "$WORKER_DIR/scripts/cron-wrapper.sh" \
         "$WORKER_DIR/scripts/slack-heartbeat.sh" \
         "$WORKER_DIR/scripts/install-heartbeat.sh"

# 4. Copy plist from the freshly-synced worker/ to LaunchAgents
mkdir -p "$HOME/Library/LaunchAgents"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
cp "$WORKER_DIR/scripts/$LABEL.plist" "$PLIST_DEST"
echo "✓ Plist installed at $PLIST_DEST"

# 5. Reload
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"

if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    echo "✓ Loaded into gui/$(id -u)"
else
    echo "✗ Failed to load $LABEL" >&2
    exit 1
fi

# 6. Clean up stale logs from the previous location (if user is migrating)
if [ -e "$HOME/Library/Logs/slack-heartbeat.out.log" ] \
   && [ ! -L "$HOME/Library/Logs/slack-heartbeat.out.log" ]; then
    echo "  (old logs at ~/Library/Logs/slack-heartbeat.*.log — safe to delete)"
fi

echo
echo "Layout:"
echo "  $WORKER_ROOT/"
echo "  ├── logs/           (stdout/stderr from each run)"
echo "  └── worker/         (repo clone; hard-reset to origin/main every fire)"
echo
echo "Manage:"
echo "  launchctl print    gui/\$(id -u)/$LABEL     # status + config"
echo "  launchctl kickstart -k gui/\$(id -u)/$LABEL # fire now (test)"
echo "  launchctl bootout  gui/\$(id -u)/$LABEL     # remove"
echo
echo "Logs:"
echo "  $LOGS_DIR/slack-heartbeat.out.log"
echo "  $LOGS_DIR/slack-heartbeat.err.log"
