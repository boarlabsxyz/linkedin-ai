#!/bin/bash
# Stop hook: walk the transcript JSONL since the last real user prompt
# and append every assistant text block + every AskUserQuestion Q&A,
# in chronological order, to the current history file.
#
# Other tool calls (Bash, Read, Edit, Write, …) are intentionally skipped.
# Always emits hookSpecificOutput.systemMessage with a one-line trace.
set -u
source "${CLAUDE_PROJECT_DIR}/.claude/hooks/lib.sh"

DIAG=""
step() { DIAG+="$1"$'\n'; }

emit_and_exit() {
  DIAG="$DIAG" python3 - <<'PY'
import json, os
msg = "[history hook]\n" + os.environ["DIAG"].rstrip()
print(json.dumps({"systemMessage": msg}))
PY
  exit 0
}

if [ ! -f "$SENTINEL" ]; then
  step "  no sentinel — skipped (history capture not active)"
  emit_and_exit
fi

name=$(current_history_file)
if [ -z "$name" ]; then
  step "  ERROR: sentinel empty"
  emit_and_exit
fi
HISTORY_FILE="${HISTORY_DIR}/${name}"

payload=$(cat)
transcript=$(printf '%s' "$payload" | python3 -c "
import json, sys
print(json.load(sys.stdin).get('transcript_path',''), end='')
" 2>/dev/null)

if [ -z "$transcript" ] || [ ! -f "$transcript" ]; then
  step "  ERROR: no transcript_path in Stop payload (got: '$transcript')"
  emit_and_exit
fi

# Retry: Claude Code's transcript writes can lag the Stop hook spawn by
# tens-to-hundreds of ms, so a fresh entry from the just-finished turn
# may not be on disk yet. Poll up to ~1s before giving up.
count=0
attempts=0
while [ "$attempts" -lt 10 ]; do
  count=$(dump_turn_to_history "$transcript" "$HISTORY_FILE" 2>/dev/null)
  count=${count:-0}
  [ "$count" -gt 0 ] 2>/dev/null && break
  attempts=$((attempts + 1))
  sleep 0.1
done
case "$count" in ''|*[!0-9]*) count=0 ;; esac

if [ "$count" -eq 0 ]; then
  step "  nothing to log since last user prompt (waited ${attempts}×100ms)"
  emit_and_exit
fi

step "  Saved $count entries → $name"
emit_and_exit
