# 2026-07-24 — linkedin-comment-hourly incident

Auto-created by run-hourly (attempt 1, exit 10). Log tail:

```
POST_4_URL=https://www.linkedin.com/posts/cadrlife_why-linus-is-right-and-ai-is-wrong-i-wrote-share-7486107513558327296-9URF/
POST_4_AUTHOR_URL=https://www.linkedin.com/in/cadrlife/
POST_4_AUTHOR=Ray Myers
POST_4_HEADLINE=In search of code worth writing
POST_4_TIME_AGO=14h
POST_4_TEXT_FILE=/Users/peterovchinnikov/github_runner/actions-linkedin-ai/_work/linkedin-ai/linkedin-ai/tmp/gather-feed/2026-07-24T07-54-03Z-a1/post-4-ray-myers-1bda8609.txt
POST_5_KEY=shruti-mishra-8d009b71
POST_5_URN=urn:li:ugcPost:7485665054722256898
POST_5_URL=https://www.linkedin.com/posts/heyshrutimishra_sundar-pichai-just-reminded-everyone-that-ugcPost-7485665054722256898-Vt1s/
POST_5_AUTHOR_URL=https://www.linkedin.com/in/heyshrutimishra/
POST_5_AUTHOR=Shruti Mishra
POST_5_HEADLINE=Founder at Postey AI
POST_5_TIME_AGO=1d
POST_5_TEXT_FILE=/Users/peterovchinnikov/github_runner/actions-linkedin-ai/_work/linkedin-ai/linkedin-ai/tmp/gather-feed/2026-07-24T07-54-03Z-a1/post-5-shruti-mishra-8d009b71.txt
[102.4s] done: 5/5 accepted, 4 off-topic, 0 already-commented, 0 reposts, 5 promoted, 5 scrolls, 2 classify calls, 102s
```

## Attempt 1 heal (post-landing) — 2026-07-24 ~08:25 UTC

### Symptom

Exit 10 with `PERMALINKS_MISSING=1`: accepted post `jozsef-mark-k-86cd8095`
shipped to Slack with no post link (`POST_1_URN=-`, `POST_1_URL=-`); the other
4 accepted posts got verified permalinks. Drafts landed and merged normally
(post-landing heal — no rerun this fire; every change below is unverified
next-run). Key log lines — note there is NO error detail for the failure:

```
[51.0s] accepted 1/5: jozsef-mark-k-86cd8095 (no permalink)
[55.1s] accepted 2/5: mradul-jain-ed577933 (permalink ok)
PERMALINKS_MISSING=1
```

No `recovery … captured nothing` line and no `retrying once` line anywhere in
the log — which (reading `recoverPermalink`) proves the clipboard capture
SUCCEEDED on the first try with an `^https?://` value, `verifyPostPage`
returned null, and the captured URL did not match the `https://lnkd.in/`
keep-fallback: the only path that reaches null post_url with zero log output.

### Evidence

1. `tmp/gather-feed/…-a1/post-1-jozsef-mark-k-86cd8095.txt` — the scraped body
   BEGINS with a bare `Connect` line (feed-card header chrome: the author is
   not a connection, so the card header shows a Connect button; `parseCard`'s
   body-start skip list has `Follow|Following|View my services|Promoted|Visit
   my website` but NOT `Connect`, gather-feed.mjs:615). So
   `normBody.slice(0,80)` = `"connect ai is forcing an uncomfortable career
   question: am i replaceable? if y"` — a prefix that can never appear on the
   rendered post page → `bodyOk` false; body length ≥ 40 makes it
   `distinctive`, so the author-anchor match cannot rescue it → verify
   returns null (its reason lines are vlog-only; run-hourly.sh runs the
   gather WITHOUT `--verbose`, so nothing surfaced).
2. Live probe (single navigation to the author's
   `/in/joshy333/recent-activity/all/`, same clipboard interception as
   `RECOVER_EVAL`): "Copy link to post" wrote
   `https://www.linkedin.com/posts/activity-7484722334889619457-PnKu?utm_source=share&utm_medium=member_desktop&rcm=ACoAA…`
   via `navigator.clipboard.writeText` — a FULL canonical /posts/ URL, not an
   `lnkd.in` short link. The desktop copy-link now (at least sometimes) skips
   the short-link indirection entirely. That is why the unverified-keep
   fallback (allowlisted to `https://lnkd.in/` only) did not fire and the
   valid URL was dropped silently.

### Assumptions

- `Connect` header line leaked into the body and broke the verify body-prefix
  check — VALIDATED (text file starts with `Connect`; check logic read
  directly; probe confirmed the underlying URL is real and canonical).
- Capture itself worked and produced a full canonical URL — VALIDATED (log
  line-shape analysis + live probe reproduced the full-URL clipboard payload
  on the same post).
- The 4 successful posts either got lnkd.in short links or full URLs that
  verified cleanly (their bodies had no Connect leak — Follow IS stripped) —
  OPEN (indistinguishable from the log; both paths converge and neither
  logs at non-verbose level).
- Failure is NOT rate-limiting, auth, or menu drift (2026-07-21 class) —
  VALIDATED (menu rendered, copy item clicked, capture succeeded).

Additional probe results (pre-codex):

- The extracted-source parseCard harness (`$HEAL_DIR/parse-test.mjs`, drives
  the verbatim awk-extracted parser section) reproduces the leak: body first
  line `"Connect"` → FAIL. This is the failing pre-fix probe for the parser
  change.
- One verification navigation to the captured URL: renders the correct post
  (`bodyOk` true on the real body prefix, author anchor `/in/joshy333`
  present, no error banner), final canonical
  `https://www.linkedin.com/posts/activity-7484722334889619457-PnKu/` (urn
  `urn:li:activity:7484722334889619457`). Crucially the rendered page does
  NOT contain "connect ai is forcing…" — empirical proof the fire's
  identity check failed solely because of the Connect prefix.
- Seen-set scan: 14 stored entries (2 drafted, 12 off-topic, oldest
  2026-07-08) have `post_text` starting with `Connect\n` — the leak is as old
  as the fast gather. No other chrome-label prefixes (Subscribe/Message/…)
  exist in the corpus.
- Prior-data anomaly noticed in passing: `denys-osadchyi-0574bb1e`
  (2026-07-21, the fire that ran the legacy fallback) carries a banned
  `/feed/update/<urn>/` post_url — the fast path cannot emit that form, so it
  came from the legacy agent. Not touched by this heal; listed under open
  questions.

### Codex round 1

Brief: `$HEAL_DIR/codex-brief-1.md` (failure, evidence, planned fixes A/B/C,
seen-set question). Reply: `$HEAL_DIR/codex-reply-1.md`. Triage:

| Codex point | Verdict | Why |
|---|---|---|
| Other verify null paths (deadline / off-domain / non-posts path / error banner) could also explain the silence; log ALL of them, not just the two vlogs | valid | adopted — every null return in `verifyPostPage` now logs a reason code |
| Captured value might not equal the probe's reproduction; wrong-card capture possible (menu lookup is document-wide, LinkedIn recycles tagged nodes) | valid (latent) | identity-failure remains the overwhelming explanation for THIS fire (rendered page lacks the connect prefix); adopted a `bodyProbe` card-association check in `RECOVER_EVAL` (`card-recycled`) as the guard |
| "Not lnkd.in" was slightly overstated (case/http variants also miss the regex) | valid | doesn't change the conclusion; keep-chain now classifies via `new URL()` with explicit protocol/host checks |
| Add only observed `Connect`; no speculative Subscribe/Message/Ring-bell | valid | adopted — corpus scan found zero entries with those prefixes |
| Unify body-start + headline chrome lists; structural button-evidence in SCRAPE_CARDS | valid, deferred | refactor breadth wrong for an unverified post-landing fix — listed as follow-ups |
| Never log the query string (`rcm=` is member-associated; log lines get quoted into committed incidents) | valid | adopted — `urlForLog()` logs origin+pathname + `query=yes` flag only |
| Unverified keep of a captured canonical /posts/ URL is sound, but require https + exact `www.linkedin.com` + no userinfo/port + single-slug `/posts/` path | valid | adopted verbatim |
| Leave `urn: null` on unverified keeps (provenance clarity) | valid | adopted — urn stays a verified-slug-only field |
| C masks verifier regressions — add `PERMALINKS_UNVERIFIED` + manifest list | valid | adopted (contract key + `permalink_unverified` manifest list + always-on log); driver-side alerting on it deliberately NOT added — follow-up |
| `verify-links.mjs` prints OK when `authorOk=false` (verifies rendering, not identity) | valid | confirmed in source; fixed — `NOAUTHOR` now counts as bad |
| jq-correct the stored `post_text` (strip one leading `Connect\n`), never rewrite keys | valid | adopted, extended to all 14 affected entries (2 drafted, 12 off-topic) — same dedup semantics |
| Update SKILL.md contract docs if C ships | valid | adopted (SKILL.md + the stale CLAUDE.md `comments.json` fragment that still described `/feed/update/` post_urls) |

### Fix

All in `fast/gather-feed.mjs` unless noted:

1. `parseCard` body-start skip regex: added `Connect` (root cause — header
   chrome leak poisoned the body-hash key and the verify body prefix).
2. `verifyPostPage`: every null return now logs an always-on reason
   (out-of-time / off-domain / non-posts path / error banner / identity /
   nav exception); URLs logged via `urlForLog()` (origin+pathname only).
3. `recoverPermalink`: unverified-keep chain extended — a captured URL that
   fails verification is kept iff it parses as https + `www.linkedin.com` +
   no userinfo/port + `^/posts/[^/]+/?$` (query stripped, urn null), or is an
   `https://lnkd.in/` short link as before; both marked
   `permalinkUnverified`; anything else drops WITH a log line. New contract
   key `PERMALINKS_UNVERIFIED` + manifest `permalink_unverified` list keep
   wholesale verifier regressions visible.
4. `RECOVER_EVAL`: takes `{fgId, bodyProbe}` and refuses (`card-recycled`)
   when the tagged card no longer shows the candidate's body — a wrong-card
   URL must not ride the unverified keep.
5. `fast/verify-links.mjs`: a rendering page without the author is now
   `NOAUTHOR` and counts as bad (was: printed OK — rendering-only check).
6. Data repair (jq read-modify-write, keys/dispositions untouched, 252
   entries before and after): stripped one leading `Connect\n` from the 14
   affected `post_text`s so the fuzzy dedup bridge matches post-fix parses
   (the parser change would otherwise re-draft any of them that resurfaces);
   completed `jozsef-mark-k-86cd8095` with the probe-verified permalink
   (`urn:li:activity:7484722334889619457`,
   `https://www.linkedin.com/posts/activity-7484722334889619457-PnKu/`).
   Note: the Slack message for that draft already went out link-less; the
   repair completes the ledger, not the delivery.
7. Docs: SKILL.md contract section (two-shape permalink policy +
   `PERMALINKS_UNVERIFIED`), CLAUDE.md `comments.json` paragraph (also fixed
   the stale "canonical `/feed/update/<urn>/`" fragment), CLAUDE.md
   `## Incidents` link, known-history bullet in `references/self-heal.md`.

Alternatives rejected: rebuilding a `/posts/` URL from the card's leaked URN
(hard-banned — wrong-type 404s); relaxing the identity check to
prefix-after-first-line (fuzzier verification when the parser fix removes the
cause); driver/wrapper changes (none needed — `PERMALINKS_MISSING` handling
already covers the alarm path, and this was not a wrapper failure).

### Spot-verification

No full gather rerun (post-landing; next cron is the real test). Probes, each
against the LIVE extracted source (awk from the edited file), artifacts under
`$HEAL_DIR`:

- `parse-test.mjs` — the reconstructed failed card: body first line was
  `"Connect"` pre-fix (FAIL), is `"AI is forcing an uncomfortable career
  question:"` post-fix (PASS). Failing-then-passing probe of the same thing —
  this one is causally *fixed*, not recovered.
- `parse-collision-test.mjs` — control fixture for the accepted collision: a
  legit body whose first line is exactly `Connect` loses that line (same
  accepted risk class as `Follow`/`Following`; documented, not asserted).
- `direct-test.mjs` — 13 adversarial URL-classifier cases on the extracted
  `direct` IIFE source: canonical with tracking query → stripped keep;
  author-prefixed slug → keep; lnkd.in / http / bare-host / lookalike host /
  userinfo / port / `/feed/update/` / empty & nested `/posts/` paths / junk →
  all null. 13/13 PASS.
- Probe-normalization agreement: node-side `normText(body).slice(0,60)` found
  in the eval-side normalization of a reconstructed card innerText — PASS
  (guards against the card-association probe bricking every recovery).
- `node --check` clean on both edited scripts. `jq empty` clean on the
  repaired `comments.json`.
- Live verification navigation (1 nav): the captured canonical URL renders
  the right post — `bodyOk` true, author anchor present, no error banner, and
  the rendered text does NOT contain the connect-prefixed 80-char window —
  empirically confirming the fire's identity check failed for exactly the
  diagnosed reason.

### Unverified next-run changes

No WRAPPER or workflow edits. But HEAL_MODE=post-landing means there is no
rerun this fire: every gather-feed.mjs / verify-links.mjs change above is
live-unverified until the next cron (2026-07-25 05:28 UTC). Watch that fire
for: `PERMALINKS_UNVERIFIED` in the contract, `card-recycled` retries, and
any `verify <key>:` reason lines.

### Open questions

- Was the full-canonical clipboard payload an A/B rollout or the new default?
  The 4 verified posts this fire can't tell (both paths converge silently in
  the old code). The new reason-coded logs + `PERMALINKS_UNVERIFIED` will
  answer it within a few fires.
- `denys-osadchyi-0574bb1e` (2026-07-21, legacy-fallback fire) carries a
  banned `/feed/update/<urn>/` post_url in `comments.json` — the fast path
  cannot emit that form, so the legacy gather agent wrote it against policy.
  Left untouched (Slack delivery long done); consider a one-time repair
  and/or tightening the legacy agent's instructions if it is ever used again.
- Follow-ups deferred by restraint: unify the body-start and headline
  header-chrome lists in `parseCard`; have `SCRAPE_CARDS` collect structural
  (button-element) evidence for chrome lines instead of text matching;
  driver-side ⚠️/alerting when `PERMALINKS_UNVERIFIED` stays >0 across
  consecutive fires.

## Run summary — 2026-07-24T08:41:45Z
- attempt 1: exit 10, 102s
- gather outcome: accept (last exit 10); heal mode: post-landing; drafted delta: 5; fire ok
- post-landing heal: the fix could NOT be rerun-verified this fire — verify on the next fire
