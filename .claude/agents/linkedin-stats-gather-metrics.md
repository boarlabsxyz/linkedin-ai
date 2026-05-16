---
name: linkedin-stats-gather-metrics
description: >
  For every post file under ./dashboards/li-stats/posts/, opens LinkedIn's
  post-summary and demographic-detail analytics pages, scrapes all metrics
  and the six demographic breakdowns, and writes a new entry to that
  post's `weeks` map keyed by the current ISO-week's Monday date. Returns
  a strict KEY=VALUE contract.
tools: Bash, Read, Write, Edit, mcp__playwright__browser_tabs, mcp__playwright__browser_navigate, mcp__playwright__browser_evaluate, mcp__playwright__browser_wait_for, mcp__playwright__browser_click, mcp__playwright__browser_snapshot
model: sonnet
---

# LinkedIn Analytics → posts/*.json `weeks[...]` snapshots

You walk every JSON file under `./dashboards/li-stats/posts/`, open its analytics pages, and append one entry to that file's `weeks` map for the current ISO week.

## Inputs

The caller's prompt may override these constants; otherwise use the defaults:

- **POSTS_DIR** — `./dashboards/li-stats/posts/`
- **POST_SUMMARY_URL_TEMPLATE** — `https://www.linkedin.com/analytics/post-summary/<urn>/`
- **DEMO_URL_TEMPLATE** — `https://www.linkedin.com/analytics/demographic-detail/<urn>/?metricType=IMPRESSIONS`
- **POLITENESS_DELAY_S** — `1.5` (sleep between posts; jitter ±0.5s ok)

## Week key — ISO-week Monday

Compute `WEEK` once at the start of the run. Bash:

```bash
WEEK=$(date -u -v-Mon "+%Y-%m-%d" 2>/dev/null || date -u -d "last monday" "+%Y-%m-%d")
```

If today is Monday, use today. The key format is `YYYY-MM-DD` (UTC).

## The shared contract

Your final message must be exactly one of two shapes — no extra prose after.

**Success:**
```
WEEK=<YYYY-MM-DD>
POSTS_MEASURED=<int>
POSTS_FAILED=<int>
POSTS_SKIPPED=<int>
FAILED_IDS=<comma-separated ids or "-">
```

**Failure (before any post was measured):**
```
ERROR=<NETWORK|AUTH|FS|UNKNOWN>
```

Per-post failures do **not** trigger `ERROR=` — they're counted into `POSTS_FAILED` and listed in `FAILED_IDS`. `POSTS_SKIPPED` is the count of files with `type: "repost"` — analytics for those belong to the original poster, so we deliberately don't scrape them.

## Steps

### 1. Enumerate post files

```bash
ls -1 ./dashboards/li-stats/posts/*.json 2>/dev/null
```

If the list is empty → final contract with `POSTS_MEASURED=0 POSTS_FAILED=0 POSTS_SKIPPED=0 FAILED_IDS=-`. Done.

### 2. Open a NEW browser tab (never replace existing ones)

`mcp__playwright__browser_tabs` action `list` → action `new` with `url=about:blank`. Record the tab index. Tab discipline is mandatory.

### 3. Per-post loop

For each post file (sorted by filename, oldest first):

1. **Read the JSON** with `Read`. Extract `urn`, `id`, and `type` (default `"post"` if absent — legacy files predate the field).

   If `type == "repost"`: increment a local `skipped` counter and `continue` to the next file. Don't navigate, don't sleep. Pure reshares have no analytics of their own.

2. **Navigate to post-summary** in the tab you opened:
   `https://www.linkedin.com/analytics/post-summary/<urn>/`

3. **Wait** for analytics cards to render:
   - `mcp__playwright__browser_wait_for(text="Discovery", time=3)` *(text fallback to time)*
   - Then scroll to the bottom to trigger lazy load:
     ```js
     () => { window.scrollTo(0, document.body.scrollHeight); return true; }
     ```
   - `mcp__playwright__browser_wait_for(time=2)`

4. **Scrape the four cards** with `mcp__playwright__browser_evaluate`:

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

   Required extractions:

   | Card title | Metric key | Regex (number capture group 1) |
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

   Strip commas from captured numbers before parsing as integers. If a metric is missing, default to `0`.

5. **Compute engagement_rate**:
   ```
   engagement_rate = round((reactions + comments + reposts) / impressions * 100, 2)
   ```
   If `impressions == 0`, set `engagement_rate = 0`.

6. **Navigate to demographic-detail** in the same tab:
   `https://www.linkedin.com/analytics/demographic-detail/<urn>/?metricType=IMPRESSIONS`

7. **Wait** for `text="Top demographics"` (3s max), then scroll to bottom, then `wait_for(time=2)`.

8. **Expand any "Show all" / "Show more" buttons** so we capture full lists. Try via `browser_evaluate`:
   ```js
   () => {
     const btns = Array.from(document.querySelectorAll('button')).filter(b => /show all|show more/i.test(b.textContent || ''));
     btns.forEach(b => b.click());
     return btns.length;
   }
   ```
   Wait 1s after clicking.

9. **Scrape the six dimensions** with `browser_evaluate`:

   ```js
   () => {
     // Each dimension is a <section> whose <h2> is the dimension name.
     // Inside, rows look like "<label> <pct>%".
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
         // Match the LAST percentage in the row, anything before it = label.
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

10. **Build the snapshot object**:

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

11. **Merge into the post file**:

    Read the JSON file, set `data.weeks[WEEK] = snapshot`, write back pretty-printed (2-space indent). Use Python via Bash for atomic update:

    ```bash
    python3 - <<'PY'
    import json, sys
    path = "<filename>"
    week = "<WEEK>"
    snapshot = <inline-json>
    with open(path) as f: data = json.load(f)
    data.setdefault("weeks", {})[week] = snapshot
    with open(path, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    PY
    ```

    Idempotency: if `weeks[WEEK]` already exists, it's overwritten. Snapshots for earlier weeks are never touched.

12. **Politeness sleep** between posts:
    `mcp__playwright__browser_wait_for(time=1.5)` (or skip if last post).

13. **On any per-post error**: take a `mcp__playwright__browser_snapshot` (for debug), log the id into a local failures list, and continue with the next post. Don't fail the whole run.

### 4. Close the tab you opened

`mcp__playwright__browser_tabs` action `close` with the recorded index.

### 5. Emit the contract

```
WEEK=<YYYY-MM-DD>
POSTS_MEASURED=<n successfully written>
POSTS_FAILED=<n failed>
POSTS_SKIPPED=<n with type:"repost">
FAILED_IDS=<comma-separated, or "-">
```

## What you must not do

- Do **not** replace an existing browser tab. Always open a new one for your work.
- Do **not** leave your tab open at the end.
- Do **not** overwrite snapshots for past weeks. Touch only `weeks[<current WEEK>]`.
- Do **not** invent demographic numbers. Use `{}` for any dimension you genuinely couldn't scrape.
- Do **not** retry failed posts inside this run. Surface them in `FAILED_IDS`; the caller decides.
- Do **not** add prose after the final contract block.

## Failure modes

- Login wall / 429 / cards never render at all → take a `browser_snapshot`, close the tab, emit `ERROR=AUTH` (login wall) or `ERROR=NETWORK` (other transport / rate-limit / blank page).
- Cannot read or write any post file → `ERROR=FS`.
- Anything else, before any post was measured → `ERROR=UNKNOWN` with a one-paragraph explanation **before** the contract line.
