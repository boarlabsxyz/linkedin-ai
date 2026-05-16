---
title: LinkedIn Stats
---

## Account snapshot (latest week)

```sql account
select
  week,
  followers,
  post_impressions_7d,
  profile_viewers_90d,
  search_appearances_previous_week
from li_stats.account_weeks
order by week desc
limit 1
```

<BigValue data={account} value=followers title="Followers" />
<BigValue data={account} value=post_impressions_7d title="Post impressions (7d)" />
<BigValue data={account} value=profile_viewers_90d title="Profile viewers (90d)" />
<BigValue data={account} value=search_appearances_previous_week title="Search appearances (prev week)" />

## Top 10 posts by impressions (latest week)

```sql top_posts
select
  p.posted_date,
  p.preview,
  w.impressions,
  w.reactions,
  w.engagement_rate
from li_stats.post_weeks w
join li_stats.posts p on p.id = w.id
where w.week = (select max(week) from li_stats.post_weeks)
order by w.impressions desc
limit 10
```

<BarChart data={top_posts} x=preview y=impressions sort=true swapXY=true />

<DataTable data={top_posts} rows=10>
  <Column id=posted_date title="Posted" />
  <Column id=preview title="Preview" wrap=true />
  <Column id=impressions title="Impr." align=right />
  <Column id=reactions title="React." align=right />
  <Column id=engagement_rate title="Engagement %" align=right />
</DataTable>

## Seniority breakdown (latest week, averaged across posts)

```sql seniority
select
  label,
  round(avg(pct), 1) as avg_pct
from li_stats.post_demographics
where dimension = 'seniority'
  and week = (select max(week) from li_stats.post_demographics)
group by label
order by avg_pct desc
```

<BarChart data={seniority} x=label y=avg_pct sort=true />

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
