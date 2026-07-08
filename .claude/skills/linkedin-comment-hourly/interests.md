# Interest categories for the LinkedIn feed filter

Agent 1 (`linkedin-comment-hourly-gather-feed`) classifies each scraped post against these categories. A post is **relevant** if it touches ANY of them directly or is clearly adjacent (bias toward inclusion). Tune this file to widen or narrow the filter; no code change needed.

## Categories

- **AI / LLMs / AI Agents / AI Engineering** — foundation models, agent frameworks, RAG, evals, tool use, coding agents, prompt engineering, dev tooling for LLM apps, model releases, AI research, AI safety, AI product launches.
- **Startups / Entrepreneurship / Fundraising / Growth** — company-building, B2B SaaS growth, GTM, sales, fundraising, hiring, technical org design (especially adjacent to AI teams), founder essays, VC commentary.

## Adjacency examples (still mark relevant)

- Dev tooling for AI apps (e.g., Cursor, Claude Code, coding agents in general).
- Technical hiring for AI teams or startups.
- Product-management commentary from AI-native companies.
- Metrics / instrumentation posts about LLM workloads.
- Founder-mode posts, PMF stories, revenue growth stories at software startups.

## Off-topic examples (skip and write `<slug>.off-topic.json`)

- Politics, sports, celebrity news.
- Generic motivational / gratitude / life-lesson posts with no AI or startup content.
- Personal life events (weddings, births) unless AI/startup context makes them relevant.
- Non-tech industry news (real estate, hospitality, retail — unless AI/startup adjacent).
- LinkedIn platform meta-posts ("just hit 10k followers, here's what I learned") unless the substance is AI or startup lessons.
