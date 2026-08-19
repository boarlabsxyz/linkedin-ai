#!/usr/bin/env node
// Regression suite for the ICP gate — browser-free, no `claude -p` calls.
// Run: node .claude/skills/linkedin-comment-hourly/fast/test-icp-gate.mjs
//
// Covers the parts of gate 2 that decide things without the network: author
// identity, the icp-filter.md allow/deny parsing, cache invalidation, and the
// precedence order those three resolve in. The LLM half (card verdict, profile
// probe) is exercised by the offline hit-rate probe:
//   node fast/gather-feed.mjs --probe-file=<corpus.json>

import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { profileKey, readProfileList, headlineHash } from './keys.mjs';
import { icpWithoutProbe, __test } from './gather-feed.mjs';
import { recordAgeDays, cachedProfileData, profileFileName } from '../../pipeline-shared/profile-store.mjs';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(SCRIPT_DIR, '..', '..', '..', '..');

let passed = 0;
const test = (name, fn) => {
  try { fn(); passed++; console.log(`ok   ${name}`); }
  catch (err) { console.error(`FAIL ${name}\n     ${err.message}`); process.exitCode = 1; }
};

const card = (over = {}) => ({
  on_topic: true, reason: 'ai tooling', icp: true, icpConfidence: 'high',
  icpReason: 'maintainer of a coding agent', model: 'test-model', ...over,
});

// ------------------------------------------------------------ author identity

test('profileKey normalizes every shape LinkedIn hands out', () => {
  assert.equal(profileKey('https://www.linkedin.com/in/greg-ceccarelli/'), 'in/greg-ceccarelli');
  assert.equal(profileKey('https://www.linkedin.com/in/Greg-Ceccarelli?trk=feed'), 'in/greg-ceccarelli');
  assert.equal(profileKey('https://linkedin.com/in/dax/recent-activity/all/'), 'in/dax');
  assert.equal(profileKey('/in/relative-form'), 'in/relative-form');
  assert.equal(profileKey('https://www.linkedin.com/in/%C3%BCmit'), 'in/ümit');
});

test('profileKey collapses NFD and NFC so one human gets one profile file', () => {
  // %C3%A5 is the composed 'å'; 'a' + %CC%8A is the decomposed pair. Without
  // NFC these are two keys — and now two FILES — for one person.
  const nfc = profileKey('https://www.linkedin.com/in/nimish-g%C3%A5tam-44125512');
  const nfd = profileKey('https://www.linkedin.com/in/nimish-ga%CC%8Atam-44125512');
  assert.equal(nfd, nfc);
  assert.equal(profileFileName(nfd), profileFileName(nfc));
});

test('profileKey refuses anything that is not a member profile', () => {
  for (const bad of [
    '', null, undefined, 'not a url',
    'https://www.linkedin.com/company/anthropic/',
    'https://www.linkedin.com/feed/',
    'https://evil.example.com/in/someone',
  ]) assert.equal(profileKey(bad), '', `expected no key for ${String(bad)}`);
});

test('headlineHash ignores case and whitespace but not content', () => {
  assert.equal(headlineHash('  Co-founder   @ SpecStory '), headlineHash('co-founder @ specstory'));
  assert.notEqual(headlineHash('Co-founder @ SpecStory'), headlineHash('CTO @ SpecStory'));
});

// -------------------------------------------------------- icp-filter.md lists

const SAMPLE_MD = `
# ICP gate

Format is \`- https://www.linkedin.com/in/inline-code-must-not-count\`.

\`\`\`
- https://www.linkedin.com/in/fenced-example-must-not-count
\`\`\`

Prose naming https://www.linkedin.com/in/prose-must-not-count is not a bullet.

## Always accept

- https://www.linkedin.com/in/Allowed-One — a note with punctuation
- https://www.linkedin.com/in/allowed-two/?trk=x and https://linkedin.com/in/allowed-three

## Never accept

- https://www.linkedin.com/in/denied-one — keeps slipping through
`;

test('readProfileList takes only bullets, and only inside the named section', () => {
  const allow = readProfileList(SAMPLE_MD, 'always accept');
  assert.deepEqual([...allow].sort(), ['in/allowed-one', 'in/allowed-three', 'in/allowed-two']);
  const deny = readProfileList(SAMPLE_MD, 'never accept');
  assert.deepEqual([...deny], ['in/denied-one']);
});

test('readProfileList ignores fenced examples, inline code and prose', () => {
  const all = readProfileList(SAMPLE_MD);
  for (const ghost of ['in/fenced-example-must-not-count', 'in/inline-code-must-not-count', 'in/prose-must-not-count']) {
    assert.ok(!all.has(ghost), `${ghost} must not parse as a real entry`);
  }
});

test('the shipped icp-filter.md parses to empty lists, not to its own examples', () => {
  const md = fs.readFileSync(path.join(SCRIPT_DIR, '..', 'icp-filter.md'), 'utf8');
  assert.equal(readProfileList(md, 'always accept').size, 0);
  assert.equal(readProfileList(md, 'never accept').size, 0);
});

test('the ICP rubric the gate ships with is present and non-trivial', () => {
  const icp = fs.readFileSync(path.join(REPO_ROOT, 'sources', 'icp.md'), 'utf8');
  assert.ok(icp.trim().length > 500, 'sources/icp.md should hold the real rubric');
});

// ---------------------------------------------------------------- cache rules

const RUBRIC = 'rubric-v1';
const day = (n) => new Date(Date.now() - n * 86_400_000).toISOString();

// One person's file under dashboards/profiles/. Profile-first: the verdict is
// a nested, invalidatable block, and the scrape outlives it.
const profileRecord = (over = {}) => {
  const { icp: icpOver, ...rest } = over;
  return {
    schema: 1,
    key: 'in/x',
    profile_url: 'https://www.linkedin.com/in/x',
    name: 'X Person',
    headline: 'Founder @ Agentic',
    headline_hash: headlineHash('Founder @ Agentic'),
    first_seen_at: day(30),
    updated_at: day(0),
    scraped_at: new Date().toISOString(),
    profile_text: 'About: maintains a coding agent',
    icp: icpOver === null ? null : {
      verdict: true, confidence: 'high', reason: 'ok', evidence: 'profile', model: 'm',
      rubric_hash: RUBRIC, headline_hash: headlineHash('Founder @ Agentic'),
      decided_at: new Date().toISOString(),
      ...icpOver,
    },
    ...rest,
  };
};
__test.setRubricHash(RUBRIC);

test('a fresh profile record hits', () => {
  __test.setIcpState({ records: { 'in/x': profileRecord() } });
  assert.equal(__test.icpCacheGet('in/x', 'Founder @ Agentic').verdict, true);
});

test('a changed headline invalidates a CARD verdict — re-judging one is free', () => {
  __test.setIcpState({ records: { 'in/x': profileRecord({ icp: { evidence: 'card' } }) } });
  assert.equal(__test.icpCacheGet('in/x', 'VP Sales @ Agentic'), null);
  assert.equal(__test.icpCacheGet('in/x', 'Founder @ Agentic').verdict, true);
});

test('a changed headline does NOT invalidate a PROFILE verdict inside the window', () => {
  // Peter's rule (2026-08-18): a profile read once is not read again for the
  // TTL, whatever else moves about the person.
  __test.setIcpState({ records: { 'in/x': profileRecord({ icp: { evidence: 'profile' } }) } });
  assert.equal(__test.icpCacheGet('in/x', 'VP Sales @ Somewhere Else').verdict, true);
});

test('the default no-touch window is 10 days', () => {
  assert.equal(__test.ICP_CACHE_TTL_DAYS, 10);
});

test('the window is measured from the SCRAPE, not from the verdict', () => {
  // A re-judge stamps a new decided_at; if that reset the window, a profile
  // read once would never be re-read.
  const rec = profileRecord({ scraped_at: day(11), icp: { decided_at: day(0) } });
  assert.ok(recordAgeDays(rec) > 10, 'an 11-day-old scrape is stale however fresh the verdict');
  assert.equal(cachedProfileData(rec), null, 'and its data is no longer reusable');
});

test('a profile read inside the window blocks another page load', () => {
  __test.setIcpState({ records: { 'in/x': profileRecord({ scraped_at: day(9) }) } });
  assert.equal(__test.profileReadRecently('in/x'), true);
  __test.setIcpState({ records: { 'in/x': profileRecord({ scraped_at: day(11) }) } });
  assert.equal(__test.profileReadRecently('in/x'), false);
  // A card-only record has no scrape date at all — that is what "no page was
  // opened" looks like on disk. (A record that HAS a scraped_at was scraped,
  // whatever its latest verdict happened to be judged from.)
  __test.setIcpState({
    records: {
      'in/x': profileRecord({
        scraped_at: null, profile_text: null,
        icp: { evidence: 'card', decided_at: day(1) },
      }),
    },
  });
  assert.equal(__test.profileReadRecently('in/x'), false, 'a card verdict opened no page');
  assert.equal(__test.profileReadRecently(''), false);
});

test('a verdict from a DIFFERENT ICP rubric is dropped, but its data survives', () => {
  // The whole point of caching scraped data: the ICP definition moves, the
  // profile text does not, so the author is re-judged offline.
  const stale = profileRecord({ icp: { rubric_hash: 'rubric-v0' } });
  __test.setIcpState({ records: { 'in/x': stale } });
  assert.equal(__test.icpCacheGet('in/x', 'Founder @ Agentic'), null, 'verdict is not today\'s answer');
  assert.equal(cachedProfileData(stale), 'About: maintains a coding agent', 'data is still usable');
  assert.equal(__test.profileReadRecently('in/x'), true, 'and the page must not be re-opened');
});

test('cachedProfileData refuses what cannot be re-judged', () => {
  assert.equal(cachedProfileData(null), null);
  assert.equal(cachedProfileData(profileRecord({ scraped_at: null, profile_text: null })), null,
    'no page was ever read');
  assert.equal(cachedProfileData(profileRecord({ profile_text: '   ' })), null, 'empty scrape');
  assert.equal(cachedProfileData(profileRecord({ scraped_at: day(11) })), null, 'outside the window');
});

test('a headline-only verdict never deletes a scrape the other pipeline paid for', () => {
  // linkedin-stats writes card verdicts into the same store. If that dropped
  // profile_text, the feed gate would re-open pages it already read.
  __test.setIcpState({ records: { 'in/x': profileRecord({ scraped_at: day(2) }) } });
  __test.icpCacheSet('in/x', 'Founder @ Agentic', {
    verdict: false, confidence: 'high', reason: 'headline says sales', evidence: 'card', model: 'm',
  });
  const rec = __test.getProfile('in/x');
  assert.equal(rec.icp.evidence, 'card', 'the verdict was judged from a card');
  assert.equal(rec.profile_text, 'About: maintains a coding agent', 'but the scrape survives');
  assert.equal(rec.scraped_at, day(2), 'and so does its date');
  assert.equal(__test.profileReadRecently('in/x'), true, 'so the page still must not be re-opened');
});

test('a re-judge keeps the original scrape date, text and URL', () => {
  __test.setIcpState({
    records: {
      'in/x': profileRecord({
        scraped_at: day(3),
        icp: { verdict: false, rubric_hash: 'old' },
      }),
    },
  });
  // evidence 'profile' with NO profileText = a re-judge off stored data.
  __test.icpCacheSet('in/x', 'Founder @ Agentic', {
    verdict: true, confidence: 'high', reason: 'rubric widened', evidence: 'profile', model: 'm',
  });
  const rec = __test.getProfile('in/x');
  assert.equal(rec.icp.verdict, true);
  assert.equal(rec.icp.rubric_hash, RUBRIC, 're-stamped with the rubric that judged it');
  assert.equal(rec.profile_text, 'About: maintains a coding agent', 'data carried over');
  assert.equal(rec.profile_url, 'https://www.linkedin.com/in/x');
  assert.equal(rec.scraped_at, day(3), 'the no-touch window must NOT slide forward');
});

test('a profile read that failed to classify still blocks the next page load', () => {
  // verdict: null — the page was read but no verdict came back. There is
  // nothing to use (icpCacheGet skips it) but the read must not repeat.
  __test.setIcpState({});
  __test.icpCacheSet('in/x', 'Founder @ Agentic', {
    verdict: null, confidence: 'low', reason: 'profile read; not classified yet',
    evidence: 'profile', profileUrl: 'https://www.linkedin.com/in/x/', profileText: 'About: builds a coding agent',
  });
  assert.equal(__test.icpCacheGet('in/x', 'Founder @ Agentic'), null, 'no verdict to hand out');
  assert.equal(__test.profileReadRecently('in/x'), true, 'but the page must not be re-opened');
  assert.equal(__test.getProfile('in/x').icp.verdict, null);
});

test('a profile record stores the page text and URL it was judged from', () => {
  __test.setIcpState({});
  __test.icpCacheSet('in/x', 'Founder @ Agentic', {
    verdict: true, confidence: 'high', reason: 'maintains a coding agent', evidence: 'profile',
    model: 'm', profileUrl: 'https://www.linkedin.com/in/x/', profileText: 'About: builds a coding agent',
  });
  const rec = __test.getProfile('in/x');
  assert.equal(rec.profile_url, 'https://www.linkedin.com/in/x/');
  assert.equal(rec.profile_text, 'About: builds a coding agent');
  assert.equal(rec.headline, 'Founder @ Agentic');
  assert.equal(rec.key, 'in/x');
});

test('a card record with no prior scrape stores no page text', () => {
  __test.setIcpState({});
  __test.icpCacheSet('in/x', 'Founder @ Agentic', {
    verdict: true, confidence: 'high', reason: 'r', evidence: 'card', model: 'm',
  });
  const rec = __test.getProfile('in/x');
  assert.equal(rec.profile_text, null);
  assert.equal(rec.scraped_at, null);
  assert.equal(__test.profileReadRecently('in/x'), false);
});

test('the shared module is the single implementation both pipelines import', async () => {
  const shared = await import('../../pipeline-shared/profile-store.mjs');
  const keys = await import('./keys.mjs');
  assert.equal(keys.profileKey, shared.profileKey, 'keys.mjs must re-export, not re-implement');
  assert.equal(keys.headlineHash, shared.headlineHash);
  assert.equal(keys.readProfileList, shared.readProfileList);
  assert.equal(shared.PROFILES_REL_DIR, 'dashboards/profiles');
  assert.equal(shared.DEFAULT_TTL_DAYS, 10);
  // Both pipelines must hash the same texts in the same order.
  assert.equal(shared.rubricHash('a', 'b'), shared.rubricHash('a', 'b'));
  assert.notEqual(shared.rubricHash('a', 'b'), shared.rubricHash('b', 'a'));
});

test('a verdict older than the TTL invalidates', () => {
  const old = new Date(Date.now() - (__test.ICP_CACHE_TTL_DAYS + 1) * 86_400_000).toISOString();
  __test.setIcpState({ records: { 'in/x': profileRecord({ scraped_at: old }) } });
  assert.equal(__test.icpCacheGet('in/x', 'Founder @ Agentic'), null);
  const fresh = new Date(Date.now() - (__test.ICP_CACHE_TTL_DAYS - 1) * 86_400_000).toISOString();
  __test.setIcpState({ records: { 'in/x': profileRecord({ scraped_at: fresh }) } });
  assert.equal(__test.icpCacheGet('in/x', 'Founder @ Agentic').verdict, true);
});

test('a malformed, undated or unkeyed record is a miss, never a crash', () => {
  __test.setIcpState({
    records: {
      'in/no-verdict': profileRecord({ icp: { verdict: 'yes' } }),
      'in/no-date': profileRecord({ scraped_at: null, icp: { decided_at: null } }),
      'in/no-icp': profileRecord({ icp: null }),
    },
  });
  assert.equal(__test.icpCacheGet('in/no-verdict', 'Founder @ Agentic'), null);
  assert.equal(__test.icpCacheGet('in/no-date', 'Founder @ Agentic'), null);
  assert.equal(__test.icpCacheGet('in/no-icp', 'Founder @ Agentic'), null);
  assert.equal(__test.icpCacheGet('', 'Founder @ Agentic'), null);
  assert.equal(__test.icpCacheGet('in/absent', 'Founder @ Agentic'), null);
});

test('icpCacheSet needs a profile key — an anonymous author is never stored', () => {
  __test.setIcpState({});
  __test.icpCacheSet('', 'Founder @ Agentic', { verdict: true, confidence: 'high', reason: 'r', evidence: 'card' });
  assert.equal(__test.getProfile(''), null);
  assert.equal(__test.getStore().dirtyCount(), 0);
});

// ----------------------------------------------------------- precedence order

test('the deny list beats everything, including a confident true verdict', () => {
  __test.setIcpState({
    allow: ['in/p'], deny: ['in/p'],
    records: { 'in/p': profileRecord({ key: 'in/p', icp: { verdict: true } }) },
  });
  const d = icpWithoutProbe('in/p', 'Founder @ Agentic', card({ icp: true, icpConfidence: 'high' }));
  assert.equal(d.verdict, false);
  assert.equal(d.source, 'denylist');
});

test('the allow list beats a cached false and a confident false verdict', () => {
  __test.setIcpState({
    allow: ['in/p'],
    records: { 'in/p': profileRecord({ key: 'in/p', icp: { verdict: false } }) },
  });
  const d = icpWithoutProbe('in/p', 'Founder @ Agentic', card({ icp: false, icpConfidence: 'high' }));
  assert.equal(d.verdict, true);
  assert.equal(d.source, 'allowlist');
});

test('a cached verdict beats the classifier and does not re-cache', () => {
  __test.setIcpState({
    records: {
      'in/p': profileRecord({
        key: 'in/p',
        icp: { verdict: false, evidence: 'profile', reason: 'sales role' },
      }),
    },
  });
  const before = __test.counters.icpCacheHits;
  const d = icpWithoutProbe('in/p', 'Founder @ Agentic', card({ icp: true, icpConfidence: 'high' }));
  assert.equal(d.verdict, false);
  assert.equal(d.source, 'cache/profile');
  assert.equal(__test.counters.icpCacheHits, before + 1);
  assert.equal(__test.getProfile('in/p').icp.reason, 'sales role');
  assert.equal(__test.getStore().dirtyCount(), 0, 'a cache hit must not rewrite the file');
});

test('a confident card verdict decides and is written to the store', () => {
  __test.setIcpState({});
  const d = icpWithoutProbe('in/p', 'Founder @ Agentic', card({ icp: true, icpConfidence: 'high' }));
  assert.equal(d.verdict, true);
  assert.equal(d.source, 'card');
  assert.equal(__test.getProfile('in/p').icp.evidence, 'card');
  assert.equal(__test.getProfile('in/p').icp.headline_hash, headlineHash('Founder @ Agentic'));
});

test('a confident FALSE card verdict also decides — that is the common reject', () => {
  __test.setIcpState({});
  const d = icpWithoutProbe('in/p', 'VP Sales', card({ icp: false, icpConfidence: 'high' }));
  assert.equal(d.verdict, false);
  assert.equal(d.source, 'card');
});

test('low confidence escalates to the probe instead of guessing, either way', () => {
  __test.setIcpState({});
  assert.equal(icpWithoutProbe('in/p', 'Building things', card({ icp: true, icpConfidence: 'low' })), null);
  assert.equal(icpWithoutProbe('in/p', 'Building things', card({ icp: false, icpConfidence: 'low' })), null);
  assert.equal(__test.getProfile('in/p'), null, 'an unsettled author must not be stored');
  assert.equal(__test.getStore().dirtyCount(), 0);
});

test('an author with no profile link still gets a card verdict, just no file', () => {
  __test.setIcpState({ deny: ['in/p'] });
  const d = icpWithoutProbe('', 'Founder @ Agentic', card({ icp: true, icpConfidence: 'high' }));
  assert.equal(d.verdict, true);
  assert.equal(__test.getStore().dirtyCount(), 0);
});

console.log(`\n${passed} passed${process.exitCode ? ' — WITH FAILURES' : ''}`);
