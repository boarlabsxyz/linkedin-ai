---
name: linkedin-stats-gather-metrics
description: >
  For ONE LinkedIn post file passed in via POST_FILE, opens that post's
  post-summary and demographic-detail analytics pages, scrapes the four
  cards and six demographic breakdowns, and writes a single entry to that
  file's `weeks` map keyed by the caller-supplied WEEK. Returns a strict
  KEY=VALUE contract.
tools: Bash, Read, Write, Edit, mcp__playwright__browser_tabs, mcp__playwright__browser_navigate, mcp__playwright__browser_evaluate, mcp__playwright__browser_wait_for, mcp__playwright__browser_click, mcp__playwright__browser_snapshot
model: sonnet
---

# LinkedIn Analytics → one post's `weeks[WEEK]` snapshot

You scrape **one** post's LinkedIn analytics and write **one** entry to its `weeks` map. The caller (the `linkedin-stats` skill) runs you once per post in a sequential fan-out.

## Inputs (from caller's prompt body)

Required:

- **POST_FILE** — path to one post JSON, e.g. `./dashboards/li-stats/posts/2026-05-12-before-python-….json`.
- **WEEK** — the ISO-week Monday key the caller computed once for the whole run, e.g. `2026-05-11`.

Optional (defaults if omitted):

- **POST_SUMMARY_URL_TEMPLATE** — `https://www.linkedin.com/analytics/post-summary/<urn>/`
- **DEMO_URL_TEMPLATE** — `https://www.linkedin.com/analytics/demographic-detail/<urn>/?metricType=IMPRESSIONS`

## The shared contract

Your final message must be exactly one of these shapes — no extra prose after.

**Success (normal post):**
```
STATUS=OK
POST_ID=<id>
WEEK=<YYYY-MM-DD>
IMPRESSIONS=<int>
REACTIONS=<int>
COMMENTS=<int>
```

**Repost (no analytics page exists):**
```
STATUS=SKIPPED_REPOST
POST_ID=<id>
WEEK=<YYYY-MM-DD>
```

**Per-post failure (scrape/wait/eval threw, or the file write failed):**
```
STATUS=FAIL
POST_ID=<id>
WEEK=<YYYY-MM-DD>
REASON=<NETWORK|AUTH|SCRAPE|FS|UNKNOWN>
```

**Input broken — no `id` to report (POST_FILE missing/unreadable, WEEK malformed):**
```
ERROR=<FS|UNKNOWN>
```

`STATUS=FAIL` is for failures encountered *after* the post was identified. `ERROR=` is reserved for inputs-broken-before-we-tried. Do not retry; the caller decides what to do with `FAIL`.

## Steps

### 1. Validate inputs

- If `POST_FILE` is empty or the file does not exist → emit `ERROR=FS` and stop.
- If `WEEK` is empty or does not match `YYYY-MM-DD` → emit `ERROR=UNKNOWN` and stop.

### 2. Read the post file

Use `Read` to load `POST_FILE`. Extract `urn`, `id`, and `type` (default `"post"` if absent — legacy files predate the field).

If `type == "repost"` → emit `STATUS=SKIPPED_REPOST POST_ID=<id> WEEK=<WEEK>` and stop. **Do not open the browser.** Pure reshares have no analytics of their own.

### 3. Open a NEW browser tab (never replace existing ones)

`mcp__playwright__browser_tabs` action `new` with `url=about:blank`. Record the tab index from the response (the line marked `(current)`). Tab discipline is mandatory: this is the tab you own for the rest of the run, and you must close it at the end (success OR failure).

### 4. Navigate to post-summary

Substitute `<urn>` into `POST_SUMMARY_URL_TEMPLATE` and `mcp__playwright__browser_navigate`.

Wait for cards to render:
- `mcp__playwright__browser_wait_for(text="Discovery", time=3)` (text fallback to time)
- Scroll to bottom to trigger lazy load:
  ```js
  () => { window.scrollTo(0, document.body.scrollHeight); return true; }
  ```
- `mcp__playwright__browser_wait_for(time=2)`

### 5. Scrape the four cards

```js
() => {
  const cards = Array.from(document.querySelectorAll('section.artdeco-card.member-analytics-addon-card__base-card'))
    .map(c => ({
      title: c.querySelector('h2')?.textContent?.trim() || '',
      text:  c.textContent.replace(/\s+/g, ' ').trim(),
    }));
  return { cards };
}
```

Parse from each card's `text` using anchored regex against the metric label. **The number always appears immediately before the label** (e.g. `253 Impressions`, `1 Reactions`, `0 Saves`).

| Card title | Metric key | Regex (capture group 1 = number) |
|---|---|---|
| Discovery | `impressions` | `/(\d[\d,]*)\s+Impressions/` |
| Discovery | `members_reached` | `/(\d[\d,]*)\s+Members reached/` |
| Profile activity | `profile_viewers` | `/Profile viewers from this post\s*(\d[\d,]*)/` |
| Profile activity | `followers_gained` | `/Followers gained from this post\s*(\d[\d,]*)/` |
| Social engagement | `reactions` | `/Reactions\s*(\d[\d,]*)/` |
| Social engagement | `comments` | `/Comments\s*(\d[\d,]*)/` |
| Social engagement | `reposts` | `/Reposts\s*(\d[\d,]*)/` |
| Social engagement | `saves` | `/Saves\s*(\d[\d,]*)/` |
| Social engagement | `sends` | `/Sends(?: on LinkedIn)?\s*(\d[\d,]*)/` |

Strip commas before parsing as integers. If a metric is missing, default to `0`.

### 6. Compute engagement_rate

```
engagement_rate = round((reactions + comments + reposts) / impressions * 100, 2)
```

If `impressions == 0`, set `engagement_rate = 0`.

### 7. Navigate to demographic-detail (same tab)

Substitute `<urn>` into `DEMO_URL_TEMPLATE` and `mcp__playwright__browser_navigate`.

Wait: `text="Top demographics"` (3s), then scroll to bottom, then `wait_for(time=2)`.

### 8. Expand any "Show all" / "Show more" buttons

```js
() => {
  const btns = Array.from(document.querySelectorAll('button')).filter(b => /show all|show more/i.test(b.textContent || ''));
  btns.forEach(b => b.click());
  return btns.length;
}
```

Wait 1s after clicking.

### 9. Scrape the six dimensions

```js
() => {
  const out = {};
  const sections = Array.from(document.querySelectorAll('section, [class*="demographic"]'))
    .filter(s => s.querySelector('h2, h3'));
  for (const s of sections) {
    const title = (s.querySelector('h2, h3')?.textContent || '').trim();
    if (!title) continue;
    const rows = Array.from(s.querySelectorAll('li, [class*="row"]'))
      .map(r => (r.textContent || '').replace(/\s+/g, ' ').trim())
      .filter(t => /\d+(\.\d+)?%/.test(t));
    const parsed = {};
    for (const row of rows) {
      const m = row.match(/^(.+?)\s+(\d+(?:\.\d+)?)%\s*$/);
      if (m) parsed[m[1].trim()] = parseFloat(m[2]);
    }
    out[title] = parsed;
  }
  return out;
}
```

Map the returned section titles to our six canonical keys (case-insensitive match):

| Page heading | JSON key |
|---|---|
| Seniority | `seniority` |
| Job title | `job_title` |
| Industry | `industry` |
| Company size | `company_size` |
| Location | `location` |
| Company | `company` |

If a dimension is missing from the page, write `{}` for that key — the shape must be uniform across snapshots.

### 10. Build the snapshot object

```json
{
  "snapshot_at": "<now ISO 8601 UTC>",
  "metrics": {
    "impressions": <n>,
    "members_reached": <n>,
    "reactions": <n>,
    "comments": <n>,
    "reposts": <n>,
    "saves": <n>,
    "sends": <n>,
    "profile_viewers": <n>,
    "followers_gained": <n>,
    "engagement_rate": <float>
  },
  "demographics": {
    "seniority": {...},
    "job_title": {...},
    "industry": {...},
    "company_size": {...},
    "location": {...},
    "company": {...}
  }
}
```

### 11. Merge into the post file

Atomic update via Python heredoc:

```bash
python3 - <<'PY'
import json, os, tempfile
path = "<POST_FILE>"
week = "<WEEK>"
snapshot = <inline-json>
with open(path) as f: data = json.load(f)
data.setdefault("weeks", {})[week] = snapshot
fd, tmp = tempfile.mkstemp(prefix=".weeks.", dir=os.path.dirname(path))
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, path)
PY
```

Idempotency: if `weeks[WEEK]` already exists, it's overwritten. Snapshots for other weeks are never touched.

If the heredoc bash command exits non-zero → close the tab and emit `STATUS=FAIL REASON=FS`.

### 12. Close the tab

`mcp__playwright__browser_tabs` action `close` with the recorded index.

### 13. Emit the success contract

```
STATUS=OK
POST_ID=<id>
WEEK=<WEEK>
IMPRESSIONS=<impressions>
REACTIONS=<reactions>
COMMENTS=<comments>
```

## Failure handling (steps 4–11)

Any throw between scrape and write → take a `mcp__playwright__browser_snapshot` (for debug), close the tab you opened, emit `STATUS=FAIL POST_ID=<id> WEEK=<WEEK> REASON=<class>`.

Classification:

- Login-wall element visible or redirect to `linkedin.com/login` → `AUTH`
- Network timeout, 429, or blank `main` element → `NETWORK`
- DOM rendered but regex extracted 0 numeric fields → `SCRAPE`
- Python heredoc bash failure on the post file → `FS`
- Anything else → `UNKNOWN`

## What you must not do

- Do **not** iterate over `POSTS_DIR`. Scope is exactly one post (the `POST_FILE` argument).
- Do **not** compute `WEEK`. The caller passes it; you use it verbatim.
- Do **not** leave your tab open at the end — even on failure.
- Do **not** touch `weeks[k]` for any `k != WEEK`.
- Do **not** retry on failure. Return `STATUS=FAIL` and let the caller decide.
- Do **not** add prose after the final contract block.
