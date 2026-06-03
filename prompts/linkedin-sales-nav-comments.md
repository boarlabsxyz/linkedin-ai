# Plan-mode prompt — `linkedin-sales-nav-comments` skill

Paste the block below into Claude Code while in **plan mode** to design a daily skill that scrapes the Sales Navigator "OpenSource AI" lead-alerts feed and posts comment ideas to Slack.

The findings the prompt relies on were verified live on 2026-06-03 via MCP Playwright (logged in as Peter Ovchynnikov) and `WebFetch`.

## Findings recap

- **Tooling:** `WebFetch` cannot read Sales Nav — both URLs return only the page title (`Sales Navigator`). The MCP Playwright browser is already logged in and renders the lead-list URL directly.
- **DOM (verified 2026-06-03):**
  - Alert cards: `article.alert-card-new`.
  - Alert type + lead member ID: `data-alert-id` URN, e.g. `urn:li:notificationV2:(urn:li:fs_salesProfile:(...,NIL,NIL),LEAD_SHARED_UPDATE,urn:li:uniqueSuffix:(urn:li:member:<id>,<suffix>))`.
  - Lead Sales Nav profile + display name: `a.alert-card-new__headline-text-link` (and `aria-label="View profile for <Name>"`).
  - Post body + company + title + post age: `.alert-card-new__lockup-text-content` `innerText` (body appears twice — dedup the doubled text).
  - Canonical post URL: click the `View` `<button>`, wait for `div[class*="_sidesheet"]` to load, then regex its HTML for `urn:li:share:<id>`. URL = `https://www.linkedin.com/feed/update/urn:li:share:<id>/`.
- **Volume:** ~11 cards on initial render; infinite-scroll loads more (25 after one scroll). Same lead repeats often — dedup by member ID is required.
- **Alert types observed on this list:** only `LEAD_SHARED_UPDATE` so far. Others (likes/comments/mentions) may surface; v1 should skip unknown types.

## The prompt

```
Design a skill called `linkedin-sales-nav-comments` that runs daily, scrapes the
"OpenSource AI" Sales Navigator lead-alerts feed, picks the comment-worthy
posts, generates comment variants via the existing `linkedin-comment-ideas`
skill, and posts them to Slack. Produce a step-by-step implementation plan
covering structure, scraping, generation, Slack delivery, and scheduling.

Constants known up front:
- Sales Nav lead-list URL: https://www.linkedin.com/sales/home?alertGroup=LEAD&listId=7451883417308237824
- The Sales Nav home URL https://www.linkedin.com/sales/home is auth-walled.
  WebFetch returns only the page title. Use MCP Playwright; the existing
  browser session is already logged in as Peter Ovchynnikov.
- Existing repo skill to reuse for comment generation:
  `.claude/skills/linkedin-comment-ideas/` (SKILL.md + references/strategies.md).
  Don't reimplement the voice anchor, structure, or strategies — call into it
  with each chosen post's text.
- Existing repo agent that demonstrates serial Playwright-MCP discipline and
  shows the conventions to follow: `.claude/agents/linkedin-stats-gather-posts.md`.
- Slack MCP tools available: postMessage, openDm, listChannels, listUsers.
- Scheduling: use the `schedule` skill (cron). Avoid `loop`.

DOM facts the plan must rely on (verified 2026-06-03):
- Each alert: `article.alert-card-new`.
  - `data-alert-id` URN contains the alert type (e.g. `LEAD_SHARED_UPDATE`)
    and `urn:li:member:<memberId>` for the lead.
  - Lead name + Sales Nav profile URL: `a.alert-card-new__headline-text-link`
    (aria-label `View profile for <Name>` on the parent anchor).
  - Post body + company + title + age: `.alert-card-new__lockup-text-content`
    `innerText` (note: post body repeats — strip the duplicate).
  - "View" is a `<button>` whose click opens a side-panel
    `div[class*="_sidesheet"]`. After the panel loads, its HTML contains
    `urn:li:share:<id>`. Canonical URL:
    `https://www.linkedin.com/feed/update/urn:li:share:<id>/`.
- Infinite-scroll: initial render ~11 cards; scrolling the page (or
  `.alerts__feed`) to the bottom loads more (~25 after one scroll).
- Same lead repeats often. Need dedup per memberId and a per-lead cap.
- On this list, all observed alerts so far are LEAD_SHARED_UPDATE. Other
  alert types may appear (likes/comments/mentions); the scraper should
  read the type from `data-alert-id` and skip unsupported ones for v1.

Ambiguities to resolve in the plan (ask me before finalising):
1. Does "3 options" mean:
   (a) one post per day, 3 comment variants for that post (matches what
       `linkedin-comment-ideas` already produces); or
   (b) three different posts, one comment per post; or
   (c) three different posts, three variants per post (9 comments total)?
2. Slack target: which channel ID, or post to my self-DM? If channel, run
   `listChannels` to surface options.
3. Selection heuristic for "comment-worthy" when there are >N candidates:
   prefer most-recent? Prefer leads I haven't commented on this week
   (and how is that state tracked)? Prefer posts with embedded reshare?
4. Run cadence: every weekday morning my local time, or daily at a fixed
   UTC hour? What timezone?
5. Should the skill also surface posts I might want to *not* engage with
   (so I can clear those alerts), or only positive picks?

Implementation plan must cover:
A. Skill skeleton: SKILL.md (flow, constants, trigger phrases), and any
   references/ files. Match the conventions in CLAUDE.md (skill folder
   layout, links to `.claude/skills/linkedin-comment-ideas/`, bundled .sh
   only if Bash logic >~10 lines).
B. Scraper logic — using Playwright MCP serially (the same browser instance
   is shared across calls; no parallel fan-out):
   - Open the lead-list URL in a new tab.
   - Scroll to load N alerts (N as a constant; default 50).
   - For each card: extract memberId, name, sales-profile URL, company,
     title, post-age, post body (dedup duplicated text), alert type.
   - Dedup by memberId, keeping most-recent only (or top-K per memberId
     based on the resolved heuristic).
   - Filter to alert types we support (start with `LEAD_SHARED_UPDATE`).
C. Per chosen alert: click its View button, wait for the side-panel
   `div[class*="_sidesheet"]` to finish loading, regex its HTML for
   `urn:li:share:<id>`, build canonical post URL, close panel.
D. Comment generation: for each chosen post, invoke `linkedin-comment-ideas`
   with the scraped post text (already in-hand — skip its Step 1 Playwright
   loader by passing pasted-text mode). Capture the 2-3 variants it returns.
E. Slack delivery: format one Slack message per chosen post with:
   - Lead name + headline (company, title) + Sales Nav profile URL
   - Canonical LinkedIn post URL
   - Post body excerpt (~400 chars, with truncation marker)
   - 2-3 comment variants, each labelled with strategy + one-line rationale
   - Source: which list it came from + alert age
   Use Slack MCP `postMessage` (channel ID as constant). Each variant in a
   code block for easy copy-paste.
F. State: track which post URNs have already been pushed to Slack, so the
   next run doesn't repost. Suggest a small JSON file under e.g.
   `tmp/linkedin-sales-nav-comments/seen.json` (gitignored), keyed by share URN.
G. Scheduling: call the `schedule` skill to register a daily cron entry that
   invokes this skill at the agreed time.
H. Error handling: explicit cases for (i) Playwright session expired /
   logged out (stop and tell me); (ii) zero new alerts (no Slack post, log
   only); (iii) side-panel never reveals share URN (skip that card, continue
   others); (iv) Slack MCP failure (retry once, then save the message to
   `tmp/` and notify me on next run).

Conventions to follow (from CLAUDE.md):
- TypeScript not needed — this is a skill, not application code.
- New constants (list ID, Slack channel) go in SKILL.md as a Constants table.
- Update CLAUDE.md to add the new skill row.
- Do not commit. I will run `common-pr-commit` separately.

Output the plan as: skill folder tree → SKILL.md outline → references file
outline (if any) → step-by-step run flow → list of decisions you need from
me before coding.
```
