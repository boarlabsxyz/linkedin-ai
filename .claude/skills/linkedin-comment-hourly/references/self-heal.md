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
- `post-landing` — the gather hit selector drift (exit 30) and the fire
  already shipped drafts via the legacy agent fallback; the drafted data has
  already been merged to main. There is NO rerun this fire: every change you
  make is unverified next-run by definition — say so in the incident, keep
  the fix conservative, and lean on `fast/verify-links.mjs` + saved-HTML
  probes for spot-verification instead.

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
| 0 / 10 | ok / partial — you are only called when the CONTRACT is unusable despite the ok exit: missing `contract.env`, non-numeric `POSTS_FOUND`, `OUT_DIR` not matching the attempt's `--out-dir` (stale/foreign contract), a `POST_<i>` missing `KEY`/`AUTHOR`, or a `POST_<i>_TEXT_FILE` absent, empty, or outside the attempt dir — that's a contract-emission bug in the script | fix the contract writer / text-file plumbing in `gather-feed.mjs` |
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
- The Slack bookends and the batched classifier are pinned `claude -p`
  micro-call shapes (see WRAPPER comments) — do not "improve" their flags.
