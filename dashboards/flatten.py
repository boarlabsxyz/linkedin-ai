#!/usr/bin/env python3
"""Flatten dashboards/li-stats/{posts,account}.json into tidy CSVs both dashboards read.

Writes CSVs to two locations:
 - dashboards/li-stats/flat/    (canonical, gitignored)
 - dashboards/evidence/sources/li_stats/   (mirror; Evidence's CSV source doesn't follow symlinks)
"""
import csv, json, pathlib, shutil, sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT_DATA = HERE / "li-stats"
IN_POSTS = ROOT_DATA / "posts"
IN_ACCOUNT = ROOT_DATA / "account.json"
OUT_FLAT = ROOT_DATA / "flat"
OUT_EVIDENCE = HERE / "evidence" / "sources" / "li_stats"

METRIC_KEYS = ["impressions", "members_reached", "reactions", "comments",
               "reposts", "saves", "sends", "profile_viewers",
               "followers_gained", "engagement_rate"]

posts, post_weeks, post_demographics, account_weeks, account_demographics = [], [], [], [], []

for p in sorted(IN_POSTS.glob("*.json")):
    d = json.loads(p.read_text())
    posts.append({
        "id": d["id"],
        "posted_date": d.get("posted_date", ""),
        "type": d.get("type", "post"),
        "preview": (d.get("preview") or "")[:120],
        "post_url": d.get("post_url", ""),
    })
    for week, snap in (d.get("weeks") or {}).items():
        m = snap.get("metrics") or {}
        post_weeks.append({"id": d["id"], "week": week, **{k: m.get(k, 0) for k in METRIC_KEYS}})
        for dim, labels in (snap.get("demographics") or {}).items():
            for label, pct in (labels or {}).items():
                post_demographics.append({"id": d["id"], "week": week, "dimension": dim, "label": label, "pct": pct})

if IN_ACCOUNT.exists():
    acct = json.loads(IN_ACCOUNT.read_text())
    for week, snap in (acct.get("weeks") or {}).items():
        dash = snap.get("dashboard") or {}
        aud = snap.get("audience") or {}
        account_weeks.append({
            "week": week,
            "followers": dash.get("followers", 0),
            "post_impressions_7d": dash.get("post_impressions_7d", 0),
            "profile_viewers_90d": dash.get("profile_viewers_90d", 0),
            "search_appearances_previous_week": dash.get("search_appearances_previous_week", 0),
            "followers_delta_pct_7d": aud.get("followers_delta_pct_7d", 0),
        })
        for dim, labels in (aud.get("demographics") or {}).items():
            for label, pct in (labels or {}).items():
                account_demographics.append({"week": week, "dimension": dim, "label": label, "pct": pct})

OUT_FLAT.mkdir(parents=True, exist_ok=True)
OUT_EVIDENCE.mkdir(parents=True, exist_ok=True)

def write_csv(name, rows):
    path = OUT_FLAT / f"{name}.csv"
    if not rows:
        path.write_text("")
    else:
        with path.open("w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)
    shutil.copy2(path, OUT_EVIDENCE / f"{name}.csv")

write_csv("posts", posts)
write_csv("post_weeks", post_weeks)
write_csv("post_demographics", post_demographics)
write_csv("account_weeks", account_weeks)
write_csv("account_demographics", account_demographics)

print(f"posts={len(posts)} post_weeks={len(post_weeks)} post_demographics={len(post_demographics)} account_weeks={len(account_weeks)} account_demographics={len(account_demographics)}", file=sys.stderr)
print(f"wrote to: {OUT_FLAT}/ and {OUT_EVIDENCE}/", file=sys.stderr)
