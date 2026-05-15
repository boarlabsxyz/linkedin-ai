#!/usr/bin/env python3
"""Convert YouTube auto-caption VTT to a deduplicated `[HH:MM:SS] text` transcript.

Usage:
    clean-vtt.py <input.vtt> [output.txt]

If output is omitted, writes to stdout.

YouTube auto-captions have rolling overlap (each line repeats in the next cue),
so we dedupe identical text lines. We also strip inline `<HH:MM:SS.mmm>` word-level
timing tags and `<c>...</c>` color tags.
"""

import re
import sys


def clean(vtt_text: str) -> str:
    seen: set[str] = set()
    out: list[str] = []
    for block in re.split(r"\n\n+", vtt_text):
        lines = block.strip().split("\n")
        if not lines or "-->" not in lines[0]:
            continue
        m = re.match(r"(\d{2}:\d{2}:\d{2})\.\d+ -->", lines[0])
        if not m:
            continue
        start = m.group(1)
        text = " ".join(lines[1:])
        text = re.sub(r"<\d{2}:\d{2}:\d{2}\.\d+>", "", text)
        text = re.sub(r"</?c>", "", text).strip()
        if not text or text in seen:
            continue
        seen.add(text)
        out.append(f"[{start}] {text}")
    return "\n".join(out) + "\n"


def main() -> int:
    if len(sys.argv) < 2 or len(sys.argv) > 3:
        print("Usage: clean-vtt.py <input.vtt> [output.txt]", file=sys.stderr)
        return 64
    with open(sys.argv[1], encoding="utf-8") as f:
        result = clean(f.read())
    if len(sys.argv) == 3:
        with open(sys.argv[2], "w", encoding="utf-8") as f:
            f.write(result)
    else:
        sys.stdout.write(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
