// Observable Framework data loader: reads ../../../li-stats/{posts,account}.json,
// flattens to {posts, post_weeks, post_demographics, account_weeks} and emits to stdout.
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const LI_STATS = resolve(HERE, "..", "..", "..", "li-stats");
const POSTS_DIR = join(LI_STATS, "posts");
const ACCOUNT_FILE = join(LI_STATS, "account.json");

const METRIC_KEYS = [
  "impressions", "members_reached", "reactions", "comments",
  "reposts", "saves", "sends", "profile_viewers",
  "followers_gained", "engagement_rate",
];

type PostMeta = { id: string; posted_date: string; type: string; preview: string; post_url: string };
type PostWeek = { id: string; week: string } & Record<string, number>;
type Demo = { id: string; week: string; dimension: string; label: string; pct: number };
type AccountWeek = { week: string; followers: number; post_impressions_7d: number; profile_viewers_90d: number; search_appearances_previous_week: number };

const posts: PostMeta[] = [];
const post_weeks: PostWeek[] = [];
const post_demographics: Demo[] = [];
const account_weeks: AccountWeek[] = [];

for (const fname of readdirSync(POSTS_DIR).filter(f => f.endsWith(".json")).sort()) {
  const d = JSON.parse(readFileSync(join(POSTS_DIR, fname), "utf8"));
  posts.push({
    id: d.id,
    posted_date: d.posted_date ?? "",
    type: d.type ?? "post",
    preview: (d.preview ?? "").slice(0, 120),
    post_url: d.post_url ?? "",
  });
  for (const [week, snap] of Object.entries((d.weeks ?? {}) as Record<string, any>)) {
    const m = snap.metrics ?? {};
    const row: PostWeek = { id: d.id, week } as PostWeek;
    for (const k of METRIC_KEYS) (row as any)[k] = m[k] ?? 0;
    post_weeks.push(row);
    for (const [dim, labels] of Object.entries((snap.demographics ?? {}) as Record<string, Record<string, number>>)) {
      for (const [label, pct] of Object.entries(labels ?? {})) {
        post_demographics.push({ id: d.id, week, dimension: dim, label, pct: Number(pct) });
      }
    }
  }
}

try {
  const acct = JSON.parse(readFileSync(ACCOUNT_FILE, "utf8"));
  for (const [week, snap] of Object.entries((acct.weeks ?? {}) as Record<string, any>)) {
    const dash = snap.dashboard ?? {};
    account_weeks.push({
      week,
      followers: dash.followers ?? 0,
      post_impressions_7d: dash.post_impressions_7d ?? 0,
      profile_viewers_90d: dash.profile_viewers_90d ?? 0,
      search_appearances_previous_week: dash.search_appearances_previous_week ?? 0,
    });
  }
} catch { /* account.json optional */ }

process.stdout.write(JSON.stringify({ posts, post_weeks, post_demographics, account_weeks }));
