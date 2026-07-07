#!/usr/bin/env bash
# One-shot installer for the slack-heartbeat LaunchAgent.
# Idempotent: safe to re-run to pick up plist changes.
set -euo pipefail

LABEL=xyz.boarlabs.slack-heartbeat
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
PLIST_SRC="$REPO_ROOT/scripts/$LABEL.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

# Ensure the shell script is executable
chmod +x "$REPO_ROOT/scripts/slack-heartbeat.sh"

# Copy plist (overwrite any prior version)
cp "$PLIST_SRC" "$PLIST_DEST"
echo "✓ Plist installed at $PLIST_DEST"

# Unload any prior version, then load
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"

if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    echo "✓ Loaded into gui/$(id -u)"
else
    echo "✗ Failed to load $LABEL" >&2
    exit 1
fi

echo
echo "Manage:"
echo "  launchctl print    gui/\$(id -u)/$LABEL     # status + config"
echo "  launchctl kickstart -k gui/\$(id -u)/$LABEL # fire it now (test)"
echo "  launchctl bootout  gui/\$(id -u)/$LABEL     # remove"
echo
echo "Logs:"
echo "  ~/Library/Logs/slack-heartbeat.out.log"
echo "  ~/Library/Logs/slack-heartbeat.err.log"
