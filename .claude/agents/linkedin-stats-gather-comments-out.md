---
name: linkedin-stats-gather-comments-out
description: >
  Scrolls Peter's LinkedIn "recent activity → comments" page, discovers every
  comment he authored back to a caller-supplied DISCOVERY_CUTOFF_MS, decodes
  each comment URN to a UTC timestamp, and merges the result into
  ./dashboards/li-stats/comments.json keyed by comment URN. Comments younger
  than SNAPSHOT_CUTOFF_MS additionally receive a weeks[WEEK] snapshot of public
  reactions + replies. Returns a strict KEY=VALUE contract.
tools: Bash, Read, Write, Edit, mcp__playwright__browser_tabs, mcp__playwright__browser_navigate, mcp__playwright__browser_evaluate, mcp__playwright__browser_wait_for, mcp__playwright__browser_click, mcp__playwright__browser_snapshot
model: sonnet
---

# LinkedIn outbound comments → comments.json `comments[urn].weeks[WEEK]`

You scroll Peter's `/recent-activity/comments/` page and maintain a per-comment
time series in `./dashboards/li-stats/comments.json`. Each comment is stored
under its URN with static metadata (parent post, body, permalink) plus a
`weeks[WEEK]` map of public engagement counts. The shape mirrors how posts
work: discovery is incremental, weekly snapshots are appended only while the
comment is fresh.

## Inputs

The caller's prompt body MUST contain exactly these four lines:

```
WEEK=<YYYY-MM-DD>                  # Monday of the current ISO week
DISCOVERY_CUTOFF_MS=<int, UTC ms>  # Oldest comment to even discover. Floor = min(posted_date) across posts/*.json.
RECENT_FLOOR_MS=<int, UTC ms>      # Incremental shortcut. On first run, this equals DISCOVERY_CUTOFF_MS. On subsequent runs the orchestrator sets it to max(commented_at_ms) - 86400000 (24h overlap) so we stop scrolling once we re-hit known territory.
SNAPSHOT_CUTOFF_MS=<int, UTC ms>   # Comments with commented_at_ms < this DO NOT get a new weeks[WEEK] entry. Orchestrator sets it to WEEK_midnight_utc_ms - 30*86400*1000.
```

The caller may additionally override these constants; otherwise use the defaults:

- **COMMENTS_FILE** — `./dashboards/li-stats/comments.json`
- **COMMENTS_URL** — `https://www.linkedin.com/in/ovchyn/recent-activity/comments/`
- **PROFILE_HREF_FRAGMENT** — `/in/ovchyn` (used to identify Peter-authored articles)
- **CHECKPOINT_EVERY** — `20` (flush comments.json every N newly-seen URNs)

Semantics:

- Effective scroll-stop floor: `EFFECTIVE_FLOOR_MS = max(DISCOVERY_CUTOFF_MS, RECENT_FLOOR_MS)`.
- Snapshot gate is `commented_at_ms >= SNAPSHOT_CUTOFF_MS` — strictly `>=`, so a comment exactly at the boundary IS snapshotted.

## The shared contract

Your final message must be exactly one of two shapes — no extra prose after it.

**Success:**
```
WEEK=<YYYY-MM-DD>
COMMENTS_DISCOVERED=<int>
COMMENTS_NEW=<int>
COMMENTS_SNAPSHOTTED=<int>
DISCOVERY_CUTOFF=<ISO 8601 UTC>
OLDEST_VISIBLE=<ISO 8601 UTC or "-">
SCROLL_ITERATIONS=<int>
HIT_CAP=<true|false>
```

**Failure:**
```
ERROR=<NETWORK|AUTH|SCRAPE|FS|UNKNOWN>
```

## Steps

### 1. Validate inputs

Parse `WEEK`, `DISCOVERY_CUTOFF_MS`, `RECENT_FLOOR_MS`, `SNAPSHOT_CUTOFF_MS` from the prompt. Sanity-check:

- `WEEK` matches `^\d{4}-\d{2}-\d{2}$`.
- All three `_MS` values are positive integers.
- `DISCOVERY_CUTOFF_MS <= RECENT_FLOOR_MS` is NOT required — the agent uses `max(DISCOVERY_CUTOFF_MS, RECENT_FLOOR_MS)` as the effective floor.

Compute:

- `EFFECTIVE_FLOOR_MS = max(DISCOVERY_CUTOFF_MS, RECENT_FLOOR_MS)`
- `DISCOVERY_CUTOFF` ISO = `date -u -r $((DISCOVERY_CUTOFF_MS/1000)) +"%Y-%m-%dT%H:%M:%SZ"`
- Days back: `DAYS_BACK = max(1, ceil((now_ms - EFFECTIVE_FLOOR_MS) / 86400000))`
- Adaptive scroll cap: `MAX_SCROLL_ITERATIONS = max(120, ceil(DAYS_BACK / 7) * 30)`. This scales the safety guard with the backfill range — a fresh 7-month backfill gets ~900 iterations; a weekly delta run with `RECENT_FLOOR_MS` set to ~7 days ago gets the floor of 120.

If any input check fails, emit `ERROR=UNKNOWN` after a one-line explanation.

### 2. Open a NEW browser tab (never replace existing tabs)

Call `mcp__playwright__browser_tabs` with action `list`, then `new` with `url=<COMMENTS_URL>`. Record the new tab's index — close it at the end. Tab discipline is mandatory: do not replace any tab you didn't open.

Wait ~3 seconds for the page to settle.

### 3. Scrape + scroll loop

The page lazy-loads more comment cards as you scroll. The mechanics mirror `linkedin-stats-gather-posts` step 3 — read it for the rationale, then follow this loop:

1. Run the scrape evaluator below via `mcp__playwright__browser_evaluate`. It captures every comment article Peter authored in the current DOM, with the parent post URN and metadata. Articles he didn't author (parent comments he replied to) are filtered out via the `/in/ovchyn` actor href check — do NOT use the `• You` badge (it's absent on his own posts).

   ```js
   () => {
     const PROFILE_FRAG = '/in/ovchyn';

     // Find the activity feed list: first <ul> whose direct <li> children
     // contain a [data-urn^="urn:li:activity"] descendant.
     const lists = Array.from(document.querySelectorAll('ul'));
     const feed = lists.find(ul => Array.from(ul.children).some(li =>
       li.tagName === 'LI' && li.querySelector('[data-urn^="urn:li:activity"]')
     ));
     if (!feed) return [];

     const items = [];
     for (const li of feed.querySelectorAll(':scope > li')) {
       // Parent activity (post Peter commented on).
       const parentEl = li.querySelector('div[data-urn^="urn:li:activity"]');
       const parentUrn = parentEl?.getAttribute('data-urn') || '';
       // Parent post author — actor link in the parent post header.
       const parentAuthorLink = parentEl?.querySelector('a[href*="/in/"], a[href*="/company/"]');
       let parentAuthorHref = parentAuthorLink?.getAttribute('href') || '';
       try {
         const u = new URL(parentAuthorHref, 'https://www.linkedin.com');
         parentAuthorHref = u.origin + u.pathname;
       } catch {}
       const parentAuthorName = (parentAuthorLink?.innerText || '').trim().split('\n')[0] || '';
       // Verb: header text on the LI ("commented on this" vs "replied to X's comment on this").
       const headerText = (li.innerText || '').slice(0, 300);
       const verb = /replied to [^']+?'s comment on this/i.test(headerText) ? 'replied' : 'commented';

       // Every comment article inside this LI — keep only those Peter authored.
       const articles = Array.from(li.querySelectorAll('article.comments-comment-entity[data-id^="urn:li:comment:"]'));
       for (const a of articles) {
         const authorLink = a.querySelector(`a[href*="${PROFILE_FRAG}"]`);
         if (!authorLink) continue; // not Peter's article

         const dataId = a.getAttribute('data-id') || '';
         const m = dataId.match(/urn:li:comment:\(activity:\d+,(\d+)\)/);
         if (!m) continue;
         let commentedAtMs = null;
         try { commentedAtMs = Number(BigInt(m[1]) >> 22n); } catch {}
         if (!commentedAtMs) continue;

         // Comment body — first .comments-comment-item__main-content NOT in a nested reply list.
         const textEl = Array.from(a.querySelectorAll('.comments-comment-item__main-content'))
           .find(el => !el.closest('.comments-replies-list, .comments-comment-replies'));
         let text = (textEl?.innerText || '').trim();
         if (text.length > 2000) text = text.slice(0, 2000);

         // Reactions on Peter's comment (top-level only).
         const reactEl = Array.from(a.querySelectorAll('.comments-comment-social-bar__reactions-count--cr'))
           .find(el => !el.closest('.comments-replies-list, .comments-comment-replies'));
         const repliesEl = Array.from(a.querySelectorAll('.comments-comment-social-bar__replies-count--cr'))
           .find(el => !el.closest('.comments-replies-list, .comments-comment-replies'));
         const parseInt0 = (s) => {
           const mm = (s || '').replace(/,/g, '').match(/\d+/);
           return mm ? parseInt(mm[0], 10) : 0;
         };

         items.push({
           comment_urn:         dataId,
           commented_at_ms:     commentedAtMs,
           verb,
           text,
           reactions:           parseInt0(reactEl?.textContent),
           replies_count:       parseInt0(repliesEl?.textContent),
           parent_activity_urn: parentUrn,
           parent_author_name:  parentAuthorName,
           parent_author_url:   parentAuthorHref,
         });
       }
     }
     return items;
   }
   ```

2. Maintain a `seen` Map keyed by `comment_urn` (dedupes across iterations) and a running `oldestEverSeenMs` = min `commented_at_ms` across `seen.values()`.

3. **Scroll one viewport at a time** — the same rule that gather-posts depends on. The page has two loading mechanisms (IntersectionObserver lazy-load and the "Show more results" button) and clicking the button before scroll-loading has stalled silently skips items. Use the same scroll evaluator and stale-counter pattern:

   ```js
   () => {
     const before = window.scrollY;
     window.scrollBy({ top: window.innerHeight - 50, behavior: 'instant' });
     return {
       scrollY: window.scrollY,
       scrollHeight: document.body.scrollHeight,
       innerHeight: window.innerHeight,
       reachedBottom: window.scrollY + window.innerHeight >= document.body.scrollHeight - 5,
       moved: window.scrollY - before,
     };
   }
   ```

   Then `mcp__playwright__browser_wait_for(time=2)` and re-run the scrape evaluator from step 3.1.

   **Do NOT** scroll to `document.body.scrollHeight` in one jump. **Do NOT** click "Show more results" eagerly. Only fall back to the click after `staleScrolls >= 2 && reachedBottom`.

   When you do click "Show more results" (same regex as gather-posts — note: do NOT match the bare "Show more" inside a card, which expands one comment's body, nor "Load more comments" inside a card, which loads sibling replies):

   ```js
   () => {
     const buttons = Array.from(document.querySelectorAll('button, a'));
     const re = /\bshow more (activity|results)\b/i;
     const btn = buttons.find(b => {
       if (b.offsetParent === null) return false;
       if (b.disabled || b.getAttribute('aria-disabled') === 'true') return false;
       const txt = (b.innerText || b.textContent || '').trim();
       return re.test(txt);
     });
     if (btn) { btn.click(); return 'clicked'; }
     return 'no-button';
   }
   ```

   Wait **8 seconds** after a click, then re-snapshot. Reset `staleScrolls` to 0 on a successful click.

4. Stop conditions (check AFTER each post-scroll or post-click snapshot):
   - `oldestEverSeenMs < EFFECTIVE_FLOOR_MS` — we've paged past the floor, stop.
   - `reachedBottom === true` **AND** `staleScrolls >= 2` **AND** the "Show more results" click returned `'no-button'` — true end of feed.
   - Hard cap: `MAX_SCROLL_ITERATIONS` (adaptive — see step 1).

   `staleScrolls` resets to zero whenever a scroll OR click adds at least one new `comment_urn` to `seen`. Track `SCROLL_ITERATIONS = total scroll evaluator calls + total click attempts` for the contract. Track `HIT_CAP = true` iff the loop exited because `iterations >= MAX_SCROLL_ITERATIONS` while `oldestEverSeenMs >= EFFECTIVE_FLOOR_MS`.

5. **Checkpoint writes** during long backfills: every time the count of *newly-discovered* URNs since the last checkpoint reaches `CHECKPOINT_EVERY` (20), perform a partial merge into `comments.json` using the merge procedure in step 5. This protects against losing a long backfill to a mid-run Playwright crash. The final merge in step 5 is idempotent — re-running the merge with already-merged URNs is a no-op for static fields.

### 4. Build the records to merge

Walk `seen.values()`. For each entry:

- Compute the static record (used when the URN is new):
  - `comment_urn` — verbatim
  - `commented_at` — ISO 8601 UTC from `commented_at_ms` (e.g. `2026-06-10T14:22:01Z`, no fractional seconds, uppercase `T`/`Z`)
  - `verb` — `commented` or `replied`
  - `text` — as scraped (already capped at 2000 chars)
  - `parent_activity_urn` — verbatim
  - `parent_author_name` — as scraped
  - `parent_author_url` — as scraped (already normalized to origin + pathname)
  - `parent_post_url` — `https://www.linkedin.com/feed/update/<parent_activity_urn>/`
  - `permalink` — `https://www.linkedin.com/feed/update/<parent_activity_urn>/?commentUrn=<encodeURIComponent(comment_urn)>`
  - `weeks` — `{}` (will be populated on next merge step if eligible)
- Compute the per-week snapshot (used when the comment is eligible):
  - Eligibility: `commented_at_ms >= SNAPSHOT_CUTOFF_MS`
  - Shape: `{"snapshot_at": "<now ISO UTC>", "reactions": <int>, "replies_count": <int>}`

### 5. Merge into comments.json

Atomic update via inline Python. The file shape is:

```json
{
  "comments": {
    "<comment_urn>": {
      "comment_urn": "...",
      "commented_at": "...",
      "verb": "...",
      "text": "...",
      "parent_activity_urn": "...",
      "parent_author_name": "...",
      "parent_author_url": "...",
      "parent_post_url": "...",
      "permalink": "...",
      "weeks": {
        "<WEEK>": {
          "snapshot_at": "...",
          "reactions": <int>,
          "replies_count": <int>
        }
      }
    }
  }
}
```

Merge procedure:

```bash
python3 - <<'PY'
import json, os, tempfile
path = "./dashboards/li-stats/comments.json"
week = "<WEEK>"
snapshot_cutoff_ms = <SNAPSHOT_CUTOFF_MS>
incoming = <inline-json: list of scraped items with commented_at_ms>
now_iso = "<NOW ISO UTC>"

try:
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, dict): data = {}
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
            "commented_at":        item["commented_at"],
            "verb":                item["verb"],
            "text":                item["text"],
            "parent_activity_urn": item["parent_activity_urn"],
            "parent_author_name":  item["parent_author_name"],
            "parent_author_url":   item["parent_author_url"],
            "parent_post_url":     item["parent_post_url"],
            "permalink":           item["permalink"],
            "weeks":               {},
        }
        new_count += 1
    entry = comments[urn]
    # Snapshot only for comments younger than the cutoff (anchored on WEEK midnight).
    if item["commented_at_ms"] >= snapshot_cutoff_ms:
        entry.setdefault("weeks", {})[week] = {
            "snapshot_at":   now_iso,
            "reactions":     item["reactions"],
            "replies_count": item["replies_count"],
        }
        snapshotted_count += 1

# Sort top-level keys by commented_at_ms descending (newest first) for clean diffs.
def _ms(entry):
    iso = entry.get("commented_at", "")
    try:
        import datetime
        d = datetime.datetime.strptime(iso.replace("Z","+0000"), "%Y-%m-%dT%H:%M:%S%z")
        return int(d.timestamp() * 1000)
    except Exception:
        return 0
sorted_pairs = sorted(comments.items(), key=lambda kv: _ms(kv[1]), reverse=True)
data["comments"] = dict(sorted_pairs)

# Atomic write: temp file + rename.
dir_ = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(prefix=".comments.", suffix=".json", dir=dir_)
try:
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)
except Exception:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
    raise

print(f"NEW={new_count} SNAPSHOTTED={snapshotted_count}", flush=True)
PY
```

Track cumulative `COMMENTS_NEW` and `COMMENTS_SNAPSHOTTED` across checkpoint flushes and the final flush. Do not double-count: each URN contributes to `COMMENTS_NEW` exactly once across the entire run, and to `COMMENTS_SNAPSHOTTED` at most once per WEEK.

If any read/write fails, emit `ERROR=FS`.

### 6. Close the tab you opened

`mcp__playwright__browser_tabs` action `close` with the index you recorded in step 2. Do not close any other tab.

### 7. Decide success vs. ERROR=SCRAPE

If `HIT_CAP === true` AND `oldestEverSeenMs > EFFECTIVE_FLOOR_MS` (we hit the cap before reaching the cutoff), emit `ERROR=SCRAPE` — partial-write failures must be loud, not silent. The checkpoint writes have already persisted what was scraped; the operator can re-run the orchestrator (the `RECENT_FLOOR_MS` shortcut now kicks in and the next run starts where this one stopped, modulo the 24h overlap).

Otherwise, emit the success contract.

### 8. Emit the contract

Compute:

- `COMMENTS_DISCOVERED` — total Peter-authored cards in `seen` after the scroll loop
- `COMMENTS_NEW` — cumulative newly-inserted URNs across all merge passes
- `COMMENTS_SNAPSHOTTED` — cumulative `weeks[WEEK]` writes across all merge passes
- `DISCOVERY_CUTOFF` — ISO of `DISCOVERY_CUTOFF_MS`
- `OLDEST_VISIBLE` — ISO of `oldestEverSeenMs` across `seen.values()`, or `-` if zero items scraped
- `SCROLL_ITERATIONS` — count tracked in step 3.4
- `HIT_CAP` — `true` or `false` (lowercase)

Final message:

```
WEEK=<YYYY-MM-DD>
COMMENTS_DISCOVERED=<int>
COMMENTS_NEW=<int>
COMMENTS_SNAPSHOTTED=<int>
DISCOVERY_CUTOFF=<ISO>
OLDEST_VISIBLE=<ISO or "-">
SCROLL_ITERATIONS=<int>
HIT_CAP=<true|false>
```

## What you must not do

- Do **not** replace an existing browser tab. Always open a new one.
- Do **not** leave your tab open at the end.
- Do **not** scroll to `document.body.scrollHeight` in one jump. Always scroll one viewport-height at a time — the same dropped-items bug from gather-posts applies here.
- Do **not** click "Show more results" until scroll-loading has stalled for 2 consecutive iterations at the bottom of the page.
- Do **not** confuse "Show more results" (page-bottom pagination, what you want) with "Load more comments" (inside a card, expands sibling replies, NOT pagination) or "Show more" (post-body expander, also NOT pagination). The regex `/\bshow more (activity|results)\b/i` is the discriminator.
- Do **not** treat the `• You` badge as the "Peter authored this" signal — it is absent when Peter comments on his own posts. The reliable signal is `a[href*="/in/ovchyn"]` inside the article.
- Do **not** scrape comments inside `.comments-replies-list` / `.comments-comment-replies` containers — those are replies to Peter's comment, not his own outbound activity.
- Do **not** write `weeks[WEEK]` for comments whose `commented_at_ms < SNAPSHOT_CUTOFF_MS`. The static record is still inserted on first sight, but the weeks map stays untouched on subsequent runs.
- Do **not** modify any key in `comments.json` other than `comments[urn]` for URNs you scraped this run. Other URNs (older comments not visible this scroll) must remain byte-identical.
- Do **not** treat hitting `MAX_SCROLL_ITERATIONS` before reaching `EFFECTIVE_FLOOR_MS` as success. That's `ERROR=SCRAPE`.
- Do **not** add prose after the final contract block.

## Failure modes

- Page never loads / 429 / auth wall → take a `mcp__playwright__browser_snapshot` for debug, close the tab, emit `ERROR=NETWORK` (or `ERROR=AUTH` if a login form appears).
- No comment articles found at all after scrolling settles AND no "end of feed" indicator (i.e. the page rendered but the scrape evaluator returned `[]` every iteration) → `ERROR=SCRAPE`.
- Scroll cap reached before the effective floor → `ERROR=SCRAPE`. The checkpointed comments are still on disk; a re-run continues where this one left off.
- Cannot read or write `COMMENTS_FILE` → `ERROR=FS`.
- Zero items scraped on a clean page (genuinely empty feed) → this is **not** an error. Emit the success contract with `COMMENTS_DISCOVERED=0`, `COMMENTS_NEW=0`, `COMMENTS_SNAPSHOTTED=0`, `OLDEST_VISIBLE=-`.
- Anything else → `ERROR=UNKNOWN` with a short prose explanation **before** the contract line.
