// Shared post-identity helpers for the linkedin-comment-hourly fast scripts.
// Extracted verbatim from gather-feed.mjs so gather-inbox.mjs computes
// byte-identical keys — cross-source dedup (feed vs Slack-dropped links)
// depends on both scripts agreeing on <author-slug>-<body-hash8> and the
// fuzzy bridge. Pure string functions only; anything stateful stays in the
// scripts.
//
// Forward-only key scheme: same `<author-slug>-<body-hash8>` FORMAT the agent
// used, but computed natively (NFKD + Cyrillic translit + sha256 of
// whitespace-collapsed body). Byte-parity with the legacy bash pipeline
// (iconv//TRANSLIT + tr + shasum) is NOT guaranteed — the fuzzy secondary
// dedup below is what bridges entries written by the old agent.

import crypto from 'node:crypto';

const CYR = {
  а: 'a', б: 'b', в: 'v', г: 'h', ґ: 'g', д: 'd', е: 'e', є: 'ie', ж: 'zh', з: 'z',
  и: 'y', і: 'i', ї: 'i', й: 'i', к: 'k', л: 'l', м: 'm', н: 'n', о: 'o', п: 'p',
  р: 'r', с: 's', т: 't', у: 'u', ф: 'f', х: 'kh', ц: 'ts', ч: 'ch', ш: 'sh',
  щ: 'shch', ь: '', ю: 'iu', я: 'ia', ы: 'y', э: 'e', ё: 'e', ъ: '',
};

export function authorSlug(author) {
  let s = author.normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[Ѐ-ӿ]/g, (ch) => CYR[ch] ?? '');
  s = s.replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').replace(/-{2,}/g, '-');
  return (s || 'author').slice(0, 40).replace(/-+$/, '');
}

export const normText = (s) => (s || '').replace(/[​‌‍﻿]/g, '').toLowerCase().replace(/\s+/g, ' ').trim();

export function makeKey(author, body) {
  const hash = crypto.createHash('sha256').update(normText(body), 'utf8').digest('hex').slice(0, 8);
  return `${authorSlug(author)}-${hash}`;
}

// Fuzzy bridge to legacy entries: normalized author + first 160 chars of the
// normalized body. Catches the same card even when the hash recipe differs
// (legacy bash normalization vs ours, footer-cut differences, …).
export const fuzzyId = (author, body) => `${normText(author)}|${normText(body).slice(0, 160)}`;

// A cached ICP verdict is only valid for the headline that produced it — same
// invalidation idea as linkedin-stats/fast/classify-icp.mjs `headlineHash`.
export const headlineHash = (headline) =>
  crypto.createHash('sha256').update(normText(headline), 'utf8').digest('hex').slice(0, 16);

// ---------------------------------------------------------- person identity

// Author identity for the ICP gate: the normalized profile path, e.g.
// "in/gregceccarelli". Same shape linkedin-stats/fast/people.mjs `personKey`
// stores, so a verdict is portable between the two pipelines. Returns '' when
// the card carried no usable profile link — an author without an identity is
// never cached and never allow/deny-listed, only classified per post.
export function profileKey(url) {
  const raw = String(url || '').trim();
  if (!raw) return '';
  try {
    const u = new URL(raw, 'https://www.linkedin.com');
    if (!/(^|\.)linkedin\.com$/i.test(u.hostname)) return '';
    const m = u.pathname.match(/\/in\/([^/?#]+)/i);
    if (!m) return '';
    const slug = decodeURIComponent(m[1]).replace(/\/+$/, '').toLowerCase();
    return /[a-z0-9]/i.test(slug) ? `in/${slug}` : '';
  } catch { return ''; }
}

// Profile-URL bullets out of a markdown section of `file`, keyed like
// profileKey(). Only `- ` / `* ` bullet lines count, and fenced/inline code is
// stripped first — otherwise the file's own format example and the prose
// describing it parse as real entries (exactly how readVipKeys in
// .github/scripts/build-stats-json.mjs got burned on its first run).
//
// `section` is a case-insensitive heading substring: bullets are collected only
// while the nearest preceding `#`-heading matches it. Omit it to take every
// bullet in the file.
export function readProfileList(md, section = null) {
  const clean = String(md || '')
    .replace(/```[\s\S]*?```/g, '')
    .replace(/`[^`\n]*`/g, '');
  const want = section ? section.toLowerCase() : null;
  const keys = new Set();
  let inSection = !want;
  for (const line of clean.split('\n')) {
    const h = line.match(/^\s{0,3}#{1,6}\s+(.*)$/);
    if (h) { inSection = !want || h[1].toLowerCase().includes(want); continue; }
    if (!inSection) continue;
    if (!/^\s*[-*]\s/.test(line)) continue;
    for (const m of line.matchAll(/https?:\/\/(?:[a-z0-9-]+\.)*linkedin\.com\/in\/([A-Za-z0-9\-_%.]+)/gi)) {
      const k = profileKey(`https://www.linkedin.com/in/${m[1]}`);
      if (k) keys.add(k);
    }
  }
  return keys;
}
