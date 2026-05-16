---
title: LinkedIn Stats
---

# LinkedIn Stats

```js
const stats = await FileAttachment("data/stats.json").json();
const { posts, post_weeks, post_demographics, account_weeks } = stats;
const latestAcctWeek = account_weeks.length ? account_weeks.slice().sort((a, b) => b.week.localeCompare(a.week))[0] : null;
const latestPostWeek = post_weeks.length ? post_weeks.map(r => r.week).sort().at(-1) : null;
const previewById = new Map(posts.map(p => [p.id, p.preview]));
const datedById = new Map(posts.map(p => [p.id, p.posted_date]));
```

## Account snapshot (latest week — ${latestAcctWeek?.week ?? "—"})

<div class="grid grid-cols-4">
  <div class="card"><h2>Followers</h2><span class="big">${latestAcctWeek?.followers?.toLocaleString() ?? "—"}</span></div>
  <div class="card"><h2>Post impressions (7d)</h2><span class="big">${latestAcctWeek?.post_impressions_7d?.toLocaleString() ?? "—"}</span></div>
  <div class="card"><h2>Profile viewers (90d)</h2><span class="big">${latestAcctWeek?.profile_viewers_90d?.toLocaleString() ?? "—"}</span></div>
  <div class="card"><h2>Search appearances (prev week)</h2><span class="big">${latestAcctWeek?.search_appearances_previous_week?.toLocaleString() ?? "—"}</span></div>
</div>

## Top 10 posts by impressions (latest week — ${latestPostWeek ?? "—"})

```js
const top = post_weeks
  .filter(r => r.week === latestPostWeek)
  .sort((a, b) => b.impressions - a.impressions)
  .slice(0, 10)
  .map(r => ({ ...r, preview: previewById.get(r.id) ?? r.id, posted_date: datedById.get(r.id) ?? "" }));
```

```js
Plot.plot({
  marginLeft: 320,
  height: 360,
  x: { label: "Impressions" },
  y: { label: null },
  marks: [
    Plot.barX(top, { x: "impressions", y: "preview", sort: { y: "x", reverse: true }, fill: "var(--theme-foreground-focus)" }),
    Plot.text(top, { x: "impressions", y: "preview", text: d => d.impressions.toLocaleString(), dx: 6, textAnchor: "start" })
  ]
})
```

${Inputs.table(top, {
  columns: ["posted_date", "preview", "impressions", "reactions", "engagement_rate"],
  header: { posted_date: "Posted", preview: "Preview", impressions: "Impr.", reactions: "React.", engagement_rate: "Engagement %" },
  width: { preview: 480 }
})}

## Seniority breakdown (latest week, averaged across posts)

```js
const seniorityRows = (() => {
  const byLabel = new Map();
  for (const row of post_demographics.filter(r => r.dimension === "seniority" && r.week === latestPostWeek)) {
    const cur = byLabel.get(row.label) ?? { label: row.label, total: 0, n: 0 };
    cur.total += row.pct;
    cur.n += 1;
    byLabel.set(row.label, cur);
  }
  return [...byLabel.values()]
    .map(({ label, total, n }) => ({ label, avg_pct: +(total / n).toFixed(1) }))
    .sort((a, b) => b.avg_pct - a.avg_pct);
})();
```

```js
Plot.plot({
  marginLeft: 140,
  height: 280,
  x: { label: "% of impressions" },
  y: { label: null },
  marks: [
    Plot.barX(seniorityRows, { x: "avg_pct", y: "label", sort: { y: "x", reverse: true }, fill: "var(--theme-foreground-focus)" }),
    Plot.text(seniorityRows, { x: "avg_pct", y: "label", text: d => `${d.avg_pct}%`, dx: 6, textAnchor: "start" })
  ]
})
```

## Posts published per month

```js
const perMonth = (() => {
  const m = new Map();
  for (const p of posts) {
    const month = p.posted_date.slice(0, 7);
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
