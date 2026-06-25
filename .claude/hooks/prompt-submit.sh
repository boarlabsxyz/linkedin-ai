#!/bin/bash
# UserPromptSubmit hook: append the user's prompt to the current history
# file. If no file exists yet (first prompt of a fresh session), derive a
# slug from this prompt and create the file.
set -u
source "${CLAUDE_PROJECT_DIR}/.claude/hooks/lib.sh"

payload=$(cat)
prompt=$(printf '%s' "$payload" | python3 -c "
import json, sys
d = json.load(sys.stdin)
# Claude Code uses 'prompt'; tolerate 'user_message' too.
print(d.get('prompt') or d.get('user_message') or '', end='')
" 2>/dev/null)

[ -z "$prompt" ] && exit 0

if [ ! -f "$SENTINEL" ]; then
  start_history_file "$prompt" >/dev/null
fi

append_to_history "user" "$prompt"
exit 0
