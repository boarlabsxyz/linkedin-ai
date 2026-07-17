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
    # Drop untracked leftovers from an interrupted fire (reset --hard keeps them),
    # matching cron-wrapper.sh so a repaired worker starts pristine.
    git -C "$WORKER_DIR" clean -fd
fi

# 3. Ensure scripts are executable
chmod +x "$WORKER_DIR/scripts/cron-wrapper.sh" \
         "$WORKER_DIR/scripts/slack-heartbeat.sh" \
         "$WORKER_DIR/scripts/install-heartbeat.sh" \
         "$WORKER_DIR/.claude/skills/linkedin-comment-hourly/run-hourly.sh" 2>/dev/null || true

# 3a. Mark the worker path as trusted so .claude/settings.json permissions are
# honored inside the cron `claude -p`. Without this, launchd runs log a warning
# ("Ignoring N permissions.allow entries") and skills like linkedin-comment-hourly
# lose their allowlist. `claude -p --dangerously-skip-permissions` still works,
# but silencing the warning avoids confusing failure diagnosis.
python3 - "$WORKER_DIR" <<'PY'
import json, os, sys
p = os.path.expanduser('~/.claude.json')
worker = sys.argv[1]
try:
    with open(p) as f: data = json.load(f)
except FileNotFoundError:
    data = {}
projects = data.setdefault('projects', {})
entry = projects.setdefault(worker, {})
if not entry.get('hasTrustDialogAccepted'):
    entry['hasTrustDialogAccepted'] = True
    with open(p, 'w') as f: json.dump(data, f, indent=2)
    print(f'✓ Marked {worker} as trusted in ~/.claude.json')
else:
    print(f'  {worker} already trusted in ~/.claude.json')
PY

# 4. Copy plist from the freshly-synced worker/ to LaunchAgents
mkdir -p "$HOME/Library/LaunchAgents"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
cp "$WORKER_DIR/scripts/$LABEL.plist" "$PLIST_DEST"
echo "✓ Plist installed at $PLIST_DEST"

# 5. Reload. `enable` first: a previously disabled service (launchctl print
# lists it under disabled) makes bootstrap fail with error 119, so a plain
# bootout+bootstrap is NOT idempotent from that state. The enable override
# persists across bootstraps.
launchctl enable "gui/$(id -u)/$LABEL"
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
