---
title: LinkedIn Stats — Per-post
---

# LinkedIn Stats — Per-post

[← Account view](./)

```js
const stats = await FileAttachment("data/stats.json").json();
const { posts, post_weeks, post_demographics } = stats;
const sortedPosts = posts.slice().sort((a, b) => (b.posted_date || "").localeCompare(a.posted_date || ""));
```

## Pick a post

```js
const selectedPost = view(Inputs.select(sortedPosts, {
  label: "Post",
  format: p => `${p.posted_date || "—"} — ${(p.preview || p.id).slice(0, 80)}`,
  value: sortedPosts[0]
}));
```

```js
const postId = selectedPost?.id;
const myWeeks = post_weeks
  .filter(r => r.id === postId)
  .slice()
  .sort((a, b) => a.week.localeCompare(b.week));
const latestWeek = myWeeks.at(-1)?.week ?? null;
const myDemos = post_demographics.filter(r => r.id === postId && r.week === latestWeek);
```

<div class="card">
  <h2>${selectedPost?.posted_date ?? "—"} — ${selectedPost?.type ?? ""}</h2>
  <p>${selectedPost?.preview ?? ""}</p>
  <p>${selectedPost?.post_url ? `<a href="${selectedPost.post_url}" target="_blank">Open on LinkedIn ↗</a>` : ""}</p>
</div>

## Weekly metrics

```js
function metricChart(fields, label) {
  const fs = Array.isArray(fields) ? fields : [fields];
  const long = myWeeks.flatMap(row => fs.map(f => ({ week: row.week, metric: f, value: row[f] ?? 0 })));
  return Plot.plot({
    height: 220,
    marginLeft: 60,
    y: { label, grid: true },
    x: { label: null, type: "point" },
    color: { legend: fs.length > 1 },
    marks: [
      Plot.lineY(long, { x: "week", y: "value", stroke: "metric" }),
      Plot.dot(long, { x: "week", y: "value", fill: "metric" }),
      Plot.ruleY([0])
    ]
  });
}
```

<div class="grid grid-cols-1">
  <div class="card"><h2>Impressions</h2>${metricChart("impressions", "Impressions")}</div>
  <div class="card"><h2>Engagement actions</h2>${metricChart(["reactions","comments","reposts","saves","sends"], "Count")}</div>
  <div class="card"><h2>Engagement rate</h2>${metricChart("engagement_rate", "%")}</div>
  <div class="card"><h2>Profile viewers & followers gained</h2>${metricChart(["profile_viewers","followers_gained"], "Count")}</div>
</div>

${Inputs.table(myWeeks, {
  columns: ["week", "impressions", "reactions", "comments", "reposts", "saves", "sends", "profile_viewers", "followers_gained", "engagement_rate"],
  header: { week: "Week", impressions: "Impr.", reactions: "React.", comments: "Comm.", reposts: "Reposts", saves: "Saves", sends: "Sends", profile_viewers: "Profile views", followers_gained: "Fol. gained", engagement_rate: "Eng. %" }
})}

## Audience demographics (latest week for this post — ${latestWeek ?? "—"})

```js
function demoBar(dimension, opts = {}) {
  const rows = myDemos
    .filter(r => r.dimension === dimension)
    .slice()
    .sort((a, b) => b.pct - a.pct)
    .slice(0, opts.limit ?? 999);
  if (!rows.length) return html`<em>No data</em>`;
  return Plot.plot({
    marginLeft: opts.marginLeft ?? 200,
    height: opts.height ?? (rows.length * 22 + 60),
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
  <div class="card"><h2>Top job titles</h2>${demoBar("job_title", {limit: 10, marginLeft: 240})}</div>
  <div class="card"><h2>Top industries</h2>${demoBar("industry", {limit: 10, marginLeft: 260})}</div>
  <div class="card"><h2>Company size</h2>${demoBar("company_size", {marginLeft: 180})}</div>
  <div class="card"><h2>Top locations</h2>${demoBar("location", {limit: 10, marginLeft: 240})}</div>
  <div class="card"><h2>Top companies</h2>${demoBar("company", {limit: 10, marginLeft: 240})}</div>
</div>
