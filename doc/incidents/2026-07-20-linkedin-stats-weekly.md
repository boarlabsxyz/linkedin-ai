# 2026-07-20 — linkedin-stats weekly scrape incident

## Attempt 1 heal — 2026-07-20 ~14:30 UTC

### Symptom

Exit 1 (UNKNOWN). Two independent failures in one run:

1. **posts phase dead** — `[22.1s] posts phase failed: no activity cards found`
   → contract `[posts] ERROR=SCRAPE`. The reason:'SCRAPE' throw maps to
   sev.unknown → exit 1. Navigation itself succeeded (no goto timeout); the
   22.1s ≈ 15s waitForSelector + short scroll loop ending 'end-of-feed', i.e.
   the page rendered but matched zero `div[data-urn^="urn:li:activity"]`.
2. **audience-canary** — `[account] PAGES_FAILED=audience-canary`. Audience
   demographics have been six EMPTY groups for 3 consecutive snapshots
   (2026-07-13, 2026-07-20 first fire, this attempt) while `total_followers`
   parsed fine. Probes later showed the parser works on the idle page — the
   emptiness correlates with the CONCURRENT fast-path layout, not with anchor
   drift (see Evidence). The canary (added after last week) now surfaces it.

Everything else was healthy and fast: metrics 42/44 OK (2 repost skips,
0 failed, normal 10–20s page times), dashboard/content/search/profile-views
parsed, comments-out discovered 3. NOT the 2026-07-20 nav-slowdown signature.

### Evidence

- The comments-out scraper anchors on the SAME `div[data-urn^="urn:li:activity"]`
  selector and worked minutes later in the same run on
  /recent-activity/comments/ — so data-urn is not globally gone; the change is
  specific to the /recent-activity/all/ surface.
- account.json weeks 2026-06-29 and earlier: 9–10 rows per demographic group;
  2026-07-13 onward: 0 rows in all six groups (week 2026-07-06 has no entry).
- Probe 1 (14:33 UTC, same runner, fresh single-tab context): /recent-activity/all/
  rendered 5 `div[data-urn^="urn:li:activity"]` cards within 8s — the surface
  works; attempt 1's zero-cards at 14:25 was transient, not durable drift.
- Probe 1: /analytics/creator/audience/ now has an "All" tab (new) before the
  six group tabs; the default view shows grouped summary triples.
- Probe 2 (idle browser): all six tab buttons exist with exact innerText match,
  clicks work, per-tab rows render within 800ms, URL unchanged, and the line
  structure (`label` / `pct%` pairs after the strip's "Company size", footer
  break at "About") parses cleanly with the EXISTING parser. So the parser is
  not wrong on an idle page — the failure is scrape-condition-dependent.
- Probe 3: a second about:blank page does NOT occlude the first
  (visibilityState stayed `visible`) — Playwright pages here are separate
  windows; couldn't reproduce hidden-tab rendering this way.
- Manifest of attempt 1: account phase took 20.8s total (5 pages) and ran
  fully inside the metrics pool ramp (metrics 241s, from ~22s). 20.8s fits the
  "all six clicks returned true, each 800ms-later grab saw an empty rows
  region" time budget (~7.8s for the audience step); a marker-timeout +
  clicked=false×6 path would have taken ~25s+.
- Timeline: demographics healthy under the SEQUENTIAL agent path (2026-06-29),
  empty from the first CONCURRENT fast-path run (2026-07-13). The audience
  rows are XHR-fetched per tab click; under 3 concurrent metrics tabs the
  fetch plausibly exceeds the fixed 800ms settle every time. (Alternative
  mechanism, unproven: account window occluded by metrics windows → rAF
  paused → lazy module never paints. Same repair either way.)

### Assumptions

- A1 (open, acted on): the six empty demographic groups come from the fixed
  800ms settle expiring before the per-tab XHR rows render under concurrent
  metrics load — not from clicked=false. Inferred from the 20.8s account-phase
  time budget; not directly observed (would need a full concurrent rerun,
  which the 429 budget forbids).
- A2 (superseded after codex round): distinct first labels were observed once
  but are not a safe invariant — the shipped fix compares a FULL row signature
  (JSON of labels+pcts) instead of the first label.
- A3 (open, acted on): posts-phase zero-cards was a transient server-side
  empty serve; probe 1 shows the surface healthy 8 min later. One paced
  retry is belt-and-braces; selectors unchanged.
- A4 (falsified for the tested setup): a second Playwright page occludes the
  first → probe 3 showed visibilityState stays `visible`.
- A5 (design note): in the new UI the initial "All" view parses to non-empty
  MIXED rows, so any wait-for-rows poll must be seeded with the initial view's
  first label and wait for CHANGE — otherwise stale All-view content would be
  stored as job_title.

Log tail of attempt 1:

```
ENGAGEMENTS_7D=6
PROFILE_VIEWERS_90D=132
SEARCH_APPEARANCES_7D=21
PAGES_FAILED=audience-canary

[comments]
WEEK=2026-07-20
COMMENTS_DISCOVERED=3
COMMENTS_NEW=1
COMMENTS_SNAPSHOTTED=3
DISCOVERY_CUTOFF=2025-11-11T00:00:00Z
OLDEST_VISIBLE=2026-07-08T07:56:18Z
SCROLL_ITERATIONS=1
HIT_CAP=false

```

### Codex round 1

Brief: failure + probe evidence + planned fix (adaptive per-tab poll keyed on
first-label change, keep-on-timeout; posts zero-cards retry; bringToFront +
scroll). Reply (15 min, read-only, it independently read the probe artifacts
and the scraper): "posts retry sensible; do NOT ship the audience poll as
described." Triage:

| Codex point | Verdict | Disposition |
|---|---|---|
| First tab can accept stale "All" content | valid | baseline signature seeded from the pre-click view; guard applies to ALL tabs |
| Keep-on-timeout can persist stale/partial rows | valid | timeout stores `{}` + `audience-tab-<key>` failure, never the last grab |
| `rows>=1` can capture a progressive partial render | valid | acceptance requires two consecutive identical non-empty grabs (250ms apart) that differ from the previous view |
| Canary passes 1-loaded/5-empty; wrapper accepts it (worst case: silent exit-0 auto-merge) | valid | every empty tab now lands in `PAGES_FAILED` → exit 10, no auto-merge |
| First-label distinctness unsafe | valid | full-row-signature comparison |
| A1 (slow-XHR mechanism) weakly supported; 20.8s budget doesn't discriminate | valid | documented as plausible/unproven; fix does not depend on the mechanism |
| bringToFront unreliable (metrics workers open ~39s, mid-account) + unsupported semantics | valid | dropped; replaced by serializing the account phase before the metrics pool (codex's own closing suggestion; matches the only strong evidence: sequential=healthy, concurrent=empty 3/3) |
| aria/selected-state click verification | needs-testing | skipped — live DOM attributes unknown; wrong guess breaks clicks entirely; button lookup scoped to `main`; residual misattribution risk documented below |
| Posts: fresh accumulators on round 2 | moot | round 2 only runs when accumulators are empty |
| Posts: capture diagnostics before the retry erases evidence | valid | one-line diag (url/title/data-urn count/text sample) logged on every zero round |
| Persistent zero-cards should maybe be exit 30 (COMPAT), not exit 1 | debatable | left as-is; open question below |

### Fix

All in `.claude/skills/linkedin-stats/fast/scrape-weekly.mjs`:

1. **Account phase serialized before the metrics pool** (was Phase B ∥ C).
   The audience module's rendering proved concurrency-sensitive; running the
   ~21s account phase alone eliminates the whole contention class (visibility,
   XHR competition, CPU) regardless of which mechanism is real. Deadline
   headroom is ~5x, cost is negligible. Comments-out still gated on account
   success; metrics ∥ comments unchanged.
2. **Audience step hardened**: scrollBottomSettle + bounded (10s) wait for the
   tab strip; per tab, a poll (250ms steps, 8s absolute deadline) that accepts
   only stable+changed content — two consecutive identical non-empty row
   signatures differing from the previous view's; baseline seeded from the
   pre-click "All" view; on timeout `{}` + `audience-tab-<key>` in
   PAGES_FAILED and the baseline re-anchors to the last observed signature.
   Idle-page cost: ~0.5s/tab (vs the old fixed 0.8s).
3. **Posts phase**: on zero cards after the full scroll loop, log a one-line
   page diagnostic and retry the whole navigate+scroll collection ONCE (paced
   re-navigation, 5s gap); throw the same `reason:'SCRAPE'` error only if
   still zero. Covers the observed transient empty serve.

Not chosen: reclassifying zero-cards as COMPAT/exit 30 (probes show selectors
currently fine — persistent-vs-transient is not distinguishable at throw
time); aria-based click verification (unknown DOM support); wrapper changes.

### Spot-verification

`node scrape-weekly.mjs --phases=account --data-root=<scratch copy>` with the
fixed code: exit 0, `PAGES_FAILED=-`, 18.3s, and the scratch account.json got
9–10 rows in each of the six groups with correct attribution (job titles under
job_title, locations under location) — first non-empty demographics since
2026-06-29, shape matches that last healthy snapshot. Honest causality note:
this verify ran without concurrent load — which is exactly the condition the
serialization change makes production match, so it validates the shipped
configuration, but it does NOT prove the old code would have failed at this
moment (no failing pre-fix probe under load was possible within the 429
budget). The posts fix is verified only as far as probe 1 (surface renders
cards now) + syntax; the retry path itself must prove out on the rerun.
Chrome swept after every probe (`pkill -f 'user-data-dir=.*mcp-chrome-linkedin-ai'`),
zero profile Chromes at session end.

### Unverified next-run changes

None — no edits to run-weekly.sh or the workflow yml.

### Open questions

- Root mechanism of the concurrent-run audience emptiness (slow XHR vs paused
  rendering vs early hydration) remains unproven; serialization sidesteps it.
  If demographics ever go empty again WITH the serialized layout, the
  per-tab `audience-tab-*` entries in PAGES_FAILED will say which tabs and
  the poll timing will be the next probe target.
- Posts-phase transient empty serve: cause unknown (server empty response vs
  client render race). The new zero-round diagnostic line will capture the
  page identity next time it happens; if it recurs persistently, consider
  exit 30 (COMPAT) semantics instead of exit 1.
- Residual risk (documented, accepted): a tab whose content arrives after its
  8s deadline could in principle be misattributed to the NEXT tab if it lands
  mid-poll and stabilizes; closing this fully needs selected-tab-state
  verification against the live DOM's aria attributes.
- The 2026-07-13 committed snapshot still has six empty demographic groups on
  main; this fix does not backfill it (LinkedIn shows current-period data
  only — that week is unrecoverable).

## Run summary — 2026-07-20T15:06:56Z
- attempt 1: exit 1, 264s
- attempt 2: exit 0, 271s
- outcome: RECOVERED — outer gate accepted attempt 2 (full success) after 1 heal session(s); PR left unmerged for review

## Resolution — 2026-07-20 15:23 UTC

### Outcome

**Recovered on attempt 2 (FINAL_ACCEPTANCE: complete).** Exit 0 in 271s:
posts 5 cards on round 1 (the new retry never fired), metrics 42/44 with 2
repost skips and 0 failures, account `PAGES_FAILED=-` with all six
demographic groups populated (9–10 rows each, first non-empty since
2026-06-29), attribution verified type-correct (job titles under job_title,
geo names under location, employee ranges under company_size, etc. — ruling
out the tab-shift cascade below for THIS snapshot), comments-out 3
discovered. Serialization cost ≈ +7s wall-clock vs attempt 1.

"Recovered", not "fixed": there is no failing pre-fix probe under concurrent
load (429 budget forbade one), so the causal claim is only "sequential
account phase has never produced empty demographics; concurrent always did
(3/3); production now runs sequential and produced healthy data once". The
posts retry path is verified only by probe 1 + syntax — production never
exercised round 2.

### Codex round 2

Codex's verdict: keep serialization ("the strongest part of the fix"), keep
full-signature comparison, per-tab failure reporting, and the paced posts
retry; but it rated the audience poll's attribution guarantee
**fix-invalidating** and recommended amend + rerun before merge.

**Review-session triage of that verdict: downgraded to priority-1 follow-up;
merge is still recommended.** Reasons: (1) this week's shipped data is
verified type-correct in all six groups, so the PR's data is sound; (2) the
hazard codex describes (below) existed in strictly worse form in the old
code (fixed 800ms settle, first-label guard only — which actually DID ship
six silent empty groups twice); rejecting this PR retains the worse code;
(3) the cascade needs a knife-edge timing pattern six times in a row under
the slow-render condition that serialization removed from the happy path.
Peter: if you weigh the residual auto-merge risk differently, the rejection
case is codex's, stated next.

| Codex point | Verdict | Disposition |
|---|---|---|
| **Attribution cascade**: the pre-click baseline is one immediate grab of the All view; if All is still empty/partial at seed time, late All rows can be accepted as job_title, late job_title rows as location, … — six shifted groups, `PAGES_FAILED=-`, exit 0, silent auto-merge. Full signatures prove "content changed", never "content belongs to the clicked tab". A5's guarantee is contradicted unless the seed is first stabilized. | valid hazard, confirmed in code | priority-1 follow-up (F1); downgraded from fix-invalidating per triage above |
| `page.waitForFunction(fn, { timeout: 10000 })` passes options in the `arg` position — Playwright's signature is `(fn, arg, options)`, so the strip wait actually runs on the 30s default | valid — confirmed against the Playwright API | follow-up (F2); impact minor: the wait is `.catch`'d, so this only lengthens the drift-case failure path 10s→30s |
| 250ms×2 stability window accepts a stable partial render (earliest accept ~500ms — earlier than the old 800ms settle); wants ~800–1000ms quiet-since-last-change or a loader/XHR signal | valid — though 250ms×2 was codex round 1's OWN accepted spec; round 2 supersedes round 1 | follow-up (F3) |
| Re-baseline-on-timeout is not a causal fence: if `lastSig` is `{}`/partial/previous-tab, a late response still lands on the next tab; safe behavior is abort remaining tabs or reload the page after any timeout | valid | follow-up (F4); mitigant: any timeout ⇒ `PAGES_FAILED` ⇒ exit 10 ⇒ human review, never auto-merge |
| Poll's 8s deadline is soft (an in-flight `evaluate` can overshoot/hang) and the loop never checks `breakerTripped` | valid, minor | follow-up (F5) |
| Posts retry: `allCards.size > 0` suppresses the retry — a truncated serve of ONE card exits 0 with missed posts; completeness for this account means reaching `past-cutoff`, so `end-of-feed` with `oldestEverSeenMs >= cutoffMs` should retry or go partial (with per-round accumulators if the trigger widens) | valid | follow-up (F6) |
| File header still documents the old `posts → metrics ∥ account → comments` phase order | valid — confirmed at scrape-weekly.mjs:18 | follow-up (F7, one-line doc fix) |
| My brief's auth-wall delta ("account failure lets a 4-min metrics pool open against a wall") is overstated: the metrics canary rethrows non-rate errors, so an AuthError kills the phase after one extra navigation | valid correction — confirmed in code (`if (!(e instanceof RateLimitError)) throw e`) | brief's delta withdrawn; optional cleanliness follow-up (F8: skip metrics explicitly after account AuthError/FS/breaker) |
| Zero-round diagnostic logs a raw 300-char page text sample into CI logs | valid, low severity (own feed, private repo) | follow-up nit (F9) |
| Code comments overclaim causality ("proved not enough", "proved concurrency-sensitive") — the rerun changed serialization+scroll+readiness+poll together and cannot isolate A1's mechanism | valid | follow-up (F10: reword on next touch); A1 stays open |
| 5s re-navigation pacing unvalidated (probe 8 min later doesn't bound the outage duration) | valid | already an open question; keep |
| package-lock rename is harmless metadata sync; don't revert | agreed | no action |

### Implementation deltas

Where the shipped code diverged from (or refined) the round-1-reviewed plan:

- Posts retry restructured as a 2-round loop with nav/waitForSelector/scrape
  INSIDE the loop, rather than an appended retry — behaviorally equivalent;
  `scrape`/`waitForNew` closures are shared across rounds but read `allCards`
  at call time (no stale capture). Round-1's "fresh accumulators" concern
  stays moot only while the trigger is zero-cards-only (see F6).
- `accountOk` hoisted to the top level; comments still runs ∥ metrics and is
  still gated on account success; `--phases` without account preserves old
  semantics.
- The audience poll implements round 1's agreed spec exactly (250ms×2,
  8s deadline, `{}`+per-tab-failure on timeout, re-baseline to last observed
  signature) — round 2 now says that spec itself is too weak (F1, F3, F4).
- Two refinements not in the reviewed plan: button lookup scoped to `main`,
  and a bounded tab-strip `waitForFunction` — which carries the arg-position
  bug (F2).
- Incidental: `fast/package-lock.json` name field resynced by npm install
  ("fast" → "linkedin-stats-fast-scrape"); no dependency changed.
- My brief claimed the new ordering leaves a 4-min metrics pool running
  after an account auth-wall; codex falsified this (canary rethrow) — the
  delta is withdrawn.

### Follow-ups

Priority order; F1 first — it is the one codex called fix-invalidating.

1. **F1 — make audience tab attribution causal, not signature-based.**
   Minimum: stabilize the All view BEFORE the first click (poll the seed
   grab until non-empty + stable; "All non-empty" is a known invariant of
   this account). Better: verify the clicked tab's selected state
   (aria-selected/class) before accepting rows, or correlate with the tab's
   XHR completion. Cheapest orthogonal guard: a label-shape validator per
   group (company_size rows match /employees/, seniority ∈ known set,
   industry ∈ known vocabulary…) added to the audience canary — it converts
   any silent shift into `PAGES_FAILED` regardless of mechanism.
2. **F2** — `waitForFunction(fn, undefined, { timeout: 10000 })` (arg-position
   bug; currently waits on the 30s default).
3. **F3** — widen acceptance to ~800–1000ms quiet-since-last-signature-change
   (restores at least the old settle floor; cost ≤ +0.5s/tab idle).
4. **F4** — on any per-tab timeout, abort the remaining tabs (or reload the
   audience page) instead of continuing to click on a document with an
   outstanding response.
5. **F5** — check `breakerTripped` inside the poll; treat the 8s deadline as
   advisory only if the phase-level watchdog stays.
6. **F6** — posts completeness: treat `end-of-feed` with
   `oldestEverSeenMs >= cutoffMs` as retry-worthy/partial, not success; use
   per-round accumulators if the trigger widens beyond zero-cards.
7. **F7** — fix the stale phase-order comment at scrape-weekly.mjs:18.
8. **F8** — explicitly skip metrics after account AuthError/FS/tripped
   breaker (cleanliness; canary already bounds the damage).
9. **F9** — truncate/sanitize the zero-round diagnostic's text sample.
10. **F10** — reword code comments that state A1's unproven mechanism as
    fact ("proved not enough" → "correlated with").
11. Fixture-test the posts retry (zero→cards and partial→complete rounds) —
    production has still never exercised round 2.

No run-weekly.sh or workflow changes proposed. The committed code is exactly
the code that passed the attempt-2 rerun; nothing was edited in this review
session.
