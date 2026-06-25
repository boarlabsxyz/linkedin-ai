#!/bin/bash
# SessionStart hook: on a fresh conversation (startup, clear), drop the
# sentinel so the next UserPromptSubmit creates a new history file.
# On resume/compact, leave the sentinel intact (continue the same file).
set -u
source "${CLAUDE_PROJECT_DIR}/.claude/hooks/lib.sh"

payload=$(cat)
source=$(printf '%s' "$payload" | python3 -c "import json,sys; print(json.load(sys.stdin).get('source',''))" 2>/dev/null)

case "$source" in
  startup|clear)
    rm -f "$SENTINEL"
    ;;
esac
exit 0
