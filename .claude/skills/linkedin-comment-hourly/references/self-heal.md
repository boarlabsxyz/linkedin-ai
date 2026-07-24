# Self-heal overlay — linkedin-comment-hourly gather

Pipeline-specific half of the heal protocol. Read AFTER
`.claude/skills/pipeline-shared/references/self-heal-core.md`; this file is
additive — it cannot relax the core's ground rules.

Extra context keys from the caller: `HEAL_MODE` (`in-loop` or
`post-landing`, see below), `GATHER_OUT` (the failed attempt's run-scoped
contract dir), `COMMENTS_FILE` (`./linkedin-compain/comments.json`), `TS`
(this fire's timestamp). `WRAPPER` is
`.claude/skills/linkedin-comment-hourly/run-hourly.sh`; the fast script is
`<FAST_DIR>/gather-feed.mjs`.

## HEAL_MODE

- `in-loop` — the normal case: the outer loop reruns the gather after you
  exit, and the driver resets `linkedin-compain/` to the fire's base commit
  (an immutable SHA captured at branch checkout — not the index) before that
  retry, so the rerun is real verification of your fix against clean state.
- `post-landing` — the fire already shipped its drafts and merged the data
  to main; you are fixing the fast path for the NEXT fire. Two triggers:
  selector drift (exit 30 — drafts came via the legacy agent fallback), or
  `PERMALINKS_MISSING>0` in an otherwise-accepted contract (the fast gather
  itself drafted, but ≥1 accepted post shipped to Slack without its post
  link — an error since 2026-07-21; the caller passes the count as
  `PERMALINKS_MISSING`, and the attempt log + `GATHER_OUT/manifest.json`
  name the affected keys and the captured `no-copy-item (menu: …)` /
  `no-capture` detail). There is NO rerun this fire: every change you make
  is unverified next-run by definition — say so in the incident, keep the
  fix conservative, and lean on `fast/verify-links.mjs` + saved-HTML probes
  for spot-verification instead.

Your session runs with a ~30 minute watchdog (shorter than the weekly
pipeline's — this is a morning delivery pipeline). Budget the codex round
accordingly (cap it at ~600s) and write the incident as you go.

## Pipeline-specific ground rules

- **Feed + classifier budget.** The home feed is cheaper than the analytics
  surfaces but shares the same logged-in profile; probe with ONE feed load,
  never a second full gather (it would also re-append filtered entries and
  spend the classifier's `claude -p` haiku calls). If the failure was
  rate-limiting (exit 22), you won't be called — the driver fails fast.
- **Preferred fix surfaces:** `<FAST_DIR>/gather-feed.mjs` and
  `<FAST_DIR>/verify-links.mjs`, plus this skill's `references/`. The
  interest filter is tuned in `interests.md` — classification "failures"
  are usually a tuning question, not a code bug.
- **`COMMENTS_FILE` is the cross-fire seen-set** — a single JSON array,
  written ONLY via `jq` read-modify-write. Never hand-edit it; never let a
  fix bypass the key-dedup (`<author-slug>-<body-hash8>` + the fuzzy
  author+body-prefix bridge for legacy keys).

## Exit-code taxonomy of gather-feed.mjs

| exit | meaning | typical response |
|---|---|---|
| 0 / 10 | ok / partial — you are called in-loop when the CONTRACT is unusable despite the ok exit: missing `contract.env`, non-numeric `POSTS_FOUND`, `OUT_DIR` not matching the attempt's `--out-dir` (stale/foreign contract), a `POST_<i>` missing `KEY`/`AUTHOR`, or a `POST_<i>_TEXT_FILE` absent, empty, or outside the attempt dir — that's a contract-emission bug in the script. A USABLE contract with `PERMALINKS_MISSING>0` is instead dispatched post-landing (drafts ship first): fix the copy-link capture (`RECOVER_EVAL` / `recoverPermalink`), using the menu-item dump the error line now carries | fix the contract writer / text-file plumbing, or the permalink capture, in `gather-feed.mjs` |
| 20 | AUTH — LinkedIn session expired on the runner profile | unfixable by code → ABORT (needs Peter's interactive relogin) |
| 21 | profile locked (Chrome ProcessSingleton) | you're called on the SECOND consecutive lock (the driver already swept once) — find what's actually holding the profile |
| 22 | rate-limited, nothing accepted | never dispatched to you — the driver fails fast (next fire is tomorrow; time is the only fix) |
| 23 | fs/jq failure | disk/permissions/jq on the runner — diagnose locally |
| 30 | selector drift — the home-feed DOM changed under the parsers | never dispatched in-loop: the driver falls back to the legacy gather agent first (drafts must ship), then runs you with `HEAL_MODE=post-landing` to fix the fast path for the next fire |
| 31 | classifier unusable (`claude -p` haiku calls failing) | never dispatched to you — a broken `claude -p` can't be healed by another `claude -p`; the driver fails fast |
| 1 / other | UNKNOWN error | full diagnosis per the core protocol |

## Known history (do not re-derive; details in CLAUDE.md + SKILL.md)

- LinkedIn's home feed has obfuscated CSS classes and no reliable data-urn
  since 2026-07 — card discovery goes through the control-menu button;
  post keys are `<author-slug>-<body-hash8>` computed on a footer-cut body
  (mutable reaction counts must not drift the key).
- **The ONLY permalink source is the card's "Copy link to post"** —
  clipboard `writeText` interception (clipboard `readText()` throws in the
  cron tab), then in-browser short-link resolution (`lnkd.in` serves
  reCAPTCHA to curl since 2026-07-16), then positive verification
  (author-path or body-prefix must appear on the rendered page). Never emit
  `/feed/update/<urn>/` URLs; never rebuild links from card-leaked URNs
  (`activity` vs `ugcPost`/`share` ids differ for the same post — guessing
  shipped 4 broken links). `fast/verify-links.mjs` re-opens every contract
  URL and asserts the post renders — it is the acceptance test for
  permalink changes.
- Post bodies travel as FILES (`POST_<i>_TEXT_FILE`), never inline base64 —
  inline blobs poisoned agent contexts and got generations refused
  (2026-07-16 fire).
- 2026-07-21 fire: one accepted card's control menu produced `no-copy-item`
  on a single 800ms-wait lookup and the draft went to Slack with no post
  link. Response: the lookup now polls ~3.2s + retries the whole recovery
  once + dumps the rendered menu items into the error line, and
  `PERMALINKS_MISSING>0` became a ⚠️-fire + post-landing-heal trigger.
- 2026-07-24 fire: an accepted draft shipped with no post link and NO error
  detail in the log. Two stacked causes: (1) "Connect" header chrome (shown
  for non-connection authors) leaked into the parsed body — poisoning the
  body-hash key and the verify body-prefix check; (2) the desktop copy-link
  wrote a FULL canonical `/posts/` URL (not an lnkd.in short link), which the
  lnkd.in-only unverified-keep silently dropped after verification failed.
  Response: `Connect` added to the body-start skip list, every verify null
  path now logs a reason code (query strings never logged — `rcm=` is
  member-associated), unverified keeps extended to captured canonical
  `/posts/` URLs (strict URL-parse checks, query stripped, urn null) and
  counted in `PERMALINKS_UNVERIFIED`, and `RECOVER_EVAL` gained a
  card-association body-probe (`card-recycled` error) so a recycled card's
  URL can't ride the unverified keep. 14 seen-set entries with
  Connect-prefixed `post_text` were jq-repaired (keys kept — the fuzzy
  bridge covers them). If a permalink goes missing WITH a logged reason now,
  it is a NEW failure mode, not this one.
- The Slack bookends and the batched classifier are pinned `claude -p`
  micro-call shapes (see WRAPPER comments) — do not "improve" their flags.
