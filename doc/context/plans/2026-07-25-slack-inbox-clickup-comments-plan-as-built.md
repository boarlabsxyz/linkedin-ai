# As-built — Slack-inbox links + ClickUp Comments list for the comment pipeline

_2026-07-25. The original (codex-reviewed, v4) plan lives next to this file:
`2026-07-25-slack-inbox-clickup-comments-plan.md`. This document is that plan
as actually implemented and live-tested — same structure, with every deviation
and implementation-discovered fact called out as **[as-built]**._

## What shipped (files)

| File | Role |
|---|---|
| `.claude/skills/linkedin-comment-hourly/fast/keys.mjs` | **[new]** `authorSlug`/`normText`/`makeKey`/`fuzzyId` extracted verbatim from `gather-feed.mjs`; both gathers import it so cross-source identities are byte-identical. |
| `.claude/skills/linkedin-comment-hourly/fast/gather-feed.mjs` | imports `keys.mjs`; new `--extra-seen-file` (inbox `keys.json` → same-fire cross-source dedup). No other behavior change. |
| `.claude/skills/linkedin-comment-hourly/fast/gather-inbox.mjs` | **[new]** deterministic inbox gather: human-message filter (`bot_id` absent + `user` present + subtype null/`file_share`/`thread_broadcast`), link extraction (text `<url|label>` + `attachments[].from_url/original_url` + recursive `blocks[]` link walk), normalized-URL job queue with `requests[]` provenance, disposition-aware ledger dedup, pending/dead durable queues with revival, 3-day edit-overlap window, browser fetch of post pages, contract + `keys.json` + `proposed-state.json` + conservation `manifest.json`. Exit 0/10/20/21/22/23. |
| `.claude/skills/linkedin-comment-hourly/read-slack-inbox.sh` | **[new]** pinned-haiku mint micro-call (bearer captured into a shell variable via command substitution under `perl -e 'alarm'` — never on disk) + paginated `curl` (`--connect-timeout 10 -m 30`, ≤20 pages, refuses a partial snapshot) → `messages.json`. |
| `.claude/skills/linkedin-comment-hourly/run-hourly.sh` | inbox stage before the feed loop under its own `pl_spawn_killer` watchdog (`INBOX_WATCHDOG_SECS=360`); `validate_inbox_contract` (provenance, per-post identity, MODE whitelist, no `/feed/update/`, watermark == snapshot max (string-exact) or current, proposed-state shape, conservation arithmetic); inbox-only drafting prompts on feed-0/feed-failed paths (except exit 31); reconcile-only prompt on quiet fires; postcondition-gated `install_inbox_state` before the commit section; bookend inbox counts + ⚠️ variant; `CLAUDE_TIMEOUT_SECS` 2400→3000. |
| `.claude/skills/linkedin-comment-hourly/SKILL.md` | Step 1b (inbox contract, MODE semantics), Step 2a-0 cross-source dedup gate (covers the legacy-fallback path), Step 2b rewritten (ledger-first ordering; search-first ClickUp create; draft-failure = deliver-anyway), Step 2c reconciliation, new entry fields, report format, new must-nots. |
| `.claude/skills/linkedin-comment-hourly/references/self-heal.md` | inbox is non-heal by design; heal sessions must never touch the state file. |
| `linkedin-compain/slack-inbox.json` | **[new]** seeded at the documented deployment cutoff `1784992000.000000` (just before Peter's example message). |
| `fast/fixtures/slack-messages.json`, `fast/fixtures/fetch-stub.json`, `fast/test-gather-inbox.sh` | **[new]** committed fixture suite (sanitized real proxy capture + real unfurled post body) — 45 assertions, all green. |

## [as-built] Deviations and discoveries vs the v4 plan

1. **ClickUp task identity footer is plain `key: <key>`, not `_key: <key>_`.**
   ClickUp renders markdownContent and STRIPS styling — the stored description
   text has no underscores, so the planned styled-footer grep would never
   match. Discovered live on task `86cawv15n`.
2. **Adoption identity re-ordered: Source-field URL is primary.** The MCP
   `getTask`/`listTasks` outputs TRUNCATE descriptions (the key footer is
   invisible through them), but custom fields render fully — so Step 2b-3
   adopts on (1) exact Source-field URL from the task index, then (2) the
   plain `key:` line via the REST proxy (`mintRestBearerForCurl` + `curl
   …/clickup/tasks/<id>` returns the full description) for name candidates
   without a Source value (the create-then-crash window). Fail closed
   otherwise.
3. **Post-page DOM differs from the planned selectors** (probed live):
   the bare `.update-components-actor` block does not exist on `/posts/`
   pages — only `.update-components-actor__title` / `__description` /
   `__container`; the title's innerText doubles the name (visible + a11y
   copies) and appends `• 2nd`-style badges → the scrape prefers the
   `aria-hidden` span, strips at `•`, and collapses exact `X X` doubling.
4. **The see-more toggle keeps its class after expansion** (reads "…see
   less") — the truncation assert matches only a COLLAPSED toggle (class
   AND "see more" text), otherwise every successful expansion would read as
   still-truncated.
5. **The Comments list has its own status set** (default `to do`) — not the
   Posts list's ideation/drafting/published. Tasks are created at the list
   default, as planned.
6. **`/feed/update/` copy-link recovery** shipped as a simplified single-post
   control-menu variant (`COPY_LINK_RECOVER`) rather than the feed gather's
   fgId-scoped machinery; failure keeps the link pending per plan §B6. Not
   yet exercised live (no `/feed/update/` input has occurred).
7. **Relative CLI paths resolve against the repo root**, matching
   `gather-feed.mjs` convention — callers must pass absolute paths for
   run-scoped files (the driver does; a test harness initially didn't).
8. **Alias-of-in-flight-reprocess edge**: a second URL alias matching a
   ledger key already being reprocessed proceeds to fetch and merges
   post-fetch (a pre-fetch bucket increment would have miscounted).
9. **Drive REST bridge outage observed during E2E** (`500
   unauthorized_client` on every fetch, same systemic failure as 2026-07-21):
   prep-refs degraded to the stale cache and drafting still delivered —
   the graceful-degradation path got a live validation for free.
10. **`INBOX_MAX_LINKS=5`** (plan said 5; env-overridable), attempts cap 5,
    edit overlap 3 days (constant duplicated in `read-slack-inbox.sh` and
    `gather-inbox.mjs` — keep in sync, noted in both).
11. **The mint micro-call shape had to be empirically pinned** (three failure
    modes in sequence, all fixed in `read-slack-inbox.sh`):
    - prompt on stdin → haiku ignores it entirely (the exact pl_post_slack
      pin, re-confirmed) → prompt goes inline as the positional arg;
    - a bare user-level "output the token" ask → **sonnet refuses as
      credential-exfiltration prompt injection** and haiku declines because
      the tool's own description says to skip it for shell-less callers →
      the pipeline context moved into `--append-system-prompt` (naming the
      calling script; shell runs the curl) + `Read` allowlisted so the model
      can verify the caller; 2/2 haiku mints after 0/2;
    - a parseable token can still be mis-transcribed by the model and 401
      (observed once) → the script probes the bearer with a 1-message read
      and escalates haiku → sonnet until a probe returns 200.

## [as-built] Live E2E evidence (2026-07-25)

- Slack read: 15 messages / 1 human captured via minted bearer + proxy, 1 page.
- Fetch: davidlinthicum post scraped in ~5s — author, headline, 2584-char
  fully-expanded body, canonical `/posts/` URL, urn `urn:li:ugcPost:…` from
  the slug; key `david-linthicum-8bcaa5c2`.
- Drafting: 3 variants (Clarifying / Disagree-and-argue / Provocative) from
  the cached-refs draft agent.
- Delivery: ledger entry (all new fields) → ClickUp task `86cawv15n`
  (name, full post body, Source field, `key:` footer) → Slack thread
  `1785003419.330329` (summary + post + 3 draft replies) → entry updated
  with task id + Slack ts's → watermark installed at `1784992193.489909`.
- Reconciliation/adoption: blanked task id → search-first found `86cawv15n`
  by Source URL (and by REST-proxy `key:` grep) → adopted, no duplicate.
- Dedup regression: immediate re-gather → `POSTS_FOUND=0`,
  `INBOX_DUPLICATES=1`, watermark stable — idempotent.
- Driver functions: isolated harness — real contract validates; non-numeric
  POSTS_FOUND / smuggled `/feed/update/` URL / forged watermark / broken
  conservation all rejected; install blocked on missing ledger key, proceeds
  when present.
- Fixture suite: 45/45 assertions (bot filter, ordering, extraction+
  normalization+coalescing, cap overflow→backlog, all four dedup
  dispositions, edit-window replay, dead revival by new message only,
  watermark exactness, conservation, exact body text, pending→dead at cap,
  tombstone immediate-dead, exit codes).
- Driver smoke (DRY_RUN full-run, stubbed 0-post feed gather, real inbox
  stage): exit 0 — in-driver mint + paginated read (26 msgs), correct dedup
  of the already-delivered link (`INBOX_DUPLICATES=1`, 0 posts), direct state
  install advancing the watermark past the new bot messages, DRY_RUN commit
  skip, bookends posted. An earlier smoke also proved the ❌ failure bookend
  fires from the EXIT trap on a preflight death.

## [as-built] Solution-critique rounds (post-implementation codex reviews)

- **Round 1** (10 findings; all accepted except as noted): post-fetch ledger
  matches now build rows from the FRESHLY fetched fields — 108 legacy
  drafted-without-task entries carry a profile URL or none, and a task from
  stale fields would ship the wrong link; clickup-only additionally backfills
  the entry's `post_url` (1). Tombstone detection no longer runs once the
  post container rendered — a valid post *opening* with "this post was
  deleted…" must not dead-letter (2). The clickup-only delivery gate requires
  mutation evidence (`clickup_task_id` or `clickup_error` non-null), not bare
  entry existence (3a). New dead letters are named URL+reason in the ⚠️
  bookend via `manifest.dead_new_detail` (4). Pagination fails hard on
  `hasMore` without a cursor + `curl -f` (5). `COPY_LINK_RECOVER` ported to
  the feed's hardened pattern (poll, execCommand fallback, finally-restore)
  (6). **Reprocess now atomically REPLACES the ledger entry's key/body/urls
  with the fetched row's** — 75 real off-topic entries recompute to different
  keys, and the old half-updated scheme would have wedged the watermark on
  any re-drop of one (7). State install is atomic (`cp`→revalidate→`mv`) and
  failure degrades to a warning instead of aborting before the data landing
  (8). `scan_floor_ts` added to the state (immutable deployment floor) and
  clamped in both readers (9). New committed regression tests: blocks-only
  extraction, cross-message alias coalescing, legacy-key-mismatch reprocess,
  pre-floor exclusion, clickup-only fetched-fields, plus
  `fast/test-driver-inbox.sh` (versioned driver-function harness incl. the
  per-mode gates) (10). Not taken: retro-scanning the 149 legacy `source:null`
  entries into reconciliation (no-backfill is by design; an explicit re-drop
  handles any of them and makes the entry post-feature-visible), and
  browser-path fixtures (tombstone-in-valid-body, multi-page pagination)
  — not reachable without an HTTP/browser stub, documented instead.

- **Round 2** (7 findings): `hasMore` must be an actual boolean — missing/
  null/garbage on a page refuses the snapshot (1). Same-fire reconciliation
  skips keys already attempted this session (ambiguous against the one-shot
  index; next fire's fresh index adopts them) and confirmed creates join the
  in-memory index (2). **The `MAX_LINKS` cap now governs ALL actionable
  rows** — pre-fetch clickup-only matches previously bypassed it and 41
  current ledger entries are exact-matchable, enough to blow the drafting
  watchdog; overflow goes to the durable queue and re-resolves statelessly
  (3). The clickup-only gate requires `source` set plus a NON-EMPTY task id
  or error string; the full delivery-token scheme was rejected — a stale
  marker can only mis-time the watermark, never lose delivery, because the
  reconciliation track covers any `source`-set entry without a task (4).
  Watermark must equal exactly `max(current, snapshot-max)`; the proposed
  state must live inside the out-dir, carry that exact `last_ts`, preserve
  `scan_floor_ts`, and the predicate is re-checked immediately before the
  install `mv` (5). Clickup-only ledger mutations persist ALL fresher fetched
  fields incl. body/author (6). `POST_<i>_URL=-` now rejects the contract —
  inbox rows are never legitimately linkless (7). New tests: linkless-URL and
  stale-watermark rejections.

- **Round 3** (4 findings, all accepted in bounded form): **completion
  semantics** — a drafted entry is DONE only with BOTH a task id and Slack
  evidence (`slack_ts`/`slack_error`); a kill between the ledger write and
  the Slack posts now yields a `clickup-only` row with `NEED_SLACK=1` whose
  Slack leg is re-delivered from the entry's stored `variants`, and the
  install gate demands evidence for both legs (1 — the full nonterminal
  state machine remained unnecessary: the ledger's persisted variants make
  the Slack leg reconstructable, so a flag suffices; note the FEED pipeline
  has the same pre-existing kill window, unchanged by this feature and out
  of its scope). `me_message` joins the human subtypes (2). Pending URLs are
  re-resolved against the current ledger before allocation, so an overflowed
  clickup-only job comes back fetchless instead of burning attempts into a
  false dead-letter (3). Post-fetch dedup checks the resolved canonical URL
  before key/fuzzy — an alias of a post whose opening was edited between
  fires can no longer duplicate (4; persisting input aliases in the ledger
  rejected as redundant given the canonical check). New tests: fetchless
  pending completion, me_message, edited-opening alias dedup, NEED_SLACK
  emission + both-legs gate cases (suites now 62 + 13 assertions).

- **Round 4** (4 findings): Slack completion redefined as the THREAD's
  `post_reply_ts` (the parent alone means a kill landed mid-thread); the
  NEED_SLACK re-delivery resumes under an existing parent instead of posting
  a duplicate one; the separate draft-error field was rejected (reopens the
  settled no-draft-retry design — draft failures stay terminal-and-visible)
  (1). The install gate is UNIFIED: every mode now requires `source` + a
  non-empty ClickUp outcome + (unless NEED_SLACK=0) a Slack thread outcome —
  a "successful" session that wrote ledger entries but skipped delivery can
  no longer consume messages; a separate Slack-reconciliation track stays
  unnecessary because a blocked watermark replays the message into a
  NEED_SLACK completion row (2). A fuzzy match is disqualified when both
  sides carry differing canonical URLs — same-author boilerplate openers on
  distinct posts can't collapse into a false dup; stronger body-similarity
  scoring for URL-less legacy pairs rejected as unwarranted (3). `keys.json`
  rows carry normalized URLs and the SKILL's Step 2a-0 union gate compares
  them, catching an edited-body same-post duplicate across sources; the
  in-feed post-recovery recheck was rejected — it would touch the
  battle-tested feed acceptance path for a triple-coincidence edge the union
  gate already covers (4). Suites: 65 + 15 assertions, green.

- **Round 5** (final; 3 findings): Slack reply timestamps are journaled
  incrementally after EACH call (parent / post-reply / every draft reply) and
  a NEED_SLACK resume first reads the existing thread and adopts replies that
  already landed — a kill mid-thread can no longer cause a duplicated reply
  (1). Bare/code-formatted URLs (Slack keeps them as plain text — no `<>`
  token, no link block) are now extracted via a whitelist-guarded sweep over
  message text and every block text node (3). Rejected: URL-salted keys for
  identical-body republishes under a new permalink (2) — identity is
  deliberately content-based across the entire pipeline (feed, ledger,
  ClickUp footer), an identical body yields identical drafts, so consuming
  the re-submission as a duplicate of the same content is the intended
  semantic. Final suites: 66 + 16 assertions, green. Loop closed after 5
  rounds; finding severity declined monotonically (data-loss bugs → kill
  windows → formatting edge cases).

## [as-built] Operational notes

- **Not committed.** All of this sits in the working tree per repo git rules.
  Until it lands on main, the next scheduled fire (Tue 05:28 UTC) knows
  nothing about the inbox; the seen-set entry for the davidlinthicum post and
  the watermark exist only locally. Landing before Tuesday avoids nothing
  being re-drafted (the fire won't re-draft it — it's a Slack-only input the
  old pipeline ignores) but IS required for the feature to run on schedule.
- CLAUDE.md skill-row/ledger-shape updates are deferred to the
  `common-update-memory` pass at commit time, per convention.
- First scheduled fire after landing validates the CI path (runner keychain →
  mint micro-call → proxy reachability) — watch the bookend's `inbox:` counts.
