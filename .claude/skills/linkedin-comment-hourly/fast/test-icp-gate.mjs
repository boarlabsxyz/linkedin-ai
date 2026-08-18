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

const cacheEntry = (over = {}) => ({
  verdict: true, confidence: 'high', reason: 'ok', evidence: 'profile',
  headline_hash: headlineHash('Founder @ Agentic'), model: 'm',
  decided_at: new Date().toISOString(), ...over,
});

test('a fresh cache entry hits', () => {
  __test.setIcpState({ cache: { 'in/x': cacheEntry() } });
  assert.equal(__test.icpCacheGet('in/x', 'Founder @ Agentic').verdict, true);
});

test('a changed headline invalidates the cached verdict', () => {
  __test.setIcpState({ cache: { 'in/x': cacheEntry() } });
  assert.equal(__test.icpCacheGet('in/x', 'VP Sales @ Agentic'), null);
});

test('a verdict older than the TTL invalidates', () => {
  const old = new Date(Date.now() - (__test.ICP_CACHE_TTL_DAYS + 1) * 86_400_000).toISOString();
  __test.setIcpState({ cache: { 'in/x': cacheEntry({ decided_at: old }) } });
  assert.equal(__test.icpCacheGet('in/x', 'Founder @ Agentic'), null);
  const fresh = new Date(Date.now() - (__test.ICP_CACHE_TTL_DAYS - 1) * 86_400_000).toISOString();
  __test.setIcpState({ cache: { 'in/x': cacheEntry({ decided_at: fresh }) } });
  assert.equal(__test.icpCacheGet('in/x', 'Founder @ Agentic').verdict, true);
});

test('a malformed, undated or unkeyed entry is a miss, never a crash', () => {
  __test.setIcpState({
    cache: {
      'in/no-verdict': cacheEntry({ verdict: 'yes' }),
      'in/no-date': cacheEntry({ decided_at: undefined }),
    },
  });
  assert.equal(__test.icpCacheGet('in/no-verdict', 'Founder @ Agentic'), null);
  assert.equal(__test.icpCacheGet('in/no-date', 'Founder @ Agentic'), null);
  assert.equal(__test.icpCacheGet('', 'Founder @ Agentic'), null);
  assert.equal(__test.icpCacheGet('in/absent', 'Founder @ Agentic'), null);
});

test('icpCacheSet needs a profile key — an anonymous author is never cached', () => {
  __test.setIcpState({});
  __test.icpCacheSet('', 'Founder @ Agentic', { verdict: true, confidence: 'high', reason: 'r', evidence: 'card' });
  assert.deepEqual(__test.getIcpCache(), {});
});

// ----------------------------------------------------------- precedence order

test('the deny list beats everything, including a confident true verdict', () => {
  __test.setIcpState({
    allow: ['in/p'], deny: ['in/p'],
    cache: { 'in/p': cacheEntry({ verdict: true }) },
  });
  const d = icpWithoutProbe('in/p', 'Founder @ Agentic', card({ icp: true, icpConfidence: 'high' }));
  assert.equal(d.verdict, false);
  assert.equal(d.source, 'denylist');
});

test('the allow list beats a cached false and a confident false verdict', () => {
  __test.setIcpState({ allow: ['in/p'], cache: { 'in/p': cacheEntry({ verdict: false }) } });
  const d = icpWithoutProbe('in/p', 'Founder @ Agentic', card({ icp: false, icpConfidence: 'high' }));
  assert.equal(d.verdict, true);
  assert.equal(d.source, 'allowlist');
});

test('a cached verdict beats the classifier and does not re-cache', () => {
  __test.setIcpState({ cache: { 'in/p': cacheEntry({ verdict: false, evidence: 'profile', reason: 'sales role' }) } });
  const before = __test.counters.icpCacheHits;
  const d = icpWithoutProbe('in/p', 'Founder @ Agentic', card({ icp: true, icpConfidence: 'high' }));
  assert.equal(d.verdict, false);
  assert.equal(d.source, 'cache/profile');
  assert.equal(__test.counters.icpCacheHits, before + 1);
  assert.equal(__test.getIcpCache()['in/p'].reason, 'sales role');
});

test('a confident card verdict decides and is written to the cache', () => {
  __test.setIcpState({});
  const d = icpWithoutProbe('in/p', 'Founder @ Agentic', card({ icp: true, icpConfidence: 'high' }));
  assert.equal(d.verdict, true);
  assert.equal(d.source, 'card');
  assert.equal(__test.getIcpCache()['in/p'].evidence, 'card');
  assert.equal(__test.getIcpCache()['in/p'].headline_hash, headlineHash('Founder @ Agentic'));
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
  assert.deepEqual(__test.getIcpCache(), {}, 'an unsettled author must not be cached');
});

test('an author with no profile link still gets a card verdict, just no cache', () => {
  __test.setIcpState({ deny: ['in/p'] });
  const d = icpWithoutProbe('', 'Founder @ Agentic', card({ icp: true, icpConfidence: 'high' }));
  assert.equal(d.verdict, true);
  assert.deepEqual(__test.getIcpCache(), {});
});

console.log(`\n${passed} passed${process.exitCode ? ' — WITH FAILURES' : ''}`);
