# `linkedin-stats` — add per-post comments collection

Design notes for extending the `linkedin-stats` skill so each weekly snapshot
also captures the list of top-level commenters on every post (not just the
total count we already store under `metrics.comments`).

---

## How it works now (2026-06-10)

The `linkedin-stats` skill (`.claude/skills/linkedin-stats/SKILL.md`) is a thin
orchestrator that fan-outs to three sub-agents in `.claude/agents/`:

1. **`linkedin-stats-gather-posts`** — opens
   `https://www.linkedin.com/in/ovchyn/recent-activity/all/`, scrolls one
   viewport at a time, decodes each card's URN to a UTC timestamp, writes one
   JSON file per post to `dashboards/li-stats/posts/<YYYY-MM-DD>-<slug>.json`
   with `{urn, id, type, posted_at, posted_date, post_url, preview, weeks:{}}`.
2. **`linkedin-stats-gather-metrics`** — for each post file sequentially:
   - Opens `https://www.linkedin.com/analytics/post-summary/<urn>/` and scrapes
     the four cards (Discovery / Profile activity / Social engagement).
   - Opens `https://www.linkedin.com/analytics/demographic-detail/<urn>/` and
     scrapes the six audience dimensions.
   - Merges a snapshot into the post file at `weeks[WEEK]`:
     ```json
     {
       "snapshot_at": "<ISO 8601 UTC>",
       "metrics":       { "impressions": …, "comments": 3, … },
       "demographics":  { "seniority": …, "job_title": …, … }
     }
     ```
   - Returns `STATUS=OK POST_ID=… WEEK=… IMPRESSIONS=… REACTIONS=… COMMENTS=…`.
3. **`linkedin-stats-gather-account`** — dashboard + four creator-analytics
   pages → appends a week-keyed entry to `dashboards/li-stats/account.json`.

**What is *not* collected today:** the comment count is stored, but the actual
comment metadata (who commented, when, with how many reactions and replies) is
never captured. There is no path through any of the analytics pages that
exposes individual comments — those only live on the public post URL
(`/feed/update/<urn>/`).

---

## Target — what it should also do

Capture, per weekly snapshot, the **list of top-level commenters** on each
non-repost post, so we can later answer questions like "who's repeatedly
engaging with my content" and "how did the comment thread grow over time".

### Decisions (locked in with the user 2026-06-10)

| Question | Decision |
|---|---|
| Fields per comment | `author_name`, `author_url`, `time_text` (whatever LinkedIn shows, e.g. `"2d"`), `reactions`, `replies_count` — **no comment body** |
| Replies (nested) | Top-level only; do not click "X replies" expanders |
| Storage | Inside `weeks[WEEK].comments` as an array, alongside `metrics` and `demographics` |
| Scrape source | Public post URL (`post_url` already on the file = `/feed/update/<urn>/`). Analytics pages don't expose comments. |
| Reposts (`type: "repost"`) | Still skipped — same as today; no own analytics, no own thread |

### New JSON shape

`weeks[WEEK]` grows by one key:

```jsonc
{
  "snapshot_at": "...",
  "metrics":      { … unchanged … },
  "demographics": { … unchanged … },
  "comments": [
    {
      "author_name": "Jane Doe",
      "author_url":  "https://www.linkedin.com/in/jane-doe/",
      "time_text":   "2d",
      "reactions":   4,
      "replies_count": 1
    },
    …
  ]
}
```

If a post has no comments visible, write `"comments": []` so the shape is
uniform across snapshots. Cap the captured list at **200 entries** to keep
files bounded (anything over that is almost certainly a viral outlier we'd
look at by hand anyway).

### Agent contract change

`linkedin-stats-gather-metrics` adds one line on success:

```
STATUS=OK
POST_ID=<id>
WEEK=<YYYY-MM-DD>
IMPRESSIONS=<int>
REACTIONS=<int>
COMMENTS=<int>          # still the analytics-reported count
COMMENTS_SCRAPED=<int>  # NEW — top-level comments we actually captured
```

The two can legitimately disagree (analytics counts include replies; we only
capture top-level). The skill's final report surfaces both so a mismatch is
visible.

### Skill-level final report addition

The "Gather post metrics" block in `SKILL.md`'s report grows by one line:

```
- Comments scraped: <sum of COMMENTS_SCRAPED across all posts>
```

### Verified selectors (live-probed 2026-06-10)

Confirmed against two posts: `7464644189239091201` (1 top-level, 2 replies)
and `7429507665682391040` (10+ top-level, many with reactions/replies).

| Field | Selector | Notes |
|---|---|---|
| Top-level container | `.comments-comments-list` | Wait for this before scraping |
| Top-level comment | `article.comments-comment-entity` filtered by `!a.closest('.comments-replies-list, .comments-comment-replies')` | Excludes nested replies |
| Comment URN | `article[data-id]` → `urn:li:comment:(activity:<post>,<comment>)` | Unique per comment |
| Author name | `.comments-comment-meta__description-title` | textContent.trim() |
| Author URL | `a.comments-comment-meta__description-container` href (fallback `a.comments-comment-meta__image-link`) | Already absolute, ends `/in/<slug>` |
| Time text | first `time.comments-comment-meta__data` | "2d", "1w", "3mo", … |
| Reactions count | `.comments-comment-social-bar__reactions-count--cr` queried at the article level, then filtered to exclude matches inside `.comments-replies-list` / `.comments-comment-replies` | textContent → int; element absent ⇒ 0. (DO NOT scope by `.comments-comment-social-bar` — that bare class doesn't exist; the wrapper is `--cr`.) |
| Replies count | `.comments-comment-social-bar__replies-count--cr` with the same closest-filter | "8 replies" → parse leading int; absent ⇒ 0 |
| Load-more button | `button[aria-label="Load more comments"]` or any button with text "Load more comments" | Distinct from the per-comment "See previous replies" |

### Steps to add inside `linkedin-stats-gather-metrics` (between step 9 and
step 10 — after the demographics scrape, before the snapshot is assembled)

Everything in this block is **best-effort**. Wrap it in try/catch and default
to `comments = []` on any throw — analytics metrics are load-bearing, this is
additive intel.

1. **Navigate** the owned tab to `post_url` from the post file (already on
   disk, no URL rebuild needed).
2. **Wait** for the feed-update DOM and the comment section:
   - `wait_for(time=3)` for the page to settle.
   - `wait_for(text="Load more comments", time=3)` — falls back to time if no
     more-comments button exists (small threads).
3. **Loop** to load all top-level comments:
   - Find any visible button matching `[aria-label="Load more comments"]` OR
     text `"Load more comments"`.
   - Click it, `wait_for(time=2)`.
   - Stop when: no such button OR ≥200 top-level comments collected OR 30
     iterations.
4. **Scrape** with one `browser_evaluate`. For each top-level
   `article.comments-comment-entity` that is NOT inside a replies list:
   - `author_name` = first `.comments-comment-meta__description-title`
     textContent.
   - `author_url` = first
     `a.comments-comment-meta__description-container` href (fallback:
     `a.comments-comment-meta__image-link` href). Strip query string;
     preserve trailing slash.
   - `time_text` = first `time.comments-comment-meta__data` textContent.
   - `reactions` = parse int from the first
     `.comments-comment-social-bar__reactions-count--cr` inside the article
     that is NOT inside a replies container; `0` if absent.
   - `replies_count` = parse leading int from the first
     `.comments-comment-social-bar__replies-count--cr` inside the article
     that is NOT inside a replies container (`"8 replies"` → `8`); `0` if
     absent.
5. **Truncate** at 200 entries. Set `comments = [...]`.
6. Continue with the existing snapshot-build + Python heredoc write,
   including `comments` in the object.

### Failure handling

Comment scraping is **best-effort**. If steps 1–5 throw, set `comments: []`,
record the metrics+demographics snapshot anyway, and emit `STATUS=OK` with
`COMMENTS_SCRAPED=0`. Losing the comment list should not poison the metrics
write — those are the load-bearing numbers the dashboard depends on.

A new reason class `COMMENTS` is **not** introduced; metrics-side failures
remain the only path to `STATUS=FAIL`.

---

## Out of scope for this iteration

- Reply threads (one level deep would mostly capture Peter's own replies; can
  add later if useful).
- Comment body text (privacy / file-size; revisit if discussion-content
  analysis becomes a goal).
- Backfilling historical weeks — the new `comments` field appears only on
  weeks scraped after this lands. Existing `weeks[WEEK]` entries stay
  untouched (no `comments` key); dashboards should treat the field as
  optional.
