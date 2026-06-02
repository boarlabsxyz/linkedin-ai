---
title: LinkedIn Stats — Account
---

# LinkedIn Stats — Account

[Per-post detail →](./posts)

```js
const stats = await FileAttachment("data/stats.json").json();
const { posts, account_weeks, account_demographics } = stats;
const sortedAcct = account_weeks.slice().sort((a, b) => a.week.localeCompare(b.week));
const latestAcct = sortedAcct.at(-1);
const latestAcctWeek = latestAcct?.week ?? null;
```

## Account snapshot (latest week — ${latestAcctWeek ?? "—"})

<div class="grid grid-cols-4">
  <div class="card"><h2>Followers</h2><span class="big">${latestAcct?.followers?.toLocaleString() ?? "—"}</span></div>
  <div class="card"><h2>Post impressions (7d)</h2><span class="big">${latestAcct?.post_impressions_7d?.toLocaleString() ?? "—"}</span></div>
  <div class="card"><h2>Profile viewers (90d)</h2><span class="big">${latestAcct?.profile_viewers_90d?.toLocaleString() ?? "—"}</span></div>
  <div class="card"><h2>Search appearances (prev week)</h2><span class="big">${latestAcct?.search_appearances_previous_week?.toLocaleString() ?? "—"}</span></div>
</div>

## Trends over time

```js
function trendChart(field, label) {
  return Plot.plot({
    height: 220,
    marginLeft: 60,
    y: { label, grid: true },
    x: { label: null, type: "point" },
    marks: [
      Plot.lineY(sortedAcct, { x: "week", y: field, stroke: "var(--theme-foreground-focus)" }),
      Plot.dot(sortedAcct, { x: "week", y: field, fill: "var(--theme-foreground-focus)" }),
      Plot.ruleY([0])
    ]
  });
}
```

<div class="grid grid-cols-2">
  <div class="card"><h2>Followers</h2>${trendChart("followers", "Followers")}</div>
  <div class="card"><h2>Post impressions (7d)</h2>${trendChart("post_impressions_7d", "Impressions")}</div>
  <div class="card"><h2>Profile viewers (90d)</h2>${trendChart("profile_viewers_90d", "Viewers")}</div>
  <div class="card"><h2>Search appearances (prev week)</h2>${trendChart("search_appearances_previous_week", "Appearances")}</div>
</div>

## Audience demographics (latest week)

```js
function demoBar(dimension, opts = {}) {
  const rows = account_demographics
    .filter(r => r.dimension === dimension && r.week === latestAcctWeek)
    .sort((a, b) => b.pct - a.pct)
    .slice(0, opts.limit ?? 999);
  return Plot.plot({
    marginLeft: opts.marginLeft ?? 180,
    height: opts.height ?? (rows.length * 24 + 60),
    x: { label: "%", grid: true },
    y: { label: null },
    marks: [
      Plot.barX(rows, { x: "pct", y: "label", sort: { y: "x", reverse: true }, fill: "var(--theme-foreground-focus)" }),
      Plot.text(rows, { x: "pct", y: "label", text: d => `${d.pct}%`, dx: 6, textAnchor: "start" })
    ]
  });
}
```

<div class="grid grid-cols-1">
  <div class="card"><h2>Seniority</h2>${demoBar("seniority", {marginLeft: 140})}</div>
  <div class="card"><h2>Top job titles</h2>${demoBar("job_title", {limit: 10, marginLeft: 220})}</div>
  <div class="card"><h2>Top locations</h2>${demoBar("location", {limit: 10, marginLeft: 220})}</div>
</div>

## Posts published per month

```js
const perMonth = (() => {
  const m = new Map();
  for (const p of posts) {
    const month = (p.posted_date || "").slice(0, 7);
    if (!month) continue;
    const cur = m.get(month) ?? { month, posts: 0, reposts: 0 };
    cur.posts += 1;
    if (p.type === "repost") cur.reposts += 1;
    m.set(month, cur);
  }
  return [...m.values()].sort((a, b) => a.month.localeCompare(b.month));
})();
```

```js
Plot.plot({
  height: 280,
  marks: [
    Plot.barY(perMonth, { x: "month", y: "posts", fill: "var(--theme-foreground-focus)" }),
    Plot.barY(perMonth, { x: "month", y: "reposts", fill: "var(--theme-foreground-faintest)" }),
    Plot.ruleY([0])
  ]
})
```
