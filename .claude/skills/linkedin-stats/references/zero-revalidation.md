# Selfcheck revalidation — linkedin-stats weekly

Additive protocol on top of the IMMUTABLE `pipeline-shared/references/self-heal-core.md`.
Everything in the core still binds you: no git writes, never edit
`.claude/skills/pipeline-shared/`, sweep the Chrome profile when you are done,
no secrets in the incident, read prior `doc/incidents/*.md` first.

You are invoked by `run-weekly.sh` AFTER a scrape that exited 0 with no
healing, but whose `[selfcheck]` section named at least one signal — a
suspicious ZERO (`ZERO_SIGNALS`) or a non-zero DEFECT (`ANOMALY_SIGNALS`).
Both ask the same question and both land here: is there a real-world
explanation, or did a parser rot?

## Why this exists

On **2026-08-17** every post's comment array came back empty. The week before,
those same 50 files held 85 comments. The run exited 0, passed the coverage
gate, auto-merged and published to Grafana. Not one counter the acceptance gate
reads had moved, because the gate reads `POSTS_MEASURED` / `POSTS_FAILED` /
`POSTS_UNPROCESSED` — and all 50 posts were measured. They were just measured
as empty.

A zero is the one shape a scraper produces just as happily when it is broken as
when the week was genuinely quiet. Peter, 2026-08-19: *"if at least 1 parameter
is 0, revalidate code/instruction responsible for that part. even open
playwright yourself and make sure: WOW really zero."*

## Your job

**Decide whether each zero is REAL. Not make it non-zero.**

- A confirmed-real zero is a RESULT. Record it with the evidence that proves
  it, change nothing, and the run merges and publishes exactly as it would
  have.
- **Never edit code to make a real zero non-zero.** That is fabricating data,
  and it is worse than the bug this gate exists to catch.
- **Never write CONFIRM without having loaded a page.** A verdict reasoned from
  the log alone is `BUG: unprobed`. If you could not probe at all —
  rate-limited, auth wall, out of time — write BUG with reason `unprobed`. An
  unverified zero does not get the benefit of the doubt.

## Budget

- **≤ 6 page loads total, ≥ 3s apart.** The run just finished a full scrape;
  you are spending from a warm 429 budget (~23 loads/min is safe, ~32 trips
  the limiter).
- ~30 minutes wall clock. The watchdog kills you at `ZERO_TIMEOUT_SECS`.
- `HEAL_MODE=post-landing`: the attempt loop is over, so **there is no rerun
  after you**. The core's "the rerun is the real verification" does not apply —
  your own targeted probe is the verification. The core's "do NOT run the full
  fast script" still binds; the sandboxed 3-post run below is not the full
  script.

## Per-signal protocol

`ZERO_SIGNALS` and `ANOMALY_SIGNALS` are comma lists. Handle every name in
both.

### `posts_new` — `[posts] POSTS_NEW=0`

Owner: `phasePosts` + the `CARD_SCRAPE` evaluator in `<FAST_DIR>/scrape-weekly.mjs`.

Probe: `https://www.linkedin.com/in/ovchyn/recent-activity/all/`, then
`document.querySelectorAll('div[data-urn^="urn:li:activity"]').length` and the
first card's `data-urn`. Decode its id with `Number(BigInt(id) >> 22n)` for the
posting time.

REAL iff ≥1 card renders **and** the newest card's id already has a file under
`dashboards/li-stats/posts/`. Peter does not post every week; this is the
signal most likely to be genuinely zero.

BUG if 0 cards render (that path throws `SCRAPE` on its own, so 0 cards
reaching exit 0 means the selector matched something meaningless), or the
newest visible post is not tracked.

### `comments_new` — `[comments] COMMENTS_NEW=0`

Owner: `phaseCommentsOut` + `.claude/agents/linkedin-stats-gather-comments-out.scrape.js`.

Probe: `https://www.linkedin.com/in/ovchyn/recent-activity/comments/`, then
count `article` elements and read the newest `data-id`.

REAL iff ≥1 article renders and the newest visible comment URN is already a key
in `dashboards/li-stats/comments.json`. Discovery is incremental, so a quiet
week is normal and expected.

BUG if 0 articles render, or a newer untracked URN is visible.

### `reactors` — `[people] REACTORS_SEEN=0`

Owner: `openPostReactors` / `readReactorDialog` / `scrapeOpenReactorDialog`.

Probe: pick the newest post whose latest `weeks[*].metrics.reactions > 0`, open
its `post_url`, then check **in this order** — each step names its own fix
site:

1. Does any visible element's collapsed text match `/^\d[\d,]*\s+reactions?\b/i`
   and have a `closest('a, button, [role="button"]')`?
   Failure → the counts row's text changed. Fix `openPostReactors`.
2. Click it. Does `dialog[open], [data-testid="dialog"], [role="dialog"],
   [aria-modal="true"], .artdeco-modal` mount within 4s?
   Failure → the overlay selector changed. Fix `DIALOG_SEL` / `openPostReactors`.
3. Does that dialog contain `a[href*="/in/"]`?
   Failure → the entry markup changed. Fix `readReactorDialog`.

REAL only if every scanned target genuinely has `metrics.reactions === 0`,
which contradicts the stored analytics on this account. Treat "real" here as
almost certainly wrong.

Note: `phasePeople` already escalates the provable case on its own —
`REACTORS_SEEN=0` while `REACTORS_EXPECTED>0` becomes `SELECTOR_DRIFT` (exit 10
→ the normal heal path), so if it reached you, the dialog never even reported a
count.

### `commenters` — `[metrics] COMMENTS_SCRAPED_TOTAL=0`

Owner: `scrapeOnePost`'s public-post block + `loadAndScrapePostComments` +
`.claude/agents/linkedin-stats-gather-metrics.scrape-comments.js`.

Probe: pick the newest post whose latest `metrics.comments > 0`, open its
`post_url`, wait for `.feed-shared-update-v2`, then:

```js
Array.from(document.querySelectorAll('article.comments-comment-entity'))
  .filter(a => !a.closest('.comments-replies-list, .comments-comment-replies'))
  .length
```

REAL only if **every** post reports `metrics.comments === 0`.

BUG whenever analytics reports comments and the top-level count is 0 — that is
selector drift in the canonical scrape body. Also BUG when the count is > 0 but
`weeks[WEEK].comments` is `[]`: the drift is then in the Load-more /
`SEE_MORE_EXPAND` path or in the `page.evaluate(SCRAPE_POST_COMMENTS)` handoff.

**This is the 2026-08-17 signature.** `COMMENTS_SCRAPED_TOTAL=0` with non-zero
`metrics.comments` on many posts, 85 → 0 across 50 files, `[people]
COMMENT_EVENTS=0` inherited downstream. The correct verdict that day was
`commenters: BUG`.

### `roster_unresolved` — `[people] ROSTER_UNRESOLVED > 0`

The one ANOMALY signal: an engager LinkedIn displayed that could not be turned
into a profile link. Owner: `readReactorDialog` (reactor lists) and the
canonical `.claude/agents/linkedin-stats-gather-metrics.scrape-comments.js`
(commenter lists), via `People.rosterUrls`.

There is no stored counter for this — the field was deliberately removed
(Peter, 2026-08-19: *"let's just drop them. if face such stuff, just break
pipeline and fix during self-improving stuff"*). A roster is a list of profile
links; a person with no link is a hole in it, and an "and N others" number next
to the array just normalizes the hole.

The counter is a SUM over both sides, so probe whichever the log implicates —
the phase logs the target id next to each roster it builds.

**Reactor side** — open the post, open the reaction overlay, count in the dialog:

```js
const d = document.querySelector('dialog[open], [data-testid="dialog"]');
[d.querySelectorAll('a[href*="/in/"]').length,
 [...d.querySelectorAll('*')].filter(e => /LinkedIn Member/i.test(e.innerText || '')).length]
```

**Commenter side** — same post, no dialog; count units against the anchors
inside them:

```js
const U = 'div[id^="replaceableComment_urn:li:comment:"]';
const units = [...document.querySelectorAll(U)].filter(u => !u.parentElement?.closest(U));
[units.length, units.filter(u => u.querySelector('a[href*="/in/"]')).length]
```

REAL, on either side, only if the shortfall is exactly accounted for by entries
that render as "LinkedIn Member" with **no anchor at all**. Say so explicitly
with the two counts.

BUG in every other case — and this is the likely one. Private members render no
anchor, so they normally never reach the parser: 12 of 12 reactors and 4 of 4
commenters resolved on the first real corpus. A non-zero here usually means the
anchor selector (`a[href*="/in/"]`) or the URL normalization stopped matching,
i.e. people ARE being displayed with links we no longer read.

### `REPLIES_UNMEASURED` — reported, deliberately NOT a signal

Not in either list, and not a defect to chase. On a comment permalink LinkedIn
renders the whole thread FLAT: measured live 2026-08-19, a top-level comment
and a reply shared the same parent, the same DOM depth, the same left offset
(397px), the same width, the same computed padding and margin. The only thing
that differs is an obfuscated CSS-module hash on the grandparent
(`dcc9147d…` vs `ccb1a91d…`) — split 4/4 and perfectly consistent, but with
nothing derivable behind it. Anchoring on that hash is precisely the class of
selector that silently died in the 2026-08 migration.

So the phase writes `commenters: null` ("not measured") for outbound comments
rather than `[]` ("nobody replied"), and reports the count. That is an honest
capability limit, not a broken parser — do not "fix" it by guessing from
document order or from the reply's leading @-mention (only 3 of 4 replies
carried one).

## If you find a bug

Fix surfaces are the same as `references/self-heal.md`: anything under
`<FAST_DIR>`, the canonical `.claude/agents/*.js` scrape bodies, and this
skill's `references/`. Never `pipeline-shared/`.

Verify in a SANDBOX so nothing tracked is mutated — the committed tree must
stay one attempt's coherent output:

```bash
mkdir -p "$HEAL_DIR/probe-data"
cp -R dashboards/li-stats/. "$HEAL_DIR/probe-data/"
node "$FAST_DIR/scrape-weekly.mjs" --phases=metrics \
  --data-root="$HEAL_DIR/probe-data" \
  --post-file="$HEAL_DIR/probe-data/posts/<a>.json,$HEAL_DIR/probe-data/posts/<b>.json" \
  --verbose
```

3 posts ≈ 9 page loads, ~25s at the paced rate. **Gotcha:** `--post-file`
resolves against `REPO_ROOT`, not against `--data-root` — pass repo-relative
paths that point INSIDE the probe dir.

Any wrapper or workflow edit takes effect only next Monday and is therefore
UNVERIFIED by this run; list it under "Unverified next-run changes" in the
incident. Optional codex round when `CODEX_AVAILABLE=1`, capped the portable
way (`perl -e 'alarm shift @ARGV; exec @ARGV' 900 codex exec -s read-only --ephemeral -`).

## Reporting — the wrapper reads exactly one marker

Write **one** file, as your **last action** before exiting.

- `$CONFIRM_FILE` — one line per signal: `<signal>: <one-line evidence>`.
  Write it ONLY when every signal in `ZERO_SIGNALS` is confirmed real.
- `$BUG_FILE` — one line: `<signal>: <what is broken> [fixed|unfixed]`. Write
  it when ANY signal is a bug, or when you could not probe. Still list the
  confirmed signals in the incident.

Both present → the wrapper takes BUG. Neither → `unverified`, which lands the
same as BUG (PR left open, no publish).

## Incident section

Append to `$INCIDENT_FILE`:

```
### Zero-signal revalidation — <UTC time>
- signals: <ZERO_SIGNALS>
- <signal>: probe <url + selector> -> <result> -> CONFIRMED REAL | BUG
- fix: <what changed, or "none — the zero is real">
- sandbox re-run: <command + result, if any>
- Unverified next-run changes: <wrapper/workflow edits, or "none">
```

Be honest about causality, exactly as the core requires: one clean probe after
an intermittent failure proves RECOVERY, not a fix.
