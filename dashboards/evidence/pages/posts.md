---
title: LinkedIn Stats — Per-post
---

[← Account view](/)

## Pick a post

```sql post_options
select
  id,
  posted_date || ' — ' || coalesce(substr(preview, 1, 80), id) as label,
  preview,
  type,
  post_url,
  posted_date
from li_stats.posts
order by posted_date desc
```

<Dropdown name=post_id data={post_options} value=id label=label defaultValue={post_options[0]?.id} />

```sql post_meta
select posted_date, type, preview, post_url
from li_stats.posts
where id = '${inputs.post_id.value}'
```

<DataTable data={post_meta} rows=1>
  <Column id=posted_date title="Posted" />
  <Column id=type title="Type" />
  <Column id=preview title="Preview" wrap=true />
  <Column id=post_url title="URL" contentType=link linkLabel="open ↗" />
</DataTable>

## Weekly metrics

```sql post_metrics
select
  week,
  impressions,
  members_reached,
  reactions,
  comments,
  reposts,
  saves,
  sends,
  profile_viewers,
  followers_gained,
  engagement_rate
from li_stats.post_weeks
where id = '${inputs.post_id.value}'
order by week
```

<LineChart data={post_metrics} x=week y=impressions title="Impressions" />

<LineChart data={post_metrics} x=week y={["reactions", "comments", "reposts", "saves", "sends"]} title="Engagement actions" />

<LineChart data={post_metrics} x=week y=engagement_rate title="Engagement rate (%)" />

<LineChart data={post_metrics} x=week y={["profile_viewers", "followers_gained"]} title="Profile viewers & followers gained" />

<DataTable data={post_metrics} rows=10>
  <Column id=week title="Week" />
  <Column id=impressions title="Impr." align=right />
  <Column id=reactions title="React." align=right />
  <Column id=comments title="Comm." align=right />
  <Column id=reposts title="Reposts" align=right />
  <Column id=engagement_rate title="Eng. %" align=right />
</DataTable>

## Audience demographics (latest week for this post)

```sql post_latest_week
select max(week) as week
from li_stats.post_demographics
where id = '${inputs.post_id.value}'
```

```sql demo_seniority
select label, pct
from li_stats.post_demographics
where id = '${inputs.post_id.value}'
  and dimension = 'seniority'
  and week = (select week from ${post_latest_week})
order by pct desc
```

<BarChart data={demo_seniority} x=label y=pct title="Seniority" swapXY=true sort=true />

```sql demo_job
select label, pct
from li_stats.post_demographics
where id = '${inputs.post_id.value}'
  and dimension = 'job_title'
  and week = (select week from ${post_latest_week})
order by pct desc
limit 10
```

<BarChart data={demo_job} x=label y=pct title="Top job titles" swapXY=true sort=true />

```sql demo_industry
select label, pct
from li_stats.post_demographics
where id = '${inputs.post_id.value}'
  and dimension = 'industry'
  and week = (select week from ${post_latest_week})
order by pct desc
limit 10
```

<BarChart data={demo_industry} x=label y=pct title="Top industries" swapXY=true sort=true />

```sql demo_company_size
select label, pct
from li_stats.post_demographics
where id = '${inputs.post_id.value}'
  and dimension = 'company_size'
  and week = (select week from ${post_latest_week})
order by pct desc
```

<BarChart data={demo_company_size} x=label y=pct title="Company size" swapXY=true sort=true />

```sql demo_location
select label, pct
from li_stats.post_demographics
where id = '${inputs.post_id.value}'
  and dimension = 'location'
  and week = (select week from ${post_latest_week})
order by pct desc
limit 10
```

<BarChart data={demo_location} x=label y=pct title="Top locations" swapXY=true sort=true />

```sql demo_company
select label, pct
from li_stats.post_demographics
where id = '${inputs.post_id.value}'
  and dimension = 'company'
  and week = (select week from ${post_latest_week})
order by pct desc
limit 10
```

<BarChart data={demo_company} x=label y=pct title="Top companies" swapXY=true sort=true />
