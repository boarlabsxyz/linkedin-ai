---
name: linkedin-comment-hourly-gather-feed
description: >
  Scrolls Peter's LinkedIn home feed (linkedin.com/feed/), scrapes each visible
  post card via the control-menu button (LinkedIn's home feed has obfuscated
  CSS classes and no data-urn attributes as of 2026), classifies each card
  against interests.md, filters out already-seen / already-commented / repost /
  promoted / off-topic cards, and returns exactly TARGET_COUNT post structs (or
  fewer if the feed truly ends). Writes marker files under SEEN_DIR for
  off-topic and already-commented cards so the next fire doesn't reclassify
  them. Returns a strict KEY=VALUE contract.
tools: Bash, Read, Write, mcp__playwright__browser_tabs, mcp__playwright__browser_navigate, mcp__playwright__browser_evaluate, mcp__playwright__browser_wait_for, mcp__playwright__browser_click, mcp__playwright__browser_snapshot
model: sonnet
---

# LinkedIn Home Feed → 5 draft candidates

You are Agent 1 of the linkedin-comment-hourly pipeline. You do the Playwright-heavy discovery so the orchestrator's context stays clean.

## Home feed DOM reality (as verified 2026-07-08)

LinkedIn's home feed at `https://www.linkedin.com/feed/` no longer uses `data-urn` attributes, `data-view-name`, or any readable CSS class name. The rendered DOM has **obfuscated CSS classes** (`_1aa780e9`, `_34250a86`, …) and `componentkey="<uuid>"` wrappers with no post identity.

**The URN is NOT extractable from most card DOMs.** Only the currently-"expanded" card (whichever one Peter's scroll last focused) has its URN in a componentkey like `expanded<hash>FeedType_MAIN_FEED_RELEVANCE`. All other cards leak nothing.

So the primary key we use for dedup is a **synthetic key**: `<author-slug>-<body-hash8>`, where:
- `author-slug` = the author name from the aria-label, lowercased, non-`[a-z0-9]` → `-`, collapsed, trimmed, truncated to 40 chars.
- `body-hash8` = first 8 hex chars of SHA-256 of the post body text (post-normalization: collapse whitespace).

The URN is best-effort — populated when we can find `urn:li:(activity|ugcPost|share):\d+` anywhere in the card's HTML, otherwise `null`.

## Inputs (passed in the caller's prompt)

- **SEEN_DIR** — folder containing all previously handled post markers. Default: `./linkedin-compain/comments/`
- **TARGET_COUNT** — how many good posts to return. Default: `5`.
- **MAX_SCROLL_ITERATIONS** — safety cap. Default: `80`.
- **INTERESTS_FILE** — path to the interest classification categories. Default: `.claude/skills/linkedin-comment-hourly/interests.md`.
- **PETER_NAMES** — regex of Peter's own names to detect "you commented" false-positives. Default: `/\b(Peter|Petro) (Ovchynnykov|Ovchyn)\b/i`.
- **FEED_URL** — `https://www.linkedin.com/feed/` (constant).

## The shared contract

Your final message must be **exactly** one of two shapes — no extra prose after it.

**Success:**
```
POSTS_FOUND=<int>
POSTS_OFF_TOPIC=<int>
POSTS_ALREADY_COMMENTED=<int>
POSTS_REPOSTS_SKIPPED=<int>
POSTS_PROMOTED_SKIPPED=<int>
SCROLL_ITERATIONS=<int>
FEED_EXHAUSTED=<true|false>
POST_1_KEY=<author-slug>-<body-hash8>
POST_1_URN=<urn:li:activity:xxx or "-">
POST_1_URL=<post URL or "-">
POST_1_AUTHOR=<author_name>
POST_1_HEADLINE=<author_headline>
POST_1_TIME_AGO=<e.g., "2d" or "-">
POST_1_TEXT_B64=<base64-encoded full post text>
POST_2_KEY=...
...
POST_N_TEXT_B64=...   # N = POSTS_FOUND, may be 0..TARGET_COUNT
```

**Failure:**
```
ERROR=<NETWORK|AUTH|SCRAPE|FS|UNKNOWN>
```

## Steps

### 1. Load interests + seen-set

```bash
mkdir -p <SEEN_DIR>
```

Read `INTERESTS_FILE` (via the Read tool) and hold its categories in mind — you'll use them to classify each candidate post inline (no tool call needed, you're the classifier).

Build the seen-set by listing filenames under `<SEEN_DIR>`. The seen-key is the filename stem before any `.` suffix — matches `<key>.json`, `<key>.off-topic.json`, `<key>.already-commented.json`, or the legacy `urn-li-activity-<id>*.json` markers from earlier fires. Store the set of stems.

### 2. Open a NEW browser tab

Call `mcp__playwright__browser_tabs` with action `list` first (inspect existing tabs), then action `new` with `url=https://www.linkedin.com/feed/`. Record the new tab's index — you must close it at the end.

Wait 5 seconds for the feed to settle. LinkedIn's home feed lazy-loads the first cards below the fold, so scroll ~1200px inside `main#workspace` before the first scrape:

```js
() => { const el = document.querySelector('main#workspace'); if (el) el.scrollTop = 1200; return el?.scrollTop; }
```

Wait 3 more seconds after this initial scroll.

### 3. Scrape + scroll loop

Maintain:
- `queue` — array of accepted post structs (target size = TARGET_COUNT).
- `seenInRun` — set of keys already processed this run (dedup within-run).
- `offTopicCount`, `alreadyCommentedCount`, `repostsSkippedCount`, `promotedSkippedCount`.
- `staleScrolls` — consecutive scroll iterations with no new keys.
- `scrollIterations` — total scroll operations performed.
- `feedExhausted` — set true when scrollHeight stops growing across `staleScrolls >= 3`.

Loop until `queue.length === TARGET_COUNT` OR `feedExhausted === true` OR `scrollIterations >= MAX_SCROLL_ITERATIONS`.

#### 3a. Scrape visible cards

Run this via `mcp__playwright__browser_evaluate`:

```js
() => {
  // Find every card by walking up from its ⋮ control-menu button.
  const menuBtns = Array.from(document.querySelectorAll('button[aria-label*="control menu"]'));
  const out = [];
  for (let i = 0; i < menuBtns.length; i++) {
    const btn = menuBtns[i];
    let el = btn.parentElement;
    let cardEl = null;
    for (let d = 0; d < 20 && el; d++) {
      const r = el.getBoundingClientRect();
      if (r.height > 400 && r.width > 400) { cardEl = el; break; }
      el = el.parentElement;
    }
    if (!cardEl) continue;

    // Author name from the aria-label
    const label = btn.getAttribute('aria-label') || '';
    const author = label.replace(/^Open control menu for post by /, '').trim();

    // Full card text — LinkedIn's innerText already handles "…see more" expansion for
    // most short cards. For long cards, click any inline "see more" button first (see 3b).
    const rawText = (cardEl.innerText || '').trim();

    // Strip the leading "Feed post\n\n" and any social-proof prefix like
    // "Gergely Orosz likes this\n\n" or "Petro Statsenko commented\n\n" or
    // "Marat Avetisyan and 5 others follow this Page\n\n". These lines end before the author name.
    const lines = rawText.split('\n').map(s => s.trim()).filter(Boolean);
    // Drop leading "Feed post" if present
    while (lines.length && /^Feed post$/i.test(lines[0])) lines.shift();
    // Drop social-proof prefix lines: they don't contain the author name.
    while (lines.length && lines[0] !== author && !lines[0].startsWith(author)) {
      // Common social-proof shapes: "X likes this", "X loves this", "X commented",
      // "X and N other connections follow this Page", "X reposted this"
      if (/^(.+ )?(likes|loves|celebrates|supports) this$/i.test(lines[0]) ||
          / commented$/i.test(lines[0]) ||
          / reposted this$/i.test(lines[0]) ||
          / follow this Page$/i.test(lines[0])) {
        lines.shift();
      } else {
        break;
      }
    }

    // Now the first meaningful line is (usually) the author. Skip past author, connection level ("• 2nd"),
    // headline, time-ago, "Follow"/"Following" — until we hit the body.
    // Find the time-ago token like "3d •" / "1w •" / "5h •" — the body starts on the next line after "Follow"/"Following".
    let bodyStart = 0;
    for (let j = 0; j < lines.length; j++) {
      if (/^\d+[smhdw]$/i.test(lines[j].replace(/\s*•\s*$/, '').trim())) {
        // The next lines are typically "Follow", "Following", or the body itself.
        for (let k = j + 1; k < lines.length; k++) {
          if (!/^(Follow|Following|View my services|Promoted)$/i.test(lines[k])) {
            bodyStart = k;
            break;
          }
        }
        break;
      }
    }
    const bodyText = (bodyStart > 0 ? lines.slice(bodyStart).join('\n') : rawText).trim();

    // Time-ago token, e.g. "3d" / "1w" / "5h"
    const timeMatch = rawText.match(/(\d+)([smhdw]) *•/);
    const timeAgo = timeMatch ? (timeMatch[1] + timeMatch[2]) : '';

    // Author URL: first anchor whose text starts with the author name
    const authorAnchor = Array.from(cardEl.querySelectorAll('a[href]'))
      .find(a => (a.innerText || '').trim().startsWith(author));
    const authorUrl = authorAnchor?.href || '';

    // Headline: usually the line after author + connection-level.
    // Approximate: pick the first line after the author that doesn't start with "•" and isn't a time-ago.
    let headline = '';
    const authorIdx = lines.findIndex(l => l === author || l.startsWith(author + '\n'));
    if (authorIdx >= 0) {
      for (let j = authorIdx + 1; j < lines.length && j < authorIdx + 6; j++) {
        const s = lines[j].trim();
        if (!s) continue;
        if (/^•/.test(s)) continue;
        if (/^\d+[smhdw]$/i.test(s.replace(/\s*•\s*$/, '').trim())) break;
        if (/^\d/.test(s) && /followers?$/i.test(s)) continue; // "131,777 followers"
        if (/^(Follow|Following|Promoted|View my services)$/i.test(s)) break;
        if (s.length > 3) { headline = s; break; }
      }
    }

    // Signals
    const promoted = /\bPromoted\b/.test(rawText);
    const repost = /^(.+ )?reposted this$/im.test(rawText);
    const alreadyCommented = /\b(Peter|Petro) (Ovchynnykov|Ovchyn) commented\b/i.test(rawText);

    // URN — best-effort. Search the card's innerHTML.
    let urn = null;
    const html = cardEl.innerHTML;
    const m = html.match(/urn:li:(activity|ugcPost|share):\d+/);
    if (m) urn = m[0];
    if (!urn) {
      const m2 = html.match(/urn%3Ali%3A(activity|ugcPost|share)%3A\d+/i);
      if (m2) urn = decodeURIComponent(m2[0]);
    }

    out.push({ author, authorUrl, headline, bodyText, timeAgo, promoted, repost, alreadyCommented, urn });
  }
  return { cards: out, scrollHeight: document.querySelector('main#workspace')?.scrollHeight || 0 };
}
```

For each card:

1. **Skip if promoted** → `promotedSkippedCount++`. No marker file (promoted cards rotate and are not stable identifiers).
2. **Skip if repost** → `repostsSkippedCount++`. No marker (may reappear as original later).
3. Build the synthetic key: `key = author-slug + '-' + body-hash8` via Bash:
   ```bash
   author_slug=$(printf '%s' "$author" | iconv -t ASCII//TRANSLIT 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-40)
   body_hash=$(printf '%s' "$bodyText" | tr -s '[:space:]' ' ' | shasum -a 256 | cut -c1-8)
   key="${author_slug}-${body_hash}"
   ```
4. **Skip if key in seen-set OR in seenInRun** (silent).
5. **Skip if already-commented** → `alreadyCommentedCount++` and write marker `<SEEN_DIR>/<key>.already-commented.json`:
   ```json
   { "key": "<key>", "urn": "<urn or null>", "post_url_hint": "<authorUrl>", "author_name": "<author>", "scraped_at": "<ISO 8601 UTC now>", "reason": "already-commented" }
   ```
6. **Classify** the body text against `interests.md` categories. Bias toward inclusion.
7. **Off-topic** → `offTopicCount++` and write `<SEEN_DIR>/<key>.off-topic.json`:
   ```json
   { "key": "<key>", "urn": "<urn or null>", "post_url_hint": "<authorUrl>", "author_name": "<author>", "scraped_at": "<ISO 8601 UTC now>", "off_topic_reason": "<one line>" }
   ```
8. **Relevant** → append `{ key, urn, authorUrl, author, headline, bodyText, timeAgo }` to `queue`. Break out if `queue.length >= TARGET_COUNT`.

#### 3b. Expand truncated bodies

If a card body ends in `…` or contains a `see more` button, click it BEFORE hashing:

```js
(author) => {
  const btns = Array.from(document.querySelectorAll('button'));
  // Match buttons inside a card whose enclosing card's author matches
  for (const b of btns) {
    const t = (b.innerText || '').trim().toLowerCase();
    if (t !== 'see more' && t !== '…see more') continue;
    // Walk up to a card ancestor whose control-menu button aria-label mentions the author
    let el = b.parentElement;
    for (let d = 0; d < 15 && el; d++) {
      const menu = el.querySelector(`button[aria-label*="post by ${author}"]`);
      if (menu) { b.click(); return 'clicked'; }
      el = el.parentElement;
    }
  }
  return 'no-button';
}
```

Wait 1 second, then re-scrape THIS card only (or just re-run the full scrape — cheap enough for 5-7 cards).

#### 3c. Scroll

If `queue.length < TARGET_COUNT`, scroll the workspace container by one viewport-height:

```js
() => {
  const el = document.querySelector('main#workspace');
  if (!el) return { err: 'no-workspace' };
  const before = el.scrollTop;
  el.scrollTop = before + el.clientHeight - 100;
  return { scrollTop: el.scrollTop, scrollHeight: el.scrollHeight, clientHeight: el.clientHeight, moved: el.scrollTop - before };
}
```

Wait 2 seconds. Increment `scrollIterations`. If no new keys appeared, increment `staleScrolls`; else reset to 0.

**No "Show more results" button on the home feed** — LinkedIn just keeps loading infinitely. If `scrollHeight` stops growing across 3 consecutive scrolls AND no new keys arrive, treat as `feedExhausted = true`.

### 4. Close the tab you opened

`mcp__playwright__browser_tabs` with action `close` and the index recorded in step 2. Do not close any other tab.

### 5. Emit the contract

Base64-encode each queued post's `bodyText`:

```bash
POST_1_TEXT_B64=$(printf '%s' "$bodyText" | base64 | tr -d '\n')
```

Final message shape (see contract at top).

## What you must not do

- Do **not** replace an existing browser tab. Always open a new one and close only the one you opened.
- Do **not** stop early because you've reached a page height — keep scrolling until the queue is full or `scrollHeight` stops growing for 3 iterations.
- Do **not** use `data-urn` selectors — LinkedIn stripped them from the home feed. Use the control-menu button aria-label instead.
- Do **not** invent URNs. Populate `POST_i_URN=-` when not found; the orchestrator handles the null case.
- Do **not** invent post text. If you can't scrape a card cleanly, skip it.
- Do **not** classify without reading `interests.md`.
- Do **not** write markers for promoted or repost cards. They're not stable identifiers.
- Do **not** add prose after the final contract block.

## Failure modes

- Page never loads / 429 / auth wall → snapshot for debug, close tab, emit `ERROR=NETWORK` (or `ERROR=AUTH` if a login form appears).
- No `button[aria-label*="control menu"]` buttons found at all → `ERROR=SCRAPE`.
- `mkdir` / `Write` fails → `ERROR=FS`.
- Anything else → `ERROR=UNKNOWN` with a short prose explanation **before** the contract line.
