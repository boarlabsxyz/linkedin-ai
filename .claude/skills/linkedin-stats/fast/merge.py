#!/usr/bin/env python3
"""File merge helper for the fast scrape path.

All dashboards/li-stats/*.json writes go through THIS script, not Node.
Rationale (verified empirically): Python json.load -> json.dump(indent=2,
ensure_ascii=False) round-trips every existing file byte-for-byte, while
Node JSON.stringify rewrites historical float lexemes (50.0 -> 50), churning
diffs. The merge bodies below are ported verbatim from the agent specs:
  - post:     linkedin-stats-gather-metrics.md step 12
  - account:  linkedin-stats-gather-account.md step 5 (made atomic)
  - comments: linkedin-stats-gather-comments-out.md step 4

stdin: one JSON payload {"mode": "post"|"account"|"comments", ...}
stdout: KEY=VALUE result lines. Exit 0 on success, 1 on failure.
"""
import datetime
import json
import os
import sys
import tempfile
from urllib.parse import quote


def write_atomic(path, data):
    dir_ = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".fast-merge.", suffix=".json", dir=dir_)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def new_file(p):
    """Dump a freshly-discovered post record. Refuses to overwrite."""
    path = p["path"]
    if os.path.exists(path):
        raise SystemExit(f"refusing to overwrite existing file: {path}")
    write_atomic(path, p["record"])
    print("WRITTEN=1")


def merge_post(p):
    path, week, snapshot = p["path"], p["week"], p["snapshot"]
    with open(path) as f:
        data = json.load(f)
    text = p.get("post_text")
    if text and not data.get("text"):
        data["text"] = text
    data.setdefault("weeks", {})[week] = snapshot
    write_atomic(path, data)
    print("MERGED=1")


def merge_account(p):
    path, week, snapshot = p["path"], p["week"], p["snapshot"]
    try:
        with open(path) as f:
            data = json.load(f)
    except FileNotFoundError:
        data = {"weeks": {}}
    data.setdefault("weeks", {})[week] = snapshot
    write_atomic(path, data)
    print("MERGED=1")


def merge_comments(p):
    path, week = p["path"], p["week"]
    snapshot_cutoff_ms = p["snapshot_cutoff_ms"]
    incoming = p["incoming"]
    now_iso = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    def ms_to_iso(ms):
        return datetime.datetime.fromtimestamp(
            ms / 1000, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    def build_permalink(post_urn, comment_urn):
        return f"https://www.linkedin.com/feed/update/{post_urn}/?commentUrn={quote(comment_urn, safe='')}"

    REQUIRED = {"comment_urn", "commented_at_ms", "verb", "text",
                "comment_author_name", "comment_author_url",
                "post_urn", "post_url",
                "post_author_name", "post_author_url",
                "reactions", "replies_count", "impressions"}
    for item in incoming:
        missing = REQUIRED - set(item.keys())
        if missing:
            raise SystemExit(
                f"SCRAPE_BAD_SHAPE: item missing fields {sorted(missing)}: {item.get('comment_urn')}")

    try:
        with open(path) as f:
            data = json.load(f)
        if not isinstance(data, dict):
            data = {}
    except FileNotFoundError:
        data = {}
    comments = data.setdefault("comments", {})

    new_count = 0
    snapshotted_count = 0
    for item in incoming:
        urn = item["comment_urn"]
        if urn not in comments:
            comments[urn] = {
                "comment_urn":         urn,
                "commented_at":        ms_to_iso(item["commented_at_ms"]),
                "verb":                item["verb"],
                "text":                item["text"],
                "comment_author_name": item["comment_author_name"],
                "comment_author_url":  item["comment_author_url"],
                "post_urn":            item["post_urn"],
                "post_url":            item["post_url"],
                "post_author_name":    item["post_author_name"],
                "post_author_url":     item["post_author_url"],
                "permalink":           build_permalink(item["post_urn"], urn),
                "weeks":               {},
            }
            new_count += 1
        entry = comments[urn]
        if item["commented_at_ms"] >= snapshot_cutoff_ms:
            entry.setdefault("weeks", {})[week] = {
                "snapshot_at":   now_iso,
                "reactions":     item["reactions"],
                "replies_count": item["replies_count"],
                "impressions":   item["impressions"],
            }
            snapshotted_count += 1

    def _ms(entry):
        iso = entry.get("commented_at", "")
        try:
            d = datetime.datetime.strptime(iso.replace("Z", "+0000"), "%Y-%m-%dT%H:%M:%S%z")
            return int(d.timestamp() * 1000)
        except Exception:
            return 0

    sorted_pairs = sorted(comments.items(), key=lambda kv: _ms(kv[1]), reverse=True)
    data["comments"] = dict(sorted_pairs)
    write_atomic(path, data)
    print(f"NEW={new_count} SNAPSHOTTED={snapshotted_count}")


def main():
    payload = json.load(sys.stdin)
    mode = payload["mode"]
    if mode == "newfile":
        new_file(payload)
    elif mode == "post":
        merge_post(payload)
    elif mode == "account":
        merge_account(payload)
    elif mode == "comments":
        merge_comments(payload)
    else:
        raise SystemExit(f"unknown mode: {mode}")


if __name__ == "__main__":
    main()
