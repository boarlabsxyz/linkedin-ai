#!/usr/bin/env node
// Flattens dashboards/li-stats/{account.json, posts/*.json} into a single
// payload {posts, post_weeks, post_demographics, account_weeks, account_demographics}.
// Mirrors dashboards/observable/src/data/stats.json.ts so Observable and the
// Grafana Infinity feed share the same shape.

import { readFileSync, readdirSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "..", "..");
const LI_STATS = join(REPO_ROOT, "dashboards", "li-stats");
const POSTS_DIR = join(LI_STATS, "posts");
const ACCOUNT_FILE = join(LI_STATS, "account.json");

const METRIC_KEYS = [
  "impressions", "members_reached", "reactions", "comments",
  "reposts", "saves", "sends", "profile_viewers",
  "followers_gained", "engagement_rate",
];

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--out" && argv[i + 1]) { out.out = argv[++i]; }
  }
  return out;
}

const args = parseArgs(process.argv.slice(2));
if (!args.out) {
  console.error("usage: build-stats-json.mjs --out <path>");
  process.exit(2);
}

const posts = [];
const post_weeks = [];
const post_demographics = [];
const account_weeks = [];
const account_demographics = [];

for (const fname of readdirSync(POSTS_DIR).filter(f => f.endsWith(".json")).sort()) {
  const d = JSON.parse(readFileSync(join(POSTS_DIR, fname), "utf8"));
  posts.push({
    id: d.id,
    posted_date: d.posted_date ?? "",
    type: d.type ?? "post",
    preview: (d.preview ?? "").slice(0, 120),
    post_url: d.post_url ?? "",
  });
  for (const [week, snap] of Object.entries(d.weeks ?? {})) {
    const m = snap.metrics ?? {};
    const row = { id: d.id, week };
    for (const k of METRIC_KEYS) row[k] = m[k] ?? 0;
    post_weeks.push(row);
    for (const [dim, labels] of Object.entries(snap.demographics ?? {})) {
      for (const [label, pct] of Object.entries(labels ?? {})) {
        post_demographics.push({ id: d.id, week, dimension: dim, label, pct: Number(pct) });
      }
    }
  }
}

try {
  const acct = JSON.parse(readFileSync(ACCOUNT_FILE, "utf8"));
  for (const [week, snap] of Object.entries(acct.weeks ?? {})) {
    const dash = snap.dashboard ?? {};
    const aud = snap.audience ?? {};
    account_weeks.push({
      week,
      followers: dash.followers ?? 0,
      post_impressions_7d: dash.post_impressions_7d ?? 0,
      profile_viewers_90d: dash.profile_viewers_90d ?? 0,
      search_appearances_previous_week: dash.search_appearances_previous_week ?? 0,
      followers_delta_pct_7d: aud.followers_delta_pct_7d ?? 0,
    });
    for (const [dim, labels] of Object.entries(aud.demographics ?? {})) {
      for (const [label, pct] of Object.entries(labels ?? {})) {
        account_demographics.push({ week, dimension: dim, label, pct: Number(pct) });
      }
    }
  }
} catch { /* account.json optional */ }

const payload = { posts, post_weeks, post_demographics, account_weeks, account_demographics };

mkdirSync(dirname(resolve(args.out)), { recursive: true });
writeFileSync(args.out, JSON.stringify(payload));

console.error(`wrote ${args.out} — posts=${posts.length} post_weeks=${post_weeks.length} post_demographics=${post_demographics.length} account_weeks=${account_weeks.length} account_demographics=${account_demographics.length}`);
