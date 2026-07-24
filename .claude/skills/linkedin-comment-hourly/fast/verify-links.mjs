#!/usr/bin/env node
// Independent check: open every POST_<i>_URL from a gather contract and
// confirm the post renders (not "cannot be displayed") with the right author.
// Usage: node tmp/verify-contract-links.mjs <path-to-contract.env>
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright-core');

const USER_DATA_DIR = path.join(process.env.HOME, 'Library', 'Caches', 'ms-playwright', 'mcp-chrome-linkedin-ai');
const kv = Object.fromEntries(fs.readFileSync(process.argv[2], 'utf8').split('\n')
  .filter((l) => l.includes('=')).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]));
const n = parseInt(kv.POSTS_FOUND, 10);
const posts = [];
for (let i = 1; i <= n; i++) {
  posts.push({ key: kv[`POST_${i}_KEY`], url: kv[`POST_${i}_URL`], author: kv[`POST_${i}_AUTHOR`] });
}
const ctx = await chromium.launchPersistentContext(USER_DATA_DIR, {
  channel: 'chrome', headless: false, viewport: { width: 1440, height: 1000 }, timeout: 30000,
});
const page = ctx.pages()[0] || await ctx.newPage();
let bad = 0;
for (const p of posts) {
  if (!p.url || p.url === '-') { console.log(`NOLINK  ${p.key}`); bad++; continue; }
  try {
    await page.goto(p.url, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.waitForTimeout(2500);
    const text = await page.evaluate(() => (document.querySelector('main') || document.body).innerText.slice(0, 800));
    const gone = /cannot be displayed|couldn.t be loaded|isn.t available|not available|deleted|removed|Something went wrong/i.test(text);
    const authorOk = text.toLowerCase().includes(p.author.replace(/[^\p{L}\p{N} ]/gu, '').trim().split(/\s+/)[0].toLowerCase());
    if (gone) { console.log(`BROKEN  ${p.key} -> ${p.url}`); bad++; }
    // A rendering page without the author is the WRONG post — that is
    // permalink drift too, not a pass (it printed OK until 2026-07-24).
    else if (!authorOk) { console.log(`NOAUTHOR ${p.key} -> ${p.url.slice(0, 100)}`); bad++; }
    else console.log(`OK      ${p.key} -> ${p.url.slice(0, 100)}`);
  } catch (e) {
    console.log(`ERROR   ${p.key}: ${String(e.message).split('\n')[0]}`); bad++;
  }
  await page.waitForTimeout(700);
}
await ctx.close();
console.log(bad === 0 ? 'ALL LINKS OK' : `${bad} BAD LINKS`);
process.exit(bad === 0 ? 0 : 1);
