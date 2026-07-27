#!/usr/bin/env node
// Deterministic Slack-inbox gather for the linkedin-comment-hourly pipeline.
//
// Reads a captured Slack channel snapshot (messages.json written by
// read-slack-inbox.sh from the connector's REST proxy), keeps only HUMAN
// messages (no bot_id), extracts LinkedIn post links, fetches each linked
// post from the logged-in Chrome profile (author, headline, full expanded
// body, canonical /posts/ permalink), and emits the same POST_<i>_* contract
// shape as gather-feed.mjs — plus a PROPOSED state-file successor that the
// driver installs only after the drafting phase delivered.
//
// Link-conservation invariant (checked by the driver from manifest.json):
// every job (pending_in + new + revived) ends in exactly ONE bucket —
// contract row, pending_out, dead_new, accounted_dup, skipped_already
// commented, or alias_merged. Nothing is ever silently dropped.
//
// Identity: normalized URL pre-fetch (origin + path, no query, no trailing
// slash), post key (<author-slug>-<body-hash8> from keys.mjs) post-fetch.
// Dedup against comments.json is DISPOSITION-AWARE: drafted-with-task → dup;
// drafted-without-task → clickup-only row; off-topic → reprocess row (Peter
// explicitly curated the link — the automated filter's verdict is overridden);
// already-commented → skipped.
//
// Peter-curated links get NO interest classification and NO repost filter.
//
// Usage:
//   node gather-inbox.mjs --messages-file=path [--state-file=linkedin-compain/slack-inbox.json]
//        [--comments-file=linkedin-compain/comments.json]
//        [--out-dir=tmp/gather-inbox/<utc-ts>] [--deadline-secs=240]
//        [--max-links=5] [--max-attempts=5] [--headless] [--verbose]
//        [--fetch-stub=path.json]   # fixture tests: url -> fake fetch result, no browser
//
// Exit codes (mirrors gather-feed where meaningful):
//   0  contract emitted, no fetch failures
//   10 contract emitted, partial (some fetches failed → pending; deadline;
//      rate-limited with rows)
//   20 auth/checkpoint wall (no rows emitted)
//   21 profile busy
//   22 rate-limited with nothing emitted
//   23 filesystem / state / messages-file failure

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright-core';
import { normText, makeKey, fuzzyId } from './keys.mjs';

// ---------------------------------------------------------------- constants

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(SCRIPT_DIR, '..', '..', '..', '..');
const USER_DATA_DIR = path.join(
  process.env.HOME, 'Library', 'Caches', 'ms-playwright', 'mcp-chrome-linkedin-ai');

const args = Object.fromEntries(process.argv.slice(2).map((a) => {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/);
  return m ? [m[1], m[2] ?? true] : [a, true];
}));

const MESSAGES_FILE = args['messages-file'] ? path.resolve(REPO_ROOT, String(args['messages-file'])) : null;
const STATE_FILE = path.resolve(REPO_ROOT, String(args['state-file'] || 'linkedin-compain/slack-inbox.json'));
const COMMENTS_FILE = path.resolve(REPO_ROOT, String(args['comments-file'] || 'linkedin-compain/comments.json'));
const RUN_TS = new Date().toISOString().replace(/[:.]/g, '-').replace(/-\d{3}Z$/, 'Z');
const OUT_DIR = path.resolve(REPO_ROOT, String(args['out-dir'] || path.join('tmp', 'gather-inbox', RUN_TS)));
const DEADLINE_SECS = parseInt(args['deadline-secs'] || '240', 10);
const MAX_LINKS = Math.max(1, parseInt(args['max-links'] || '5', 10));
const MAX_ATTEMPTS = Math.max(1, parseInt(args['max-attempts'] || '5', 10));
const HEADLESS = !!args.headless;
const VERBOSE = !!args.verbose;
const FETCH_STUB = args['fetch-stub'] ? path.resolve(REPO_ROOT, String(args['fetch-stub'])) : null;

// Edit horizon: messages this far below the watermark are re-scanned so a
// recent edit that ADDED a link is picked up (Slack keeps the original ts on
// edit); already-accounted links make the overlap free. Documented limit:
// edits older than this are not seen.
const EDIT_OVERLAP_SECS = 3 * 24 * 3600;

// Human-message subtypes allowed besides plain (null) messages.
const HUMAN_SUBTYPES = new Set(['file_share', 'thread_broadcast', 'me_message']);

// Positive-evidence tombstones ONLY — deliberately narrower than the feed's
// RENDER_ERROR_RE: "Something went wrong" / "couldn't be loaded" are transient
// load errors and must retry, not dead-letter (codex round 3).
const TOMBSTONE_RE = /no longer available|page not found|has been removed|post was deleted|doesn.t exist|isn.t available/i;

const t0 = Date.now();
const log = (...m) => console.error(`[${((Date.now() - t0) / 1000).toFixed(1)}s]`, ...m);
const vlog = (...m) => { if (VERBOSE) log(...m); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const nowIso = () => new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');

const CLEANUP_RESERVE_MS = 20_000;
const stopAt = t0 + DEADLINE_SECS * 1000 - CLEANUP_RESERVE_MS;
let stopReason = null; // 'deadline' | 'rate-limited'
const outOfTime = () => {
  if (!stopReason && Date.now() > stopAt) stopReason = 'deadline';
  return !!stopReason;
};

class AuthError extends Error {}
class RateLimitError extends Error {}

// ------------------------------------------------------------ ts arithmetic

// Slack ts strings ("1784992193.489909") must survive round-trips exactly —
// float64 wobbles in the microsecond digits. Compare as [sec, usec] ints.
function tsParts(ts) {
  const [s, u] = String(ts).split('.');
  return [parseInt(s, 10) || 0, parseInt((u || '0').padEnd(6, '0').slice(0, 6), 10)];
}
function tsCmp(a, b) {
  const [as, au] = tsParts(a); const [bs, bu] = tsParts(b);
  return as !== bs ? as - bs : au - bu;
}
const tsMinusSecs = (ts, secs) => `${Math.max(0, tsParts(ts)[0] - secs)}.000000`;

// ------------------------------------------------------------ url identity

// Normalized identity: https, lowercased linkedin host, path without query/
// fragment or trailing slash. Only LinkedIn post-link shapes are accepted.
function normalizeLink(raw) {
  let u;
  try { u = new URL(String(raw)); } catch { return null; }
  if (u.protocol !== 'https:' && u.protocol !== 'http:') return null;
  const host = u.hostname.toLowerCase();
  const pathName = u.pathname.replace(/\/+$/, '');
  if (host === 'lnkd.in') {
    if (!/^\/[A-Za-z0-9_/-]+$/.test(pathName)) return null;
    return `https://lnkd.in${pathName}`;
  }
  if (host === 'www.linkedin.com' || host === 'linkedin.com') {
    if (/^\/posts\/[^/]+$/.test(pathName) || /^\/feed\/update\/urn:li:[A-Za-z]+:\d+$/.test(pathName)) {
      return `https://www.linkedin.com${pathName}`;
    }
  }
  return null;
}

function extractLinks(msg) {
  const found = [];
  const push = (raw) => { const n = normalizeLink(raw); if (n) found.push(n); };
  // <https://url|label> and <https://url> tokens in message text
  for (const m of String(msg.text || '').matchAll(/<(https?:\/\/[^|>]+)(?:\|[^>]*)?>/g)) push(m[1]);
  // Bare URLs: Slack leaves a URL as PLAIN TEXT (no <> token, no link block)
  // when the human formatted it as code (`…` / preformatted). A message whose
  // only link is code-styled would otherwise scan as linkless yet still
  // consume its watermark slot (codex round 5). normalizeLink whitelists the
  // LinkedIn forms, so the broad sweep can't admit junk; the Set dedupes the
  // overlap with the token matches.
  const BARE_URL = /https?:\/\/[^\s<>"'`|]+/g;
  for (const m of String(msg.text || '').matchAll(BARE_URL)) push(m[0]);
  for (const a of msg.attachments || []) { push(a.from_url); push(a.original_url); }
  const walkBlocks = (node) => {
    if (!node || typeof node !== 'object') return;
    if (Array.isArray(node)) { node.forEach(walkBlocks); return; }
    if (node.type === 'link' && node.url) push(node.url);
    if (typeof node.text === 'string') for (const m of node.text.matchAll(BARE_URL)) push(m[0]);
    for (const v of Object.values(node)) { if (v && typeof v === 'object') walkBlocks(v); }
  };
  walkBlocks(msg.blocks || []);
  return [...new Set(found)];
}

const isHumanMsg = (m) => !m.bot_id && !!m.user
  && (!m.subtype || HUMAN_SUBTYPES.has(m.subtype));

// --------------------------------------------------------------- I/O guards

function fsFail(msg) {
  const e = new Error(msg);
  e.reason = 'FS';
  return e;
}

function loadState() {
  let raw;
  try { raw = fs.readFileSync(STATE_FILE, 'utf8'); } catch (e) {
    throw fsFail(`state file unreadable: ${STATE_FILE} (${e.message}) — never guess a watermark`);
  }
  let s;
  try { s = JSON.parse(raw); } catch (e) {
    throw fsFail(`state file corrupt: ${STATE_FILE} (${e.message}) — refusing to advance`);
  }
  if (typeof s.last_ts !== 'string' || !/^\d+\.\d+$/.test(s.last_ts)
      || !Array.isArray(s.pending) || !Array.isArray(s.dead)) {
    throw fsFail(`state file malformed: ${STATE_FILE}`);
  }
  return s;
}

function loadMessages() {
  if (!MESSAGES_FILE) throw fsFail('--messages-file is required');
  let raw;
  try { raw = JSON.parse(fs.readFileSync(MESSAGES_FILE, 'utf8')); } catch (e) {
    throw fsFail(`messages file unreadable/invalid: ${MESSAGES_FILE} (${e.message})`);
  }
  const msgs = Array.isArray(raw) ? raw : raw.messages;
  if (!Array.isArray(msgs)) throw fsFail(`messages file has no messages[] array: ${MESSAGES_FILE}`);
  return msgs;
}

function loadLedger() {
  let arr;
  try { arr = JSON.parse(fs.readFileSync(COMMENTS_FILE, 'utf8')); } catch (e) {
    throw fsFail(`comments file unreadable/invalid: ${COMMENTS_FILE} (${e.message})`);
  }
  if (!Array.isArray(arr)) throw fsFail(`${COMMENTS_FILE} is not a JSON array`);
  const byUrl = new Map();
  const byKey = new Map();
  const byFuzzy = new Map();
  for (const e of arr) {
    const n = e.post_url ? normalizeLink(e.post_url) : null;
    if (n && !byUrl.has(n)) byUrl.set(n, e);
    if (e.key && !byKey.has(e.key)) byKey.set(e.key, e);
    const f = fuzzyId(e.author_name, e.post_text);
    if (!byFuzzy.has(f)) byFuzzy.set(f, e);
  }
  return { byUrl, byKey, byFuzzy };
}

// ------------------------------------------------------------------ browser

let context = null;
let postPage = null;

async function launchBrowser() {
  let lastErr;
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      return await chromium.launchPersistentContext(USER_DATA_DIR, {
        channel: 'chrome',
        headless: HEADLESS,
        viewport: { width: 1440, height: 1000 },
        timeout: 30000,
      });
    } catch (e) {
      lastErr = e;
      log(`launch attempt ${attempt} failed: ${String(e.message).split('\n')[0]}`);
      await sleep(3000 * attempt);
    }
  }
  if (/ProcessSingleton|SingletonLock|profile is already in use/i.test(String(lastErr))) {
    console.log('ERROR=PROFILE_LOCKED');
    process.exit(21);
  }
  console.log('ERROR=UNKNOWN');
  console.error(lastErr);
  process.exit(4);
}

async function closeBrowser() {
  try { await context?.close(); } catch { /* already gone */ }
  context = null;
}

for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, async () => {
    log(`${sig} — closing browser and exiting`);
    await closeBrowser();
    process.exit(sig === 'SIGTERM' ? 143 : 130);
  });
}

// Post-detail-page scrape: proven selectors from linkedin-stats scrape-weekly
// (public post pages kept semantic classes when the analytics surfaces lost
// theirs, 2026-07). Expands see-more INSIDE the page function, then reports
// whether a collapsed toggle is still visible (truncation assert).
const POST_PAGE_SCRAPE = async () => {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const container = document.querySelector('.feed-shared-update-v2')
    || document.querySelector('[data-urn^="urn:li:activity"]');
  if (!container) return { found: false, bannerText: (document.body.innerText || '').slice(0, 300) };
  // Only match a COLLAPSED toggle: the same button flips to "…see less" after
  // expansion, so a bare class match would read as still-collapsed forever.
  const findToggle = () => Array.from(container.querySelectorAll('button')).find((b) => {
    if (b.offsetParent === null || b.disabled) return false;
    if (b.closest('.comments-comments-list, .comments-comment-item, .comments-comment-entity')) return false;
    const t = (b.innerText || '').trim().toLowerCase();
    return t === 'see more' || t === '…see more'
      || (/feed-shared-inline-show-more-text__see-more-less-toggle/.test(b.className) && /see more/.test(t));
  });
  for (let i = 0; i < 2; i++) {
    const btn = findToggle();
    if (!btn) break;
    btn.click();
    await sleep(800);
  }
  const bodyEl = container.querySelector('.feed-shared-update-v2__description, .update-components-text');
  // Post pages carry .update-components-actor__title/__description (verified
  // live 2026-07-25 — the bare .update-components-actor block does NOT exist
  // there). innerText doubles the visible + a11y copies of the name and
  // appends "• 2nd"-style badges — prefer the aria-hidden span, strip badges,
  // and collapse an exact "X X" doubling.
  const dedupe = (s) => {
    const m = s.match(/^(.+?)\s+\1$/);
    return m ? m[1] : s;
  };
  const grab = (sel) => {
    const el = container.querySelector(sel);
    if (!el) return '';
    const src = el.querySelector('span[aria-hidden="true"]') || el;
    return dedupe((src.innerText || '').replace(/\s+/g, ' ').trim());
  };
  const author = dedupe(grab('.update-components-actor__title').split('•')[0].trim());
  const headline = grab('.update-components-actor__description');
  const linkEl = container.querySelector('.update-components-actor__container a[href*="/in/"], .update-components-actor__container a[href*="/company/"]')
    || container.querySelector('a[href*="/in/"], a[href*="/company/"]');
  return {
    found: true,
    stillCollapsed: !!findToggle(),
    body: bodyEl ? (bodyEl.innerText || '').trim() : '',
    author,
    headline,
    authorUrl: linkEl ? linkEl.href.split('?')[0] : null,
    bannerText: ((document.querySelector('main') || document.body).innerText || '').slice(0, 300),
  };
};

// Copy-link recovery for /feed/update/ inputs that never redirect to /posts/:
// the feed gather's hardened RECOVER_EVAL pattern (prototype-shadow patches
// restored via delete in finally, execCommand/selection fallbacks, and a
// ~3.2s poll for the async dropdown — a fixed wait caused a real production
// miss on 2026-07-21), scoped to the single post's control menu.
const COPY_LINK_RECOVER = async () => {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const container = document.querySelector('.feed-shared-update-v2')
    || document.querySelector('[data-urn^="urn:li:activity"]');
  if (!container) return { url: null, err: 'no-container' };
  const menuBtn = container.querySelector('button[aria-label*="control menu"], button[aria-label*="Open control menu"]');
  if (!menuBtn) return { url: null, err: 'no-menu-button' };
  const cap = { writeText: null, execCommand: null, selection: null };
  let patchedWrite = false; let patchedExec = false;
  try {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      const origWrite = navigator.clipboard.writeText.bind(navigator.clipboard);
      navigator.clipboard.writeText = (t) => {
        cap.writeText = t;
        return Promise.resolve().then(() => origWrite(t)).catch(() => undefined);
      };
      patchedWrite = true;
    }
    if (document.execCommand) {
      const origExec = document.execCommand.bind(document);
      document.execCommand = (c, ...r) => {
        if (String(c).toLowerCase() === 'copy') {
          try { cap.selection = (document.getSelection() || '').toString(); } catch {}
          const ae = document.activeElement;
          if (ae && (ae.tagName === 'TEXTAREA' || ae.tagName === 'INPUT')) cap.execCommand = ae.value;
        }
        return origExec(c, ...r);
      };
      patchedExec = true;
    }
    menuBtn.scrollIntoView({ block: 'center' });
    await sleep(300);
    menuBtn.click();
    let cand = null;
    for (let waited = 0; !cand && waited < 3200; waited += 400) {
      await sleep(400);
      cand = Array.from(document.querySelectorAll('[role="menuitem"], [role="button"], button, span, div'))
        .find((el) => /^copy link to post$/i.test((el.innerText || '').trim()));
    }
    if (!cand) {
      const items = Array.from(document.querySelectorAll('[role="menuitem"]'))
        .map((el) => (el.innerText || '').trim().split('\n')[0]).filter(Boolean).slice(0, 12);
      document.body.click();
      return { url: null, err: `no-copy-item (menu: ${items.join(' | ') || 'nothing rendered'})` };
    }
    cand.click();
    await sleep(700);
  } finally {
    if (patchedWrite) delete navigator.clipboard.writeText;
    if (patchedExec) delete document.execCommand;
  }
  document.body.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
  document.body.click();
  const captured = cap.writeText || cap.execCommand || cap.selection || null;
  return { url: captured, err: captured ? null : 'no-capture' };
};

function classifyBanner(text) {
  return TOMBSTONE_RE.test(String(text || '').slice(0, 300)) ? 'tombstone' : null;
}

let fetchStub = null;

// Returns {ok, author, authorUrl, headline, body, postUrl, urn, unverified}
// or {fail: 'tombstone'|'transient', reason}
async function fetchPost(job) {
  if (fetchStub) {
    const s = fetchStub[job.url];
    if (!s) return { fail: 'transient', reason: 'no stub entry' };
    return s;
  }
  if (!context) {
    context = await launchBrowser();
    postPage = context.pages()[0] || await context.newPage();
  }
  let resp;
  try {
    resp = await postPage.goto(job.url, { waitUntil: 'domcontentloaded', timeout: 30000 });
  } catch (e) {
    if (/ERR_HTTP_RESPONSE_CODE_FAILURE/.test(String(e.message))) throw new RateLimitError(job.url);
    return { fail: 'transient', reason: `nav: ${String(e.message).split('\n')[0]}` };
  }
  if (resp && (resp.status() === 429 || resp.status() === 999)) throw new RateLimitError(`post ${resp.status()}`);
  if (/\/login|\/checkpoint|\/authwall|\/uas\//.test(postPage.url())) throw new AuthError(postPage.url());
  await postPage.waitForSelector('.feed-shared-update-v2, [data-urn^="urn:li:activity"]',
    { timeout: 12000 }).catch(() => {});
  await sleep(600);
  const got = await postPage.evaluate(POST_PAGE_SCRAPE).catch((e) => ({ found: false, evalErr: String(e.message).split('\n')[0] }));
  if (!got.found) {
    if (classifyBanner(got.bannerText) === 'tombstone') {
      return { fail: 'tombstone', reason: `tombstone banner (${normText(got.bannerText).slice(0, 60)})` };
    }
    return { fail: 'transient', reason: got.evalErr ? `eval: ${got.evalErr}` : 'post container never rendered' };
  }
  // NO tombstone test once the post container rendered: <main>'s leading text
  // IS the post, so a valid post that opens with "this post was deleted…"
  // would false-positive into a dead letter (codex solution-review round 1).
  if (!got.body || got.stillCollapsed) {
    return { fail: 'transient', reason: got.stillCollapsed ? 'body still collapsed after expand' : 'empty body' };
  }
  if (!got.author) return { fail: 'transient', reason: 'no author parsed' };
  const body = got.body.replace(/(…|\.{3})?\s*see more\s*$/i, '').replace(/hashtag\n#/g, '#').trim();
  if (/(…|\.\.\.)\s*more$/i.test(body)) return { fail: 'transient', reason: 'body ends truncated' };

  // Permalink: canonical when the final URL is /posts/; else the trust-classed
  // input (never /feed/update/ — codex-reviewed plan §B6).
  const finalU = new URL(postPage.url());
  let postUrl = null; let unverified = false; let urn = null;
  if (/^(www\.)?linkedin\.com$/.test(finalU.hostname) && /\/posts\//.test(finalU.pathname)) {
    postUrl = `https://www.linkedin.com${finalU.pathname.replace(/\/+$/, '')}`;
    const slugM = finalU.pathname.match(/[-/](activity|ugcPost|share)-(\d{15,25})-[^/]*\/?$/);
    if (slugM) urn = `urn:li:${slugM[1]}:${slugM[2]}`;
  } else if (/^https:\/\/www\.linkedin\.com\/posts\//.test(job.url)) {
    postUrl = job.url; unverified = true;
  } else if (/^https:\/\/lnkd\.in\//.test(job.url)) {
    postUrl = job.url; unverified = true;
  } else {
    // /feed/update/ input that never reached /posts/: one copy-link attempt.
    const rec = await postPage.evaluate(COPY_LINK_RECOVER).catch(() => ({ err: 'threw' }));
    const capd = rec && rec.url && /^https:\/\//.test(rec.url) ? rec.url : null;
    if (capd) {
      const capdNorm = normalizeLink(capd);
      if (capdNorm && /linkedin\.com\/posts\//.test(capdNorm)) { postUrl = capdNorm; unverified = true; }
      else if (capdNorm && /^https:\/\/lnkd\.in\//.test(capdNorm)) { postUrl = capdNorm; unverified = true; }
    }
    if (!postUrl) {
      return { fail: 'transient', reason: `no /posts/ permalink for feed-update input (${rec?.err || 'recovery empty'})` };
    }
  }
  return { ok: true, author: got.author, authorUrl: got.authorUrl, headline: got.headline, body, postUrl, urn, unverified };
}

// --------------------------------------------------------------------- main

async function main() {
  fs.mkdirSync(OUT_DIR, { recursive: true });
  if (FETCH_STUB) fetchStub = JSON.parse(fs.readFileSync(FETCH_STUB, 'utf8'));
  const state = loadState();
  const messages = loadMessages();
  const ledger = loadLedger();

  const counters = {
    msgsScanned: messages.length,
    msgsHuman: 0,
    linksFound: 0,
    accountedDupes: 0,
    skippedAlreadyCommented: 0,
    fetchFailed: 0,
    deadNew: 0,
    revived: 0,
    aliasMerged: 0,
    permalinksUnverified: 0,
  };

  // Clamp the overlap window to the immutable deployment floor: without it,
  // the first fires would replay human messages from BEFORE the documented
  // cutoff (codex solution-review round 1). Absent field → no clamp (legacy
  // state), which only widens the window — dedup still holds.
  let floorTs = tsMinusSecs(state.last_ts, EDIT_OVERLAP_SECS);
  if (typeof state.scan_floor_ts === 'string' && /^\d+\.\d+$/.test(state.scan_floor_ts)
      && tsCmp(state.scan_floor_ts, floorTs) > 0) {
    floorTs = state.scan_floor_ts;
  }
  const humans = messages
    .filter(isHumanMsg)
    .filter((m) => tsCmp(m.ts, floorTs) > 0)
    .sort((a, b) => tsCmp(a.ts, b.ts));
  counters.msgsHuman = humans.length;

  // Dead map (revival: only an explicitly NEW message revives a dead URL).
  const dead = new Map(state.dead.map((d) => [d.url, d]));
  const deadNew = [];

  // Jobs keyed by normalized URL. Pending entries are loaded AFTER
  // resolveLedgerMatch is defined (below) so each is first re-resolved
  // against the CURRENT ledger — an overflowed clickup-only job must come
  // back fetchless, not burn fetch attempts into a false dead-letter
  // (codex solution round 3).
  const jobs = new Map();
  const jobsPendingIn = state.pending.length;
  let jobsNew = 0;

  // Terminal rows keyed by post key (post-fetch identity).
  const rows = new Map();
  // Pre-fetch ledger matches grouped by ledger key so alias URLs of one
  // already-known post coalesce instead of emitting twice (codex round 3).
  const resolvedLedgerKeys = new Map(); // ledger key -> 'dup'|'skip'|rowKey

  // `res` is present on POST-fetch matches (the browser just rendered the
  // post): the row must then carry the FRESH author/body/permalink — 108 of
  // the current legacy drafted-without-task entries hold a profile URL or no
  // URL at all, and a task built from those stale fields would ship the wrong
  // link (codex solution-review round 1).
  const resolveLedgerMatch = (entry, job, res) => {
    const k = entry.key;
    if (resolvedLedgerKeys.has(k)) {
      const prior = resolvedLedgerKeys.get(k);
      if (prior === 'reprocessing') return false; // alias of an in-flight reprocess — fetch it; post-fetch key dedup merges
      if (typeof prior === 'object') {
        // alias of a pending clickup-only JOB (pre-allocation or overflowed)
        prior.requests.push(...job.requests);
        counters.aliasMerged++;
      } else if (rows.has(prior)) {
        rows.get(prior).requests.push(...job.requests);
        counters.aliasMerged++;
      } else if (prior === 'dup') counters.accountedDupes++;
      else counters.skippedAlreadyCommented++;
      return true;
    }
    if (entry.disposition === 'already-commented') {
      counters.skippedAlreadyCommented++;
      resolvedLedgerKeys.set(k, 'skip');
      return true;
    }
    if (entry.disposition === 'drafted') {
      // Completion semantics (codex solution round 3): a drafted entry is
      // DONE only when both delivery legs left evidence — a task id AND a
      // Slack outcome (ts or recorded error). A kill between the ledger
      // write and the Slack posts leaves a drafted entry with neither/one;
      // treating that as complete would silently drop the Slack delivery.
      const needsClickup = !entry.clickup_task_id;
      // Slack is complete only when the THREAD reached the post-text reply
      // (`slack_thread.post_reply_ts`) — the parent `slack_ts` alone means a
      // kill landed mid-thread and the drafts/post link never arrived
      // (codex round 4). A recorded slack_error also terminates the leg.
      const slackDone = !!(entry.slack_ts && entry.slack_thread && entry.slack_thread.post_reply_ts)
        || !!entry.slack_error;
      const needsSlack = !slackDone;
      if (!needsClickup && !needsSlack) {
        counters.accountedDupes++;
        resolvedLedgerKeys.set(k, 'dup');
        return true;
      }
      // ClickUp delivery still owed. POST-fetch (res present — the budget is
      // already spent): emit the row now, keyed by the LEDGER key but with
      // the freshly fetched fields. PRE-fetch: mark the JOB clickup-only and
      // let the unified allocation cap it — pre-round-2 these rows bypassed
      // MAX_LINKS entirely, and 41 current ledger entries are exact-matchable
      // (one snapshot could flood the sequential delivery loop unbounded).
      if (res) {
        rows.set(k, {
          key: k,
          mode: 'clickup-only',
          needSlack: needsSlack,
          matchedKey: k,
          author: res.author,
          authorUrl: res.authorUrl,
          headline: res.headline || '',
          body: res.body,
          postUrl: res.postUrl || entry.post_url,
          urn: res.urn || entry.urn || null,
          requests: [...job.requests],
        });
        resolvedLedgerKeys.set(k, k);
        return true;
      }
      job.mode = 'clickup-only';
      job.needSlack = needsSlack;
      job.needsFetch = false;
      job.entry = entry;
      resolvedLedgerKeys.set(k, job);
      return false; // registers in the jobs map for capped allocation
    }
    if (entry.disposition === 'off-topic') {
      job.mode = 'reprocess-off-topic';
      job.matchedKey = k;
      resolvedLedgerKeys.set(k, 'reprocessing');
      return false; // still needs the fetch
    }
    return false;
  };

  for (const p of state.pending) {
    const job = {
      url: p.url,
      requests: Array.isArray(p.requests) ? [...p.requests] : [],
      attempts: p.attempts || 0,
      first_seen: p.first_seen || nowIso(),
      origin: 'pending',
      needsFetch: true,
      resolution: null,
    };
    const entry = ledger.byUrl.get(p.url);
    if (entry && resolveLedgerMatch(entry, job)) continue; // terminal without fetch (dup / skip)
    jobs.set(p.url, job);
  }

  for (const msg of humans) {
    const isNew = tsCmp(msg.ts, state.last_ts) > 0;
    for (const url of extractLinks(msg)) {
      counters.linksFound++;
      const req = { message_ts: msg.ts, user: msg.user };
      if (jobs.has(url)) { jobs.get(url).requests.push(req); continue; }
      if (dead.has(url)) {
        if (isNew) {
          dead.delete(url); // explicit re-request beats the dead-letter verdict
          counters.revived++;
          jobs.set(url, { url, requests: [req], attempts: 0, first_seen: nowIso(), origin: 'revived', needsFetch: true, resolution: null });
          jobsNew++;
        }
        continue; // window replay of a dead link stays dead (accounted)
      }
      const entry = ledger.byUrl.get(url);
      if (entry) {
        const job = { url, requests: [req], attempts: 0, first_seen: nowIso(), origin: 'new', needsFetch: true, resolution: null };
        jobsNew++;
        if (resolveLedgerMatch(entry, job)) continue; // terminal without fetch
        jobs.set(url, job); // reprocess-off-topic: fetch it
        continue;
      }
      // Unaccounted link — new work. This branch is also reached for links in
      // REPLAYED (≤ watermark) messages: that is the edit-overlap window doing
      // its job (a link added by editing an already-processed message). A
      // replayed link can also look unaccounted because the ledger holds the
      // canonical URL while the message held a short link — fetching is
      // idempotent (post-fetch key dedup resolves it), so processing is safe.
      jobs.set(url, { url, requests: [req], attempts: 0, first_seen: nowIso(), origin: 'new', needsFetch: true, resolution: null });
      jobsNew++;
    }
  }

  // Unified allocation: the cap governs ALL actionable rows — browser
  // fetches AND fetchless clickup-only deliveries — because every row costs
  // the drafting session's sequential delivery loop (codex solution round 2).
  // Pending retries first (oldest first_seen), then new by first request ts.
  const actionable = [...jobs.values()];
  actionable.sort((a, b) => {
    if (a.origin === 'pending' && b.origin !== 'pending') return -1;
    if (b.origin === 'pending' && a.origin !== 'pending') return 1;
    if (a.origin === 'pending') return a.first_seen < b.first_seen ? -1 : 1;
    const at = a.requests[0]?.message_ts || '0.0'; const bt = b.requests[0]?.message_ts || '0.0';
    return tsCmp(at, bt);
  });
  const allocated = actionable.slice(0, MAX_LINKS);
  const overflow = actionable.slice(MAX_LINKS);
  // Allocated clickup-only jobs become rows now (ledger-keyed, ledger
  // fields); overflowed ones go to the durable queue and re-resolve to
  // clickup-only from the ledger on the next fire (stateless — no mode
  // persisted).
  for (const job of allocated) {
    if (job.mode !== 'clickup-only' || job.needsFetch) continue;
    const entry = job.entry;
    rows.set(entry.key, {
      key: entry.key,
      mode: 'clickup-only',
      needSlack: !!job.needSlack,
      matchedKey: entry.key,
      author: entry.author_name,
      authorUrl: entry.author_url,
      headline: entry.author_headline || '',
      body: entry.post_text,
      postUrl: entry.post_url,
      urn: entry.urn || null,
      requests: [...job.requests],
    });
    resolvedLedgerKeys.set(entry.key, entry.key);
  }
  const toFetch = allocated.filter((j) => j.needsFetch);

  const pendingOut = [];
  const toPending = (job, err) => {
    pendingOut.push({
      url: job.url,
      requests: job.requests,
      attempts: job.attempts + (err ? 1 : 0),
      last_error: err || job.last_error || null,
      first_seen: job.first_seen,
    });
  };
  const toDead = (job, reason) => {
    deadNew.push({ url: job.url, requests: job.requests, reason, died_at: nowIso() });
    counters.deadNew++;
  };
  overflow.forEach((j) => toPending(j, null));

  let authAborted = null;
  for (const job of toFetch) {
    if (outOfTime()) { toPending(job, null); continue; }
    if (authAborted) { toPending(job, null); continue; }
    let res;
    try {
      res = await fetchPost(job);
    } catch (e) {
      if (e instanceof AuthError) { authAborted = 'auth'; toPending(job, null); continue; }
      if (e instanceof RateLimitError) {
        stopReason = 'rate-limited';
        toPending(job, null);
        continue;
      }
      res = { fail: 'transient', reason: String(e.message).split('\n')[0] };
    }
    if (res.fail === 'tombstone') { toDead(job, res.reason); log(`dead: ${job.url} — ${res.reason}`); continue; }
    if (res.fail) {
      counters.fetchFailed++;
      const attemptsNow = job.attempts + 1;
      if (attemptsNow >= MAX_ATTEMPTS) {
        toDead(job, `gave up after ${attemptsNow} attempts: ${res.reason}`);
      } else {
        toPending(job, res.reason);
      }
      log(`fetch failed (${job.attempts + 1}/${MAX_ATTEMPTS}): ${job.url} — ${res.reason}`);
      continue;
    }
    if (res.unverified) counters.permalinksUnverified++;
    const key = makeKey(res.author, res.body);
    const fuzzy = fuzzyId(res.author, res.body);
    if (rows.has(key)) { rows.get(key).requests.push(...job.requests); counters.aliasMerged++; continue; }
    // Canonical-URL match first: a short-link alias whose post's OPENING was
    // edited between fires defeats both key and fuzzy identity, but the
    // resolved /posts/ URL still matches the stored entry (codex round 3).
    // Conversely a FUZZY match is disqualified when both sides carry
    // canonical URLs that differ — authors reuse 160-char boilerplate
    // openers across distinct posts, and a false dup would consume the
    // request without a row (codex round 4).
    const canon = res.postUrl ? normalizeLink(res.postUrl) : null;
    let matched = null;
    if (job.matchedKey) {
      matched = ledger.byKey.get(job.matchedKey);
    } else {
      matched = (canon && ledger.byUrl.get(canon)) || ledger.byKey.get(key) || null;
      if (!matched) {
        const fz = ledger.byFuzzy.get(fuzzy);
        const fzUrl = fz && fz.post_url ? normalizeLink(fz.post_url) : null;
        if (fz && !(fzUrl && canon && fzUrl !== canon)) matched = fz;
      }
    }
    if (matched && job.mode !== 'reprocess-off-topic') {
      // The URL was unknown but the POST is known (short-link alias, or a feed
      // scrape with a differently-cut body caught by the fuzzy bridge).
      if (resolveLedgerMatch(matched, job, res)) continue;
      // off-topic fell through: reprocess with the fetched content below.
    }
    const mode = (job.mode === 'reprocess-off-topic' || (matched && matched.disposition === 'off-topic'))
      ? 'reprocess-off-topic' : 'draft';
    rows.set(key, {
      key,
      fuzzy,
      mode,
      matchedKey: mode === 'reprocess-off-topic' ? (job.matchedKey || matched.key) : null,
      author: res.author,
      authorUrl: res.authorUrl,
      headline: res.headline || '',
      body: res.body,
      postUrl: res.postUrl,
      urn: res.urn || null,
      unverified: !!res.unverified,
      requests: job.requests,
    });
    log(`accepted (${mode}): ${key} — ${res.postUrl}`);
  }

  await closeBrowser();

  // Watermark: exact max ts across the WHOLE snapshot (validated by the
  // driver against messages.json), never below the current one.
  let watermark = state.last_ts;
  for (const m of messages) if (m.ts && tsCmp(m.ts, watermark) > 0) watermark = m.ts;

  const proposedState = {
    last_ts: watermark,
    updated_at: nowIso(),
    ...(typeof state.scan_floor_ts === 'string' ? { scan_floor_ts: state.scan_floor_ts } : {}),
    pending: pendingOut,
    dead: [...dead.values(), ...deadNew],
  };
  const proposedStateFile = path.join(OUT_DIR, 'proposed-state.json');
  fs.writeFileSync(proposedStateFile, JSON.stringify(proposedState, null, 2) + '\n');

  const rowList = [...rows.values()];
  const kv = [];
  kv.push(`POSTS_FOUND=${rowList.length}`);
  kv.push(`INBOX_MSGS_SCANNED=${counters.msgsScanned}`);
  kv.push(`INBOX_MSGS_HUMAN=${counters.msgsHuman}`);
  kv.push(`INBOX_LINKS_FOUND=${counters.linksFound}`);
  kv.push(`INBOX_DUPLICATES=${counters.accountedDupes}`);
  kv.push(`INBOX_SKIPPED_ALREADY_COMMENTED=${counters.skippedAlreadyCommented}`);
  kv.push(`INBOX_FETCH_FAILED=${counters.fetchFailed}`);
  kv.push(`INBOX_BACKLOG=${pendingOut.length}`);
  kv.push(`INBOX_DEAD=${proposedState.dead.length}`);
  kv.push(`INBOX_DEAD_NEW=${counters.deadNew}`);
  kv.push(`INBOX_REVIVED=${counters.revived}`);
  kv.push(`PERMALINKS_UNVERIFIED=${counters.permalinksUnverified}`);
  kv.push(`PROPOSED_WATERMARK=${watermark}`);
  kv.push(`PROPOSED_STATE_FILE=${proposedStateFile}`);
  kv.push(`OUT_DIR=${OUT_DIR}`);
  rowList.forEach((r, idx) => {
    const i = idx + 1;
    const textFile = path.join(OUT_DIR, `post-${i}-${r.key}.txt`);
    fs.writeFileSync(textFile, r.body);
    kv.push(`POST_${i}_KEY=${r.key}`);
    kv.push(`POST_${i}_URN=${r.urn || '-'}`);
    kv.push(`POST_${i}_URL=${r.postUrl || '-'}`);
    kv.push(`POST_${i}_AUTHOR_URL=${r.authorUrl || '-'}`);
    kv.push(`POST_${i}_AUTHOR=${String(r.author || '').replace(/\s+/g, ' ').trim()}`);
    kv.push(`POST_${i}_HEADLINE=${String(r.headline || '').replace(/\s+/g, ' ').trim()}`);
    kv.push(`POST_${i}_TIME_AGO=-`);
    kv.push(`POST_${i}_TEXT_FILE=${textFile}`);
    kv.push(`POST_${i}_SOURCE=slack-inbox`);
    kv.push(`POST_${i}_SOURCE_TS=${r.requests[0]?.message_ts || '-'}`);
    kv.push(`POST_${i}_SOURCE_USER=${r.requests[0]?.user || '-'}`);
    kv.push(`POST_${i}_REQUESTS=${JSON.stringify(r.requests)}`);
    kv.push(`POST_${i}_MODE=${r.mode}`);
    kv.push(`POST_${i}_MATCHED_KEY=${r.matchedKey || '-'}`);
    // clickup-only rows: 1 when the entry has no Slack evidence (a kill
    // landed between the ledger write and the Slack posts) — the drafting
    // session must re-deliver the Slack leg from the entry's stored variants.
    kv.push(`POST_${i}_NEED_SLACK=${r.mode === 'clickup-only' ? (r.needSlack ? 1 : 0) : 1}`);
  });
  const contract = kv.join('\n') + '\n';
  const tmp = path.join(OUT_DIR, 'contract.env.tmp');
  fs.writeFileSync(tmp, contract);
  fs.renameSync(tmp, path.join(OUT_DIR, 'contract.env'));

  // keys.json: identities of every emitted row — the feed gather's
  // --extra-seen-file (same-fire cross-source dedup) and the skill's Step
  // 2a-0 union gate. `url` lets the gate catch a same-post duplicate whose
  // body was edited between the ledger snapshot and the feed scrape (key and
  // fuzzy both differ, the canonical permalink doesn't — codex round 4).
  fs.writeFileSync(path.join(OUT_DIR, 'keys.json'), JSON.stringify(
    rowList.map((r) => ({
      key: r.key,
      fuzzy: r.fuzzy || fuzzyId(r.author, r.body),
      url: r.postUrl ? normalizeLink(r.postUrl) : null,
    })), null, 2) + '\n');

  // Conservation manifest (driver re-checks the arithmetic).
  const conservation = {
    jobs_pending_in: jobsPendingIn,
    jobs_new: jobsNew,
    contract_rows: rowList.length,
    pending_out: pendingOut.length,
    dead_new: counters.deadNew,
    accounted_dupes: counters.accountedDupes,
    skipped_already_commented: counters.skippedAlreadyCommented,
    alias_merged: counters.aliasMerged,
  };
  fs.writeFileSync(path.join(OUT_DIR, 'manifest.json'), JSON.stringify({
    ts: nowIso(),
    elapsed_secs: Math.round((Date.now() - t0) / 1000),
    stop_reason: stopReason,
    auth_aborted: !!authAborted,
    watermark,
    counters,
    conservation,
    // New dead letters by URL + reason — the driver quotes these in the ⚠️
    // bookend so Peter knows exactly what to re-drop (a bare count is
    // unactionable).
    dead_new_detail: deadNew.map((d) => ({ url: d.url, reason: d.reason })),
    fetch_stub: !!FETCH_STUB,
  }, null, 2) + '\n');
  process.stdout.write(contract);

  log(`done: ${rowList.length} rows, ${pendingOut.length} pending, ${counters.deadNew} dead, `
    + `${counters.accountedDupes} dup, ${counters.skippedAlreadyCommented} already-commented, `
    + `${Math.round((Date.now() - t0) / 1000)}s`);

  if (authAborted && rowList.length === 0) {
    console.log('ERROR=AUTH');
    return 20;
  }
  if (stopReason === 'rate-limited' && rowList.length === 0) {
    console.log('ERROR=RATE_LIMITED');
    return 22;
  }
  if (counters.fetchFailed > 0 || stopReason || authAborted || overflow.length > 0) return 10;
  return 0;
}

main().then((code) => process.exit(code)).catch(async (e) => {
  await closeBrowser();
  if (e instanceof AuthError) {
    console.log('ERROR=AUTH');
    console.error(`auth wall: ${e.message}`);
    process.exit(20);
  }
  if (e instanceof RateLimitError) {
    console.log('ERROR=RATE_LIMITED');
    console.error(`rate-limited: ${e.message}`);
    process.exit(22);
  }
  if (e && e.reason === 'FS') {
    console.log('ERROR=FS');
    console.error(e.message);
    process.exit(23);
  }
  console.log('ERROR=UNKNOWN');
  console.error(e);
  process.exit(4);
});
