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

// Person identity, the headline hash and the icp-filter.md bullet parser now
// live in the SHARED profile store — linkedin-stats needs the same
// implementations, and two copies would silently diverge. Re-exported here so
// gather-feed/gather-inbox keep importing every identity helper from one place.
export {
  profileKey, headlineHash, readProfileList,
} from '../../pipeline-shared/profile-store.mjs';
