---
title: LinkedIn Stats — Account
---

[Per-post detail →](/posts)

## Account snapshot (latest week)

```sql account_latest
select *
from li_stats.account_weeks
order by week desc
limit 1
```

<BigValue data={account_latest} value=followers title="Followers" />
<BigValue data={account_latest} value=post_impressions_7d title="Post impressions (7d)" />
<BigValue data={account_latest} value=profile_viewers_90d title="Profile viewers (90d)" />
<BigValue data={account_latest} value=search_appearances_previous_week title="Search appearances (prev week)" />

## Trends over time

```sql account_trend
select
  week,
  followers,
  post_impressions_7d,
  profile_viewers_90d,
  search_appearances_previous_week,
  followers_delta_pct_7d
from li_stats.account_weeks
order by week
```

<LineChart data={account_trend} x=week y=followers title="Followers" />

<LineChart data={account_trend} x=week y=post_impressions_7d title="Post impressions (7d)" />

<LineChart data={account_trend} x=week y=profile_viewers_90d title="Profile viewers (90d)" />

<LineChart data={account_trend} x=week y=search_appearances_previous_week title="Search appearances (prev week)" />

## Audience demographics (latest week)

```sql latest_acct_week
select max(week) as week from li_stats.account_demographics
```

```sql aud_seniority
select label, pct
from li_stats.account_demographics
where dimension = 'seniority'
  and week = (select week from ${latest_acct_week})
order by pct desc
```

<BarChart data={aud_seniority} x=label y=pct title="Seniority" swapXY=true sort=true />

```sql aud_job
select label, pct
from li_stats.account_demographics
where dimension = 'job_title'
  and week = (select week from ${latest_acct_week})
order by pct desc
limit 10
```

<BarChart data={aud_job} x=label y=pct title="Top job titles" swapXY=true sort=true />

```sql aud_location
select label, pct
from li_stats.account_demographics
where dimension = 'location'
  and week = (select week from ${latest_acct_week})
order by pct desc
limit 10
```

<BarChart data={aud_location} x=label y=pct title="Top locations" swapXY=true sort=true />

## Posts published per month

```sql posts_per_month
select
  substr(posted_date, 1, 7) as month,
  count(*)::int as posts,
  sum(case when type = 'repost' then 1 else 0 end)::int as reposts
from li_stats.posts
group by month
order by month
```

<BarChart data={posts_per_month} x=month y={["posts", "reposts"]} type=grouped />
