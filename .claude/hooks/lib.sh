#!/bin/bash
# Shared helpers for the conversation-history hooks.
# All paths are relative to ${CLAUDE_PROJECT_DIR}.

HISTORY_DIR="${CLAUDE_PROJECT_DIR}/doc/history"
TMP_DIR="${CLAUDE_PROJECT_DIR}/tmp"
SENTINEL="${TMP_DIR}/history-current"

# Defensive: if CLAUDE_PROJECT_DIR isn't set (e.g., hook invoked
# manually), bail out instead of creating /doc/history at filesystem
# root.
if [ -z "${CLAUDE_PROJECT_DIR:-}" ]; then
  echo "history-hooks: CLAUDE_PROJECT_DIR not set, skipping" >&2
  exit 0
fi

mkdir -p "$HISTORY_DIR" "$TMP_DIR"

slugify() {
  printf '%s' "$1" \
    | head -c 120 \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9' '-' \
    | sed -E 's/-+/-/g; s/^-//; s/-$//' \
    | cut -c1-40 \
    | sed -E 's/-$//'
}

current_history_file() {
  [ -f "$SENTINEL" ] && cat "$SENTINEL"
}

start_history_file() {
  local first_prompt="$1"
  local ts slug name
  ts=$(date -u +"%Y%m%d-%H%M%S")
  slug=$(slugify "$first_prompt")
  [ -z "$slug" ] && slug="msg"
  name="${ts}-${slug}.md"
  printf '%s' "$name" > "$SENTINEL"
  : > "${HISTORY_DIR}/${name}"
  printf '%s' "$name"
}

append_to_history() {
  local heading="$1" body="$2" name
  name=$(current_history_file) || return 1
  [ -z "$name" ] && return 1
  {
    printf '## %s\n\n' "$heading"
    printf '%s\n\n' "$body"
  } >> "${HISTORY_DIR}/${name}"
}

# Walk the transcript JSONL since the most recent *real* user prompt
# (tool_results are also typed "user" — they must be skipped) and APPEND
# every captured entry to the given history file in chronological order.
#
# What gets captured per entry, written as `## <heading>\n\n<body>\n\n`:
#   - assistant text       → heading="claude",          body=text
#   - AskUserQuestion call → heading="claude (asked)",  body=formatted questions
#   - AskUserQuestion ans  → heading="user (answered)", body=formatted answers
# Other tool_use / tool_result blocks are skipped (Bash, Read, Edit, Write, …).
#
# Echoes the number of entries appended on stdout (0 = nothing to do).
dump_turn_to_history() {
  local transcript="$1" history_file="$2"
  [ -f "$transcript" ] || return 1
  [ -n "$history_file" ] || return 1
  python3 - "$transcript" "$history_file" <<'PY'
import json, re, sys
path = sys.argv[1]
entries = []
with open(path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except Exception:
            continue

def content_of(e):
    c = (e.get("message") or {}).get("content")
    if c is None:
        c = e.get("content")
    return c or []

def is_real_user_prompt(e):
    if e.get("type") != "user":
        return False
    c = content_of(e)
    if isinstance(c, str):
        return True
    if isinstance(c, list):
        return not any(
            isinstance(b, dict) and b.get("type") == "tool_result" for b in c
        )
    return False

last_real_user = -1
for i, e in enumerate(entries):
    if is_real_user_prompt(e):
        last_real_user = i

# Build a lookup of AskUserQuestion tool_use id → questions array,
# so when we see a tool_result later we can reconstruct the Q&A.
auq_inputs = {}
for e in entries[last_real_user + 1:]:
    c = content_of(e)
    if not isinstance(c, list):
        continue
    for b in c:
        if (isinstance(b, dict) and b.get("type") == "tool_use"
                and b.get("name") == "AskUserQuestion"):
            auq_inputs[b.get("id")] = (b.get("input") or {}).get("questions") or []

def format_questions(questions):
    out = []
    for q in questions:
        qt = (q.get("question") or "").strip()
        if not qt:
            continue
        out.append("- " + qt)
        for opt in (q.get("options") or []):
            lbl = (opt.get("label") or "").strip()
            dsc = (opt.get("description") or "").strip()
            if lbl and dsc:
                out.append("  - " + lbl + " — " + dsc)
            elif lbl:
                out.append("  - " + lbl)
    return "\n".join(out)

def format_answers(questions, result_text):
    # Result format observed:
    #   "Your questions have been answered: \"Q1\"=\"A1\", \"Q2\"=\"A2\". You can now continue..."
    out = []
    for q in questions:
        qt = (q.get("question") or "").strip()
        if not qt:
            continue
        m = re.search(r'"' + re.escape(qt) + r'"\s*=\s*"([^"]*)"', result_text or "")
        ans = m.group(1) if m else "<skipped>"
        out.append("- " + qt + "\n  → " + ans)
    return "\n".join(out)

history_path = sys.argv[2]
records = []
for e in entries[last_real_user + 1:]:
    etype = e.get("type")
    c = content_of(e)
    if etype == "assistant":
        if isinstance(c, str):
            c = [{"type": "text", "text": c}]
        if not isinstance(c, list):
            continue
        for b in c:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "text":
                text = (b.get("text") or "").strip()
                if text:
                    records.append(("claude", text))
            elif b.get("type") == "tool_use" and b.get("name") == "AskUserQuestion":
                questions = (b.get("input") or {}).get("questions") or []
                body = format_questions(questions)
                if body:
                    records.append(("claude (asked)", body))
    elif etype == "user":
        if not isinstance(c, list):
            continue
        for b in c:
            if not (isinstance(b, dict) and b.get("type") == "tool_result"):
                continue
            tu_id = b.get("tool_use_id")
            if tu_id not in auq_inputs:
                continue
            result_content = b.get("content")
            if isinstance(result_content, list):
                result_text = "".join(
                    (x.get("text") or "") for x in result_content
                    if isinstance(x, dict) and x.get("type") == "text"
                )
            else:
                result_text = result_content or ""
            body = format_answers(auq_inputs[tu_id], result_text)
            if body:
                records.append(("user (answered)", body))

with open(history_path, "a") as f:
    for heading, body in records:
        f.write(f"## {heading}\n\n{body}\n\n")

sys.stdout.write(str(len(records)))
PY
}
