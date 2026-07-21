#!/usr/bin/env python3
"""Context archivist: distill finished task transcripts into doc/context/ ledgers.

Subcommands:
  sweep            — process every finished, unprocessed history file. Finished
                     = any tmp/history/*.md that is not the active task file
                     named in tmp/history/hook-state. Triggered in the
                     background by /new-task (after history.py rolls the state
                     file over, so the just-closed task is swept immediately);
                     safe to run manually at any time.
  process <file>   — process one history file (path or bare filename) even if
                     it is the active one; still skips if already marked done.

Per file: codex (read-only sandbox, --output-schema-forced JSON) reads the
transcript plus the existing ledgers and CLAUDE.md, and returns categorized
findings; this script renders them into doc/context/*.md and stores the raw
reply as the done-marker at tmp/history/context-processed/<file>.json. Markers
are written only on success, so a failed codex run is retried by the next
sweep. All-empty findings still mark the file done — empty is the normal case.

A flock on tmp/history/context-sweep.lock keeps concurrent sweeps from
double-appending; a second sweep exits immediately. Log: tmp/history/
context-sweep.log.
"""

import fcntl
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(
    os.environ.get("CLAUDE_PROJECT_DIR") or Path(__file__).resolve().parents[2]
).resolve()
HISTORY_DIR = REPO / "tmp" / "history"
STATE_FILE = HISTORY_DIR / "hook-state"
PROCESSED_DIR = HISTORY_DIR / "context-processed"
LOCK_FILE = HISTORY_DIR / "context-sweep.lock"
LOG_FILE = HISTORY_DIR / "context-sweep.log"
CONTEXT_DIR = REPO / "doc" / "context"
PROMPT_FILE = Path(__file__).resolve().parent / "context-prompt.md"
SCHEMA_FILE = Path(__file__).resolve().parent / "context-schema.json"
CODEX_TIMEOUT = 480

CATEGORIES = ("requirement", "decision", "correction", "fact", "follow_up")

# correction items land in requirements.md: a correction IS a requirement
# discovered the hard way (they keep a [correction] prefix for traceability).
LEDGER_FOR = {
    "requirement": "requirements.md",
    "correction": "requirements.md",
    "decision": "decisions.md",
    "fact": "facts.md",
    "follow_up": "follow-ups.md",
}

LEDGER_HEADERS = {
    "requirements.md": (
        "# Requirements — conversational ledger\n\n"
        "Standing requirements and corrections extracted from task transcripts"
        " by the\ncontext archivist (`.claude/hooks/context.py`). Append-only;"
        " newest at the\nbottom. An entry that supersedes an older one says so"
        " in its text.\n"
    ),
    "decisions.md": (
        "# Decisions — conversational ledger\n\n"
        "Choices made in conversation — what was chosen, why, and what was"
        " rejected —\nextracted from task transcripts by the context archivist"
        " (`.claude/hooks/context.py`).\nAppend-only; newest at the bottom.\n"
    ),
    "facts.md": (
        "# Facts — conversational ledger\n\n"
        "Dated empirical discoveries about external systems, extracted from"
        " task\ntranscripts by the context archivist"
        " (`.claude/hooks/context.py`). Append-only;\nnewest at the bottom.\n"
    ),
    "follow-ups.md": (
        "# Follow-ups — conversational ledger\n\n"
        "Work explicitly deferred or requested but not done in its task,"
        " extracted from\ntask transcripts by the context archivist"
        " (`.claude/hooks/context.py`).\nAppend-only; newest at the bottom."
        " Strike through or remove items once done.\n"
    ),
}


def log(msg: str) -> None:
    line = f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {msg}"
    print(line, file=sys.stderr)
    try:
        HISTORY_DIR.mkdir(parents=True, exist_ok=True)
        with LOG_FILE.open("a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def _active_file() -> str:
    try:
        return STATE_FILE.read_text().strip()
    except FileNotFoundError:
        return ""


def _finished_unprocessed() -> list:
    active = _active_file()
    out = []
    for p in sorted(HISTORY_DIR.glob("*.md")):
        if p.name == active:
            continue
        if (PROCESSED_DIR / (p.name + ".json")).exists():
            continue
        out.append(p)
    return out


def _run_codex(history_path: Path):
    """Returns the parsed findings dict, or None on any failure."""
    rel = history_path.relative_to(REPO)
    prompt = PROMPT_FILE.read_text().replace("{HISTORY_FILE}", str(rel))
    PROCESSED_DIR.mkdir(parents=True, exist_ok=True)
    out_file = PROCESSED_DIR / (history_path.name + ".reply.tmp")
    cmd = [
        "codex", "exec", "-s", "read-only", "--ephemeral",
        "-C", str(REPO),
        "--output-schema", str(SCHEMA_FILE),
        "-o", str(out_file),
        "--color", "never",
        "-",
    ]
    try:
        r = subprocess.run(
            cmd, input=prompt, capture_output=True, text=True,
            timeout=CODEX_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        log(f"codex TIMEOUT ({CODEX_TIMEOUT}s) on {history_path.name}")
        return None
    except FileNotFoundError:
        log("codex CLI not found on PATH — skipping sweep")
        return None
    if r.returncode != 0:
        tail = (r.stderr or r.stdout or "").strip()[-500:]
        log(f"codex exit {r.returncode} on {history_path.name}: {tail}")
        return None
    try:
        reply = json.loads(out_file.read_text())
    except (OSError, ValueError) as e:
        log(f"unparseable codex reply for {history_path.name}: {e}")
        return None
    finally:
        out_file.unlink(missing_ok=True)
    if not isinstance(reply, dict) or not isinstance(reply.get("task_summary"), str):
        log(f"malformed codex reply for {history_path.name}")
        return None
    for cat in CATEGORIES:
        items = reply.get(cat)
        if not isinstance(items, list) or any(not isinstance(i, str) for i in items):
            log(f"malformed category '{cat}' for {history_path.name}")
            return None
    return reply


def _entry_date(filename: str) -> str:
    m = re.match(r"(\d{4})(\d{2})(\d{2})-", filename)
    if m:
        return "-".join(m.groups())
    return time.strftime("%Y-%m-%d", time.gmtime())


def _render(reply: dict, history_filename: str) -> int:
    """Append findings to their ledgers. Returns the number of items written."""
    per_ledger = {}
    for cat in CATEGORIES:
        for item in reply[cat]:
            item = item.strip()
            if not item:
                continue
            if cat == "correction":
                item = f"[correction] {item}"
            per_ledger.setdefault(LEDGER_FOR[cat], []).append(item)
    if not per_ledger:
        return 0
    CONTEXT_DIR.mkdir(parents=True, exist_ok=True)
    heading = (
        f"## {_entry_date(history_filename)} — "
        f"{reply['task_summary'].strip() or 'untitled task'}"
    )
    for ledger, items in per_ledger.items():
        path = CONTEXT_DIR / ledger
        if not path.exists():
            path.write_text(LEDGER_HEADERS[ledger])
        block = "\n".join(f"- {i}" for i in items)
        with path.open("a") as f:
            f.write(f"\n{heading}\n\n_transcript: {history_filename}_\n\n{block}\n")
    return sum(len(v) for v in per_ledger.values())


def _mark_done(history_filename: str, reply: dict) -> None:
    PROCESSED_DIR.mkdir(parents=True, exist_ok=True)
    marker = PROCESSED_DIR / (history_filename + ".json")
    marker.write_text(json.dumps(reply, ensure_ascii=False, indent=2) + "\n")


def process_one(history_path: Path) -> bool:
    if (PROCESSED_DIR / (history_path.name + ".json")).exists():
        log(f"already processed: {history_path.name}")
        return True
    log(f"processing {history_path.name} ({history_path.stat().st_size} bytes)")
    reply = _run_codex(history_path)
    if reply is None:
        return False
    n = _render(reply, history_path.name)
    _mark_done(history_path.name, reply)
    log(f"done {history_path.name}: {n} item(s) -> doc/context/")
    return True


def sweep() -> None:
    HISTORY_DIR.mkdir(parents=True, exist_ok=True)
    lock = LOCK_FILE.open("w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log("another sweep is running — exiting")
        return
    try:
        targets = _finished_unprocessed()
        if not targets:
            return
        log(f"sweep: {len(targets)} file(s) to process")
        for p in targets:
            process_one(p)
    finally:
        lock.close()


def main() -> None:
    if len(sys.argv) < 2 or sys.argv[1] not in ("sweep", "process"):
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    if sys.argv[1] == "sweep":
        sweep()
        return
    if len(sys.argv) < 3:
        print("usage: context.py process <history-file>", file=sys.stderr)
        sys.exit(2)
    arg = Path(sys.argv[2])
    path = arg if arg.is_absolute() else (
        arg if arg.exists() else HISTORY_DIR / arg.name
    )
    if not path.exists():
        print(f"no such history file: {sys.argv[2]}", file=sys.stderr)
        sys.exit(1)
    sys.exit(0 if process_one(path.resolve()) else 1)


if __name__ == "__main__":
    main()
