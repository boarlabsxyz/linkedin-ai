---
name: linkedin-comment-hourly-gather-feed
description: >
  Scrolls Peter's LinkedIn home feed (linkedin.com/feed/), scrapes each visible
  post card via the control-menu button (LinkedIn's home feed has obfuscated
  CSS classes and no data-urn attributes as of 2026), classifies each card
  against interests.md, filters out already-seen / already-commented / repost /
  promoted / off-topic cards, and returns exactly TARGET_COUNT post structs (or
  fewer if the feed truly ends). Appends off-topic and already-commented entries
  (with full post text) to the single COMMENTS_FILE array so the next fire
  doesn't reclassify them. Returns a strict KEY=VALUE contract.
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

The **permalink** (not the raw URN) is what matters, and it's best-effort, recovered for accepted posts in two passes:

1. A regex over the card's HTML for `urn:li:(activity|ugcPost|share):\d+`. As of **2026-07-14 this yields ~0%** — LinkedIn strips URNs from every home-feed card DOM (verified: a full-document attribute scan finds zero `urn:li:activity` hits, and the timestamp/anchor links are generic `/company/.../posts/` with no activity id). Kept only as a free first try.

2. For any card that passes all filters and enters the queue but still has no permalink, the control-menu **"Copy link to post"** → clipboard flow (step 3d), while the card is still mounted. **Two 2026-07-14 realities the flow must handle:**
   - **"Copy link to post" now copies a `https://lnkd.in/p/<code>` short link, NOT a raw URN.** The old regex (`urn:li:activity` / `activity-<id>`) never matched it, so `post_url` came out null even when the copy succeeded — *this was the "no stable permalink" bug*.
   - **Reading the clipboard with `navigator.clipboard.readText()` throws "Document is not focused" in the unfocused/headless cron tab.** So we do NOT read the clipboard. We **intercept `navigator.clipboard.writeText` before clicking** and capture the string LinkedIn writes — focus-independent and permission-independent.

   The captured `lnkd.in` short link is then **resolved server-side** (`curl -sIL`) to the canonical `/posts/…-<activityId>-<hash>/` URL, from which we pull the 15–25-digit activity id → `urn:li:activity:<id>` and the canonical permalink `https://www.linkedin.com/feed/update/<urn>/`.

Only accepted posts get pass-2 recovery — filtered (off-topic / already-commented) cards keep `urn: null` / `post_url: null`, which is fine since they never need a permalink. **`post_url` for an accepted post should almost never be null now:** if resolution fails, we keep the captured `lnkd.in` short link as `post_url` (it's still a clickable permalink) with `urn: null`; only a total capture failure (no short link at all) leaves `post_url` null.

## Inputs (passed in the caller's prompt)

- **COMMENTS_FILE** — the single JSON-array file holding every handled post (drafted + filtered), one object per post. Doubles as the cross-fire seen-set. Default: `./linkedin-compain/comments.json`
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
POST_1_URL=<post permalink — canonical "https://www.linkedin.com/feed/update/<urn>/" or the "https://lnkd.in/p/<code>" short link; "-" only when nothing was captured>
POST_1_AUTHOR_URL=<author profile URL or "-">
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

Ensure the comments file exists (an empty JSON array if this is the first fire):

```bash
[ -f "<COMMENTS_FILE>" ] || printf '[]\n' > "<COMMENTS_FILE>"
```

Read `INTERESTS_FILE` (via the Read tool) and hold its categories in mind — you'll use them to classify each candidate post inline (no tool call needed, you're the classifier).

Build the seen-set from the keys already recorded in `<COMMENTS_FILE>` — one line per key:

```bash
jq -r '.[].key' "<COMMENTS_FILE>"
```

Store the returned keys as the seen-set. Every entry in the file (drafted, off-topic, or already-commented) counts — a key present here means the post was handled on a prior fire and must be skipped. `repost` / `promoted` cards are never written to the file, so they never enter the seen-set (they may legitimately reappear as originals later).

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

1. **Skip if promoted** → `promotedSkippedCount++`. Not written to `<COMMENTS_FILE>` (promoted cards rotate and are not stable identifiers).
2. **Skip if repost** → `repostsSkippedCount++`. Not written (may reappear as original later).
3. Build the synthetic key: `key = author-slug + '-' + body-hash8` via Bash:
   ```bash
   author_slug=$(printf '%s' "$author" | iconv -t ASCII//TRANSLIT 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-40)
   body_hash=$(printf '%s' "$bodyText" | tr -s '[:space:]' ' ' | shasum -a 256 | cut -c1-8)
   key="${author_slug}-${body_hash}"
   ```
4. **Skip if key in seen-set OR in seenInRun** (silent).
5. **Skip if already-commented** → `alreadyCommentedCount++` and **append an entry** to `<COMMENTS_FILE>` with `disposition:"already-commented"` (see the append helper below), then add the key to `seenInRun`.
6. **Classify** the body text against `interests.md` categories. Bias toward inclusion.
7. **Off-topic** → `offTopicCount++` and **append an entry** to `<COMMENTS_FILE>` with `disposition:"off-topic"` and a one-line `reason`, then add the key to `seenInRun`.
8. **Relevant** → run the permalink recovery flow (step 3d) for this card's `author` **now**, while the card is mounted, to set `postUrl` (and `urn` when it resolves). Then append `{ key, urn, postUrl, authorUrl, author, headline, bodyText, timeAgo }` to `queue`. Break out if `queue.length >= TARGET_COUNT`. (Relevant posts are NOT written here — the orchestrator writes their full `drafted` entry after Agent 2 drafts them.)

#### Append helper (filtered entries)

Both off-topic and already-commented use the same read-modify-write. `<COMMENTS_FILE>` is a JSON array; append one object built with `jq -n` (so text, quotes, and newlines are encoded safely — never hand-write JSON). `disposition` is `off-topic` or `already-commented`; `reason` is your one-line classification note (for already-commented, use `"already-commented"`).

**`post_text` is MANDATORY and must be the card's full scraped body — the exact `bodyText` you just classified, never empty and never a summary.** Passing multi-line body text through a shell variable is unreliable, so write it to a temp file first and read it with `jq --rawfile` (same fail-safe discipline the draft agent uses for base64):

1. Write the card's exact `bodyText` to `./tmp/filtered-<key>.txt` with the **Write tool** (exact bytes — no shell quoting).
2. Build and append the entry, reading the body via `--rawfile`:

   ```bash
   NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
   # post_url is the canonical permalink built from the URN (null when no URN — filtered
   # cards don't get pass-2 recovery). author_url is the author's profile link.
   if [ -n "$urn" ] && [ "$urn" != "-" ]; then post_url="https://www.linkedin.com/feed/update/$urn/"; else post_url=""; fi
   entry=$(jq -n \
     --arg key "$key" --arg urn "$urn" --arg posturl "$post_url" --arg authorurl "$authorUrl" \
     --arg author "$author" --arg headline "$headline" --arg time "$timeAgo" \
     --rawfile text "./tmp/filtered-<key>.txt" --arg now "$NOW" \
     --arg disp "$disposition" --arg reason "$reason" \
     '{key:$key, urn:(if $urn=="" or $urn=="-" then null else $urn end),
       post_url:(if $posturl=="" then null else $posturl end),
       author_url:(if $authorurl=="" then null else $authorurl end),
       author_name:$author, author_headline:$headline, time_ago:$time,
       post_text:($text|sub("\n+$";"")), scraped_at:$now, disposition:$disp, reason:$reason,
       variants:[], slack_summary:null, slack_ts:null,
       slack_thread:{post_reply_ts:null, draft_reply_ts:[]}, slack_error:null}')
   # Guard: refuse to append an entry whose post_text came out empty.
   if [ "$(printf '%s' "$entry" | jq -r '.post_text|length')" -eq 0 ]; then
     echo "EMPTY_POST_TEXT for $key — re-scrape the card body before appending" >&2
   else
     tmp=$(mktemp); jq --argjson e "$entry" '. + [$e]' "<COMMENTS_FILE>" > "$tmp" && mv "$tmp" "<COMMENTS_FILE>"
   fi
   ```

3. Clean up: `rm -f "./tmp/filtered-<key>.txt"`.

Storing the full `post_text` on every filtered entry is what lets a later run (or a human) re-classify after tuning `interests.md` **without re-scraping** — so an entry that trips the `EMPTY_POST_TEXT` guard must be fixed (re-scrape the body), not written empty.

#### 3b. Expand truncated bodies

If a card body ends in `…` or contains a `see more` button, click it BEFORE hashing:

**`browser_evaluate` cannot pass arguments to the function** — it only ever calls it with zero args (or a single resolved element ref). So do NOT write `(author) => {…}` and expect `author` to arrive; it never will. Instead inline the author as a literal: copy the function below and replace `<AUTHOR>` with the card's exact author name as a JS string (double-quoted; escape any `"` inside it), then pass the resulting **zero-arg** function.

```js
() => {
  const author = "<AUTHOR>";  // ← substitute the exact author name before calling; do NOT pass an argument
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

#### 3d. Recover the post permalink via "Copy link to post"

Only for a card that just passed all filters (step 8). Two moves: **(i)** one `browser_evaluate` that clicks "Copy link to post" and captures the `lnkd.in` short link LinkedIn writes; **(ii)** one Bash `curl` that resolves that short link to the canonical permalink + URN.

**Move (i) — capture the copied short link (ONE `browser_evaluate`).** The control-menu "Copy link to post" copies a `https://lnkd.in/p/<code>` short link. Do **NOT** read the clipboard — `navigator.clipboard.readText()` throws "Document is not focused" in the unfocused cron tab (the historical failure). Instead **intercept `navigator.clipboard.writeText` before clicking** and capture the string LinkedIn writes (focus- and permission-independent; verified 2026-07-14).

**`browser_evaluate` CANNOT take arguments** — passing `async (author) => {…}` and expecting `author` to be supplied is the #1 cause of this agent stalling (it retries the tool call forever hunting for a way to pass the arg). There is none. Inline the author as a literal instead: copy the function below, replace `<AUTHOR>` with the card's exact author name as a double-quoted JS string (escape any `"`), and pass the resulting **zero-arg** function to `mcp__playwright__browser_evaluate`.

```js
async () => {
  const author = "<AUTHOR>";  // ← substitute the exact author name before calling; do NOT pass an argument
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  // Intercept the clipboard WRITE (not read) — captures the URL regardless of focus/permission.
  const cap = { writeText: null, execCommand: null, selection: null };
  try {
    const origWrite = navigator.clipboard && navigator.clipboard.writeText
      ? navigator.clipboard.writeText.bind(navigator.clipboard) : null;
    if (origWrite) navigator.clipboard.writeText = (t) => { cap.writeText = t; try { return origWrite(t); } catch (e) { return Promise.resolve(); } };
  } catch (e) {}
  const origExec = document.execCommand.bind(document);   // legacy fallback (hidden-textarea copy)
  document.execCommand = (c, ...r) => {
    if (String(c).toLowerCase() === 'copy') {
      try { cap.selection = (document.getSelection() || '').toString(); } catch (e) {}
      const ae = document.activeElement;
      if (ae && (ae.tagName === 'TEXTAREA' || ae.tagName === 'INPUT')) cap.execCommand = ae.value;
    }
    return origExec(c, ...r);
  };
  const btns = Array.from(document.querySelectorAll('button[aria-label*="control menu"]'));
  const btn = btns.find(b => (b.getAttribute('aria-label') || '').includes(author));
  if (!btn) return { shortUrl: null, err: 'no-menu-btn' };
  btn.scrollIntoView({ block: 'center' });
  await sleep(300);
  btn.click();                                   // open the control menu
  await sleep(800);
  // "Copy link to post" — match by visible text (menu DOM classes are obfuscated)
  const cand = Array.from(document.querySelectorAll('[role="menuitem"], [role="button"], button, span, div'))
    .find(el => /^copy link to post$/i.test((el.innerText || '').trim()));
  if (!cand) { document.body.click(); return { shortUrl: null, err: 'no-copy-item' }; }
  cand.click();
  await sleep(700);
  const captured = cap.writeText || cap.execCommand || cap.selection || null;
  // dismiss any lingering menu/toast
  document.body.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
  document.body.click();
  // If LinkedIn ever copies a raw URN again, pull it straight out; otherwise return the short link.
  let urn = null, m; const s = captured || '';
  if ((m = s.match(/urn:li:(activity|ugcPost|share):(\d+)/)))               urn = m[0];
  else if ((m = s.match(/urn%3Ali%3A(activity|ugcPost|share)%3A(\d+)/i)))   urn = 'urn:li:' + m[1] + ':' + m[2];
  else if ((m = s.match(/activity-(\d{15,25})/i)))                         urn = 'urn:li:activity:' + m[1];
  return { shortUrl: captured, urn, err: captured ? null : 'no-capture' };
}
```

Wait ~1 second after the call. Read the return:
- If it already carries a `urn` (rare — only if LinkedIn reverts to copying raw URNs), use it directly: `post_url = https://www.linkedin.com/feed/update/<urn>/`, done.
- If it carries a `shortUrl` (the normal `https://lnkd.in/p/<code>` case) but no `urn`, go to **move (ii)**.
- If `shortUrl` is null (any `err`, empty/undefined return, or the tool call itself erroring) — treat that single call as the whole attempt: set `urn: null`, `post_url: null`, move on, and draft the post anyway.

**Move (ii) — resolve the short link to the canonical permalink (ONE Bash `curl`).** `lnkd.in/p/<code>` 301-redirects to `…/posts/<slug>-<activityId>-<hash>/`; extract the 15–25-digit activity id and build the canonical URN + permalink. Substitute the captured `shortUrl`:

```bash
short="<shortUrl>"
# Follow redirects (HEAD); take the last Location that looks like a post/activity URL.
resolved=$(curl -sIL -A "Mozilla/5.0" "$short" 2>/dev/null \
  | grep -i '^location:' | tr -d '\r' | sed 's/^[Ll]ocation: *//' \
  | grep -iE '/posts/|/feed/update/|activity|share' | tail -1)
# The activity id is the long digit run in the slug tail (…-<id>-<hash>/).
id=$(printf '%s' "$resolved" | grep -oE '[0-9]{15,25}' | head -1)
if [ -n "$id" ]; then
  urn="urn:li:activity:$id"
  post_url="https://www.linkedin.com/feed/update/$urn/"
else
  urn=""                 # couldn't resolve — leave URN unknown
  post_url="$short"      # the lnkd.in short link is itself a clickable permalink; never null it out
fi
```

So an accepted post's `post_url` is: the canonical `/feed/update/…` permalink when the id resolved, else the `lnkd.in` short link, and only `null` when move (i) captured nothing at all. `urn` stays `null` unless the id resolved. **Never null out a `post_url` when you hold a short link** — that non-null clickable link is the whole point of this fix.

**Discipline.** Move (i) is STRICTLY ONE `browser_evaluate` call per card; move (ii) is ONE `curl` per card. Do **not** re-issue the evaluate with different params, do **not** experiment with `element`/`ref`/`target` arguments, do **not** loop. Total budget ≤`TARGET_COUNT` copy-link calls + `TARGET_COUNT` curls per fire; recovery must never consume more than a few seconds per card. Burning the fire's whole time budget flailing on the evaluate call (as happened when the function took an `author` argument) is the exact failure this rule exists to prevent — when in doubt, skip recovery and keep `post_url: null`.

**No "Show more results" button on the home feed** — LinkedIn just keeps loading infinitely. If `scrollHeight` stops growing across 3 consecutive scrolls AND no new keys arrive, treat as `feedExhausted = true`.

### 4. Close the tab you opened

`mcp__playwright__browser_tabs` with action `close` and the index recorded in step 2. Do not close any other tab.

### 5. Emit the contract

For each queued post, derive the two URL fields:
- `POST_i_URL` = the recovered `postUrl` from step 3d — the canonical `https://www.linkedin.com/feed/update/<urn>/` when the id resolved, else the captured `lnkd.in` short link. Emit `-` only when step 3d captured nothing at all.
- `POST_i_AUTHOR_URL` = the card's `authorUrl` (author profile link), else `-`.

Base64-encode each queued post's `bodyText`:

```bash
POST_1_TEXT_B64=$(printf '%s' "$bodyText" | base64 | tr -d '\n')
```

Final message shape (see contract at top).

## What you must not do

- Do **not** replace an existing browser tab. Always open a new one and close only the one you opened.
- Do **not** stop early because you've reached a page height — keep scrolling until the queue is full or `scrollHeight` stops growing for 3 iterations.
- Do **not** use `data-urn` selectors — LinkedIn stripped them from the home feed. Use the control-menu button aria-label instead.
- Do **not** invent URNs or permalinks. `POST_i_URN=-` when the id never resolved; `POST_i_URL` is the resolved canonical permalink, else the captured `lnkd.in` short link, and `-` only when step 3d captured nothing. `POST_i_AUTHOR_URL` is always the author profile link. Never emit `POST_i_URL=-` while holding a captured short link — that clickable link is the fix.
- Do **not** pass arguments to `mcp__playwright__browser_evaluate` (no `author` arg, no `target`/`element`/`ref` fishing). It can't take them. Inline any per-card value (e.g. the author name) as a literal inside a zero-arg function. Getting this wrong makes the agent retry forever and burns the entire fire.
- Do **not** retry the step-3d recovery. One `browser_evaluate` (capture short link) + one `curl` (resolve it) per card; on any failure, set `post_url: null` and continue. Permalink recovery is best-effort and must never block drafting. Do **not** read the clipboard (`navigator.clipboard.readText()`) — it throws "Document is not focused" in the cron tab; intercept `writeText` instead.
- Do **not** invent post text. If you can't scrape a card cleanly, skip it.
- Do **not** classify without reading `interests.md`.
- Do **not** write entries for promoted or repost cards. They're not stable identifiers and must stay out of the seen-set so a later original isn't suppressed.
- Do **not** hand-write JSON into `<COMMENTS_FILE>` — always build entries with `jq -n` and append with `jq '. + [$e]'`, so the array never gets corrupted.
- Do **not** append a filtered entry with an empty `post_text`. It MUST carry the full scraped body (via `--rawfile`); if the guard prints `EMPTY_POST_TEXT`, re-scrape the card body and retry rather than writing a textless entry.
- Do **not** add prose after the final contract block.

## Failure modes

- Page never loads / 429 / auth wall → snapshot for debug, close tab, emit `ERROR=NETWORK` (or `ERROR=AUTH` if a login form appears).
- No `button[aria-label*="control menu"]` buttons found at all → `ERROR=SCRAPE`.
- Cannot read or append to `<COMMENTS_FILE>` (jq error, unwritable path) → `ERROR=FS`.
- Anything else → `ERROR=UNKNOWN` with a short prose explanation **before** the contract line.
