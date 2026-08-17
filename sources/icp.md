## 1\. TA — OS AI founders & staff engineers [v2.3.md](http://v2.3.md)

# Profile of Peter Ovchyn's priority TA: founders and staff engineers of AI-coding Open Source
**Working document for Boarlabz | Version 2.3 | Updated 28 April 2026 | Internal use**
This document describes the **priority target audience** of Peter, agreed at the meeting of 24 April 2026 — **founders and staff engineers of AI-coding Open Source projects**. Direct quote from Peter at 27:09 of the transcript: _"first of all, founders or some kind of staff engineers are interesting, the ones who determine where the product is heading."_ Goal of the interaction: **to find 1–2 people who will get interested in Peter's True BDD idea and will help develop and popularize it**.
**About Peter's product — True BDD** (recorded from the discussion with Peter):
*   **Name:** True BDD, where BDD = Behavior-Driven Development.
*   **Essence:** to move the source of truth from the code to the documentation — so that AI can fully restore the code and the project having access exclusively to the documentation. Peter's direct words: _"so that the code can be deleted along the way"_.
*   **Type/format:** a tool (tool / console utility). Peter explicitly excluded the options "platform", "service", "framework". He allows that over time this may grow into a platform, but for now the format is a small utility that the user downloads for themselves.
*   **Stage:** prototype — it already performs real actions, that is, more than a concept, but not yet production-ready.

The document deliberately describes **only** this audience. The Series B segment (CTO/CIO/VP Engineering at scaleups) is a separate TA with its own document and its own strategy; we are not talking about it here.

Source marking: **\[Internal: Peter/project\]** — statements from transcripts and Boarlabz project knowledge; **\[External research\]** — public sources 2025-2026.

* * *

## 1\. Profile of the priority segment
**\[Internal: Peter/project\]** Peter describes this segment through two main attributes and one auxiliary one:
**Main attributes:**
1. **Type of project** in which this person works — what Peter described with the words _"maintainers of exactly this crap"_ (24 April 2026, 24:57): AI-coding tools, frameworks, infrastructure Open Source projects. This includes coding agents, IDE extensions, CLI tools, spec-driven development frameworks and adjacent infrastructure projects.
2. **Role** — **founder** (founder of the project with technical leadership) **or staff engineer** (senior IC who holds the technical axis of the product). Not an ordinary contributor. In Peter's words — _"the ones who determine where the product is heading"_ (24 April 2026, 27:09). These are people who make product and architectural decisions: technical lead, CTO-founder, or solo maintainer of a mainstream project. Terminology clarification: **staff engineer** is an established industry role (senior IC track, the next step after Senior Engineer; the canonical reference is Will Larson, _"Staff Engineer: Leadership beyond the management track"_, 2021). Larson distinguishes four archetypes of staff engineer: Tech Lead, Architect, Solver, Right Hand. Peter's description is closest to Tech Lead and Architect — that is, people who precisely _set the direction_, rather than execute ready-made decisions.

**Auxiliary attribute — an exception for developers:**

3. **Publicity of the developer as an exception to the rule.** Ordinary developers from AI-coding OSS projects **generally do not enter the TA** (Peter said directly that "just developers are not very interesting anymore"). But there is an exception: **if the developer is public** — speaks, hosts a podcast, publishes articles, noticeably represents the project publicly — they _may_ get into the TA. The logic: publicity indicates readiness for peer exchange and makes outreach meaningful. Publicity is not applied as a criterion to founders and staff engineers — for them it is an optional bonus, not an entry filter.

**\[Internal: Peter/project\]** Whom Peter deliberately excludes from the priority TA:

*   Pure researchers — "interesting to listen to, but they do not compete in the product field; they publish a scientific paper, there is nothing to argue about with them".
*   Consultants and agencies — Peter's experience shows that in practice there is little use from them.
*   Ordinary developers — "just developers are not very interesting anymore" (with the exception for public developers, see attribute #3 below).
*   Juniors and people without their own engineering background.

**\[Internal: Peter/project\]** Geography for this segment is **not limited**. This is a fundamental difference from previous iterations of the TA — at this stage Peter is looking for the best 1–2 people, wherever they are based. This decision makes the pool potentially global and allows including people from the Bay Area, Europe, Asia by the same criterion of relevance.

**\[Internal: Peter/project\]** The funding stage of the project in which the potential partner works is **also not a criterion**. Peter is equally interested in a solo OSS maintainer without venture money, and in a founder or staff engineer of a project with $30M+ Series A. What counts is the level of technical influence and competing in the real product field.

**\[External research: AI Engineer / swyx 2025-2026\]** In the market this type of person has acquired its own identity — "AI Engineer". The term, introduced in the essay by swyx (Latent Space) "The Rise of the AI Engineer", means an engineer who builds products on ready-made foundation models rather than trains their own. The AI Engineer Summit team officially distinguishes three personas: generalist software engineer onboarding into AI; AI engineer who has already shipped to production; VP of AI / engineering leadership. Peter's TA profile most precisely corresponds to the **second persona** for the staff-engineer part, and to the **third persona** for founders who are at the same time the technical core of an OSS project. In all cases — within the boundaries of OSS projects, where this person holds the technical axis rather than just doing product engineering.

**\[External research: Latent Space,** [**ai.engineer**](http://ai.engineer)**, GitHub\]** Where this community professionally lives:

*   **X (Twitter)** — the main venue. Nodes: @karpathy, @swyx, @simonw, @amanrsanger (Cursor), @leerob, @paulgauthier (Aider), @thdxr (Dax Raad / OpenCode), @Danenania (Plandex). The community reads each other, quotes, "quote-dunks" on each other.
*   **GitHub** — repositories as a venue for technical discussion (issues, discussions). OSSF wg-vulnerability-disclosures Issue #178 (AI-SLOP best practices) — an example of public coordination of maintainers.
*   **Discord** — Cursor Discord (~35,500 participants), Cline Discord, Aider Discord, **Latent Space Discord** with Paper Club, AI Engineer Foundation. Here everyday technical conversation happens without marketing.
*   **Reddit** — r/LocalLLaMA (~694k members), r/cursor, r/ClaudeAI.
*   **Hacker News** — serious threads, read by PMs of Anthropic / OpenAI / Cursor.
*   **Newsletters**: Latent Space (swyx + Alessio Fanelli), AINews, The Pragmatic Engineer (Gergely Orosz), Drew Breunig blog.
*   **Podcasts**: Latent Space, Cognitive Revolution (Nathan Labenz), MLOps Community, Tech Lead Journal, No Priors.
*   **Conferences**: AI Engineer Summit (NYC), AI Engineer World's Fair (SF, ~3,000 participants), AI Engineer Code Summit (NYC), AI Engineer Europe (London, April 2026, 1,000+ participants). For 2026 swyx plans no fewer than 7 AIE events around the world.

**\[External research + Internal: observation\]** How this community makes decisions about joining a new idea or project: decisions are driven by **trust signals**, not by marketing communication. What works: a working artifact (repo, demo, X thread with an architectural explanation), specific data instead of general statements, endorsement from one of the trust nodes (retweet from Karpathy, podcast invite from swyx, blogroll from simonw), personal participation in IRL events, brutal honesty about tradeoffs. What does not work: cold DMs (on swyx's about page it is written directly "we do not accept cold emails"), AI-generated posts, language like "revolutionary" or "game-changing", performative vibe-coding theatre.

* * *

## 2\. The context in which they work
**\[External research: GitHub State of AI Coding 2025; ArtificialAnalysis\]** The state of the market 2025-2026 — hyper-invested, hyper-competitive, with sharp stratification. 84% of developers use or plan to use AI-coding tools. Y Combinator reported in March 2025 that 25% of W25 startups had codebases that were 95% AI-generated. Categories of tools: IDE extensions (Copilot, Cline, Continue, Roo Code, Kilo Code, Amp, Augment), dedicated IDEs (Cursor, Windsurf, Zed, Kiro, Antigravity), CLI tools (Claude Code, Aider, Codex, Goose, opencode), cloud platforms (Devin, OpenHands, Jules, Manus).
**\[External research: TechCrunch, Sacra, Anthropic\]** Economic realities — capital is extremely concentrated at the top. Cursor (Anysphere): Series D on 13 November 2025 — $2.3B at $29.3B post-money; ARR crossed $1B at the end of 2025; negotiations are under way about $50–60B. Anthropic: Series G on 12 February 2026 — $30B at **$380B post-money**, $14B ARR; **Claude Code reached a $2.5B run-rate by February 2026**. Cognition: $10.2B valuation in September 2025, negotiations are under way about $25B in April 2026. At the other end of the spectrum — solo OSS projects like Aider or BMAD without venture money; the rounds of Cline ($32M) and Continue ($5.1M); and new players like Kilo Code ($8M seed with a GitLab co-founder on board).
**\[External research: Sacra;** [**agentsindex.ai**](http://agentsindex.ai)**\]** Patterns of OSS monetization in this niche:
*   BYOK + free OSS + paid enterprise (Cline, Continue, Roo Code, Kilo Code) — the cleanest model.
*   Hosted open-core (Continue Hub, Tessl Spec Registry).
*   Sponsorships only for solo-maintainer projects (Aider, BMAD).
*   Enterprise tiers with SSO/SAML/audit/private deployment.
*   Foundation-model-bundled (Copilot Enterprise, Kiro Pro+, Claude Code Max).

Dual licensing is almost not used in this niche — predominantly MIT or Apache 2.0.

**\[External research:** [**github.blog**](http://github.blog)**,** [**kiro.dev**](http://kiro.dev)**,** [**tessl.io**](http://tessl.io)**,** [**agent-wars.com**](http://agent-wars.com)**\]** The technological landscape — **spec-driven development was legitimized as a category in 2025-2026**. Reference events:

*   **Amazon Kiro** — public preview in July 2025; the first AI-coding tool built precisely around a spec-driven workflow with three documents ([`requirements.md`](http://requirements.md), [`design.md`](http://design.md), [`tasks.md`](http://tasks.md)). By GA — 250,000+ developers.
*   **GitHub Spec Kit** (September 2025) — MIT toolkit with the commands `/specify` → `/plan` → `/tasks` → `/speckit.implement`. Up to v0.7+ at the beginning of 2026 with 30+ AI-agent integrations.
*   **BMAD-METHOD** (Brian Madison) — 40,000+ stars on GitHub, the "methodology-first-then-tool" methodology, positioned as the "antithesis of vibe coding".
*   **Tessl** — the startup of Guy Podjarny (ex-Snyk founder), $125M of venture capital, Tessl Framework + Spec Registry launched in September 2025.
*   **CodeSpeak** (Andrey Breslav, ex-Kotlin lead designer) — generates production code from markdown specifications, alpha stage, March 2026. A direct ideological relative of Peter's True BDD approach.
*   Academic support: arxiv 2602.00180 ("Spec-Driven Development: From Code to Contract") explicitly draws the line of succession "TDD = SDD at the unit level; BDD = direct ancestor".

**\[External research: METR, CodeRabbit, redmonk\]** The trend "test-driven everything / spec-first / requirements-as-code" is real, but contested. The arc: Karpathy's viral tweet about "vibe coding" (2 February 2025; Collins Word of the Year 2025) → backlash because of failure modes → CodeRabbit (December 2025): AI-collaborated code has 1.7× more major issues, a 2.74× security vulnerability rate → METR study: experienced OSS maintainers with Cursor Pro are **19% slower** at completing real tasks → the pivot of Karpathy himself in February 2026 from "vibe coding" to "agentic engineering".

Criticism of SDD from inside: Gojko Adzic (BDD pioneer) warned that "Spec-Driven Development is the revenge of Waterfall" — a caution against the return of the worst Waterfall patterns.

**\[External research + Internal: Peter/project\]** Conclusion: Peter's True BDD concept fits into a real, validated category — and at the same time is exposed to strong competition from already established players (BMAD, Spec Kit, Tessl, Kiro, CodeSpeak). The key moat potentially lies not at the tool level, but at the level of methodology + vertical domain expertise. Peter's separate positioning — _"so that the code can be deleted along the way"_ — is more radical than the competitors': BMAD/Kiro/Spec Kit are aimed at improving the process of writing code, whereas True BDD sets the goal of fully moving the source of truth to the documentation.

* * *

## 3\. Key pains of this segment
**\[External research: METR, CodeRabbit, Veracode\]** Technical pains that recur in public discussions:
*   **Quality and maintainability of AI-generated code**: CodeRabbit (December 2025) — 1.7× more major issues, 75% more misconfigurations, 2.74× security vulnerabilities in AI-co-authored PRs. Veracode 2025: ~45% of AI code samples fail OWASP tests; bigger models do NOT give safer code. GitClear: refactoring fell from 25% (2021) to <10% of changed lines (2024); duplication ~4× higher.
*   **Context window limitations** — even Claude Code "crashes into memory constraints" (swyx retros of late 2025).
*   **Eval / test problems for agentic systems**: ClawBench shows agents falling from ~70% on sandbox benchmarks to ~6.5% on realistic live-website tasks. SWE-bench is probably already saturated.
*   **Reward hacking** — has become an operational concern, not an academic one.
*   **Lethal Trifecta** (term from AIE Europe 2026): web access + personal data + email sending = a full attack chain through a coding agent.

**\[External research: Latent Space, AIE talks\]** Community pains:

*   **Isolation**: solo-founder essays and AI-cofounder articles record real demand for peer-to-peer brainstorming. swyx (January 2026): "the community is so hungry to learn and share and help each other out".
*   **Peer-learning gap** — the main reason for the existence of AIE as a "schelling point" for the industry.
*   **Maintainer burnout** (Tidelift 2024): 60% of maintainers thought about quitting; 44% reported burnout.

**\[External research: TechTarget, OSSF, CodeRabbit, Anthropic\]** Commercial / OSS pains:

*   **AI slop overwhelming maintainers**: curl closed its bug bounty in January 2026 because ~20% of submissions were AI-generated noise. Node.js raised signal requirements after >30 AI-slop reports over the holidays. **Peter Steinberger publicly asked for a solution for working with the flow of PRs that overloads him** — this is a canonical example of pain for the solo-maintainer type (type B below).
*   **Vibe Coding Kills Open Source paper** (Koren/Békés/Hinz/Lohmann, January 2026): they model that with the spread of vibe coding the diversity and the average quality of shared OSS falls.
*   **Anthropic "Claude for Open Source"** (26 February 2026): 6 months of free Claude Max 20x for qualifying maintainers — a market signal that even the labs see maintainer attrition as a strategic risk.

**\[External research + Internal: observation\]** The existential pain ("will my project be relevant if Cursor / Claude Code does this in 6 months?") is the main anxiety of founders and staff engineers of OS-AI in 2025-2026. Karpathy on 27 December 2025 published the "magnitude 9 earthquake" tweet about the speed of change of the skill stack. Anthropic Claude Code went from $0 to $2.5B ARR in ~12 months. Cognition bought Windsurf in July 2025. **OpenAI bought Peter Steinberger's OpenClaw — an example of how quickly the big players absorb successful OSS projects**, and at the same time an example of the fact that an individual engineer with a noticeable project can become an object of strategic attention of Big Tech.

This anxiety is felt by literally everyone — from solo OSS maintainers to funded startups. **This creates a real opportunity for counter-conversations** — such people are easier to draw into a contrarian thesis than a year ago.

* * *

## 4\. What Peter can give them (value proposition, broader than True BDD)
**\[Internal: Peter/project\]** Peter has a set of advantages which in combination is rare in this niche. Precisely the combination, not the separate elements, is his edge.
**First — technical depth with historical perspective.** Peter worked with neural networks even before the modern ChatGPT wave, built and brought to market BankAI — a pre-ChatGPT GenAI solution for banking, sold to a German bank in 2023 (we do not disclose the name of the bank because of an NDA). This is rare experience of production GenAI in a regulated industry before it became fashionable. Most founders and staff engineers in OS-AI are now 2-3 years into AI coding; Peter has 7+ years, through the previous wave. This is currency for a conversation with people who see through hype.
**Second — leadership context and resource.** Co-CEO of the product-and-service company Speed & Function. Experience with Wikimedia, Open Supply Hub. Access to the engineering base of Speed & Function — as an optional resource, not as an obligation on the partner's side. In other words: a partner role in the project ("we do it together"), not "I will hire you".
**Third — non-ordinary thinking about AI development.** Peter publicly articulates:
*   the thesis-conflict of AI-first vs AI-assistant mindset;
*   "requirements as the new bottleneck";
*   a conscious synthesis of deterministic and creative AI systems;
*   why junior developers thrive in the AI era (a contrast with the general panic narrative about the destruction of the junior market).

**\[External research: arxiv 2512.14012\]** The last point echoes the December 2025 paper "Professional Software Developers Don't Vibe, They Control": professional devs use agents strategically, not as a replacement, but as a force lever.

**Fourth — honesty about uncertainty.** **\[Internal: Peter/project\]** Peter is known for his phrase about BankAI — "We hope more than we know that it will work." This resonates strongly with the spirit of the 2025-2026 community, where the honest studies of METR and CodeRabbit, Karpathy's cautious pivot, Tuomas Artman's talks about "taste as competitive advantage" form a norm of intellectual honesty against performative AI hype.

**Fifth — an intellectual sparring partner for those who are rethinking what development looks like in the AI era.** This directly answers the community pain "no peer to brainstorm with".

**Sixth — True BDD as methodology + instrument.** A concrete thesis that goes further than the competitors (BMAD, Kiro, Spec Kit, Tessl, CodeSpeak): not just "generate code from a specification", but **move the source of truth from the code to the documentation** — so that the code becomes a disposable artifact rather than the center of truth about the system. The prototype already performs real actions. The format is a small console utility that the user downloads themselves, without a platform and a service — this resonates with the indie-hacker / OSS ethos of the TA.

**\[Internal: observation\]** What Peter does **not** give — and this must be honestly recorded: he does not give recognition of the SF-Valley network ("I will introduce you to Sequoia"), does not give exponential salary growth, does not give Big Tech compensation. Therefore the value proposition must focus on what Big Tech does not give — autonomy, ownership, intellectual partnership, a contrarian thesis with historical background.

* * *

## 5\. How this segment interacts with LinkedIn
**\[External research: Teract AI, StartupEdition,** [**Originality.ai**](http://Originality.ai)**\]** The paradox of the platform: this audience **predominantly does not live on LinkedIn**, but on X (Twitter), GitHub, Discord, at conferences. Multiple 2025-2026 studies converge: individual developers are 4× more active on X than on LinkedIn; technical content gives 3-5× better engagement on X. [Originality.ai](http://Originality.ai) 2025: **53.7% of long LinkedIn posts are "Likely AI"**, which forms the perception of LinkedIn as an "AI slop" channel among technical readers.
**\[External research + Internal: observation\]** The real behaviour of the three OS-AI types on LinkedIn looks like this:
**Type A — Industry veteran.** LinkedIn for them is a **formal professional showcase** (especially for former Big Tech). They have 10K+ connections from previous roles, post rarely (once every 2-4 weeks), the posts are often about high-level observations or announcements (a new company, a lecture, a paper). Engagement is moderate, but mirrors real professional weight. Andrey Breslav (ex-Kotlin) is a typical example: he is present on LinkedIn, but the real conversations are conducted on X, at conferences, in academic circles.
**Type B — Solo maintainer / viral creator.** LinkedIn for them is a **secondary channel**. The basis of their presence is X (where the project exploded), GitHub (where the code lives), a personal blog. Peter Steinberger is a typical example: WhatsApp Relay and OpenClaw grew through X threads and the OSS community, not through LinkedIn. If Steinberger posts on LinkedIn — it is a cross-post or an announcement about a milestone, not a place for technical discussion.
**Type C — Project lead of a mature OSS tool.** They use LinkedIn for recruiting, fundraising communication and enterprise partnerships. Technical discussion goes on in other channels (their Discord servers, X, GitHub). Saoud Rizwan (Cline), Paul Gauthier (Aider), Dax Raad (OpenCode), the teams of Roo Code, Kilo Code — all are present on LinkedIn, but LinkedIn's role is a secondary professional layer, not the center of the conversation.
**\[External research: Carouselli, Postiv,** [**daily.dev**](http://daily.dev)**\]** What **will work** on LinkedIn for reaching this segment, given their real behaviour:
*   **Technical depth without hype**. Long posts with specifics, numbers, failure modes. The community reacts especially to "anti-hype" content.
*   **Failure stories with specifics**. "Why BankAI barely survived until the ChatGPT moment" — stronger than success stories. Echoes the spirit of the METR and CodeRabbit studies.
*   **Specific data instead of general statements**. METR 19%, CodeRabbit 1.7×, Veracode 45% — numbers travel. General statements are ignored.
*   **Subtle comments under the posts of thought leaders in the domain**. Karpathy, swyx, Lenny, Gergely Orosz, Brian Madison, Drew Breunig, Peter Steinberger, Andrey Breslav. Comments are 15× more valuable than likes for algorithmic reach. A quality comment from Peter under a Steinberger post is many times more effective than a separate post.
*   **Direct messages with a concrete value link**. Not cold outreach. A reference to the partner's specific work + a concrete hypothesis of why True BDD is relevant to this project.
*   **PDF carousels with technical material**. The highest-reach format in 2025-2026 given dwell time. Suitable for "lessons from BankAI" or "True BDD manifesto draft".
*   **A cadence of 3×/week with strong engagement** is stronger than daily average content.

**\[External research\]** What will **NOT** work:

*   Marketing posts without technical substance.
*   "Thought leadership" with the language "revolutionary" / "game-changing" / "we're transforming X".
*   Aggressive networking / cold connections without a warm intro.
*   AI-generated posts — the community detects them instantly.
*   Engagement bait ("Agree?" / "Like if...") — the algorithm penalizes it.
*   Performative vibe-coding theatre.

**\[Internal: observation + team decision\]** A key caution for Boarlabz: **reaching the core OS-AI audience with LinkedIn alone will be difficult**. Going out to X / GitHub / Discord is strategically inevitable, but this is a separate decision that Peter will make later. In the current phase LinkedIn performs the function of a **warming-and-credibility-building layer that feeds off-platform conversations**:

*   If Peter wants to reach Steinberger — probably through X, but a LinkedIn presence makes the first touch less cold.
*   If Peter wants to talk to Brian Madison — through the podcast industry or AIE conferences, but the LinkedIn profile is checked first.
*   If Peter sees Andrey Breslav at a Cambridge lecture — a LinkedIn connection post-event is a natural step.

LinkedIn is not the main channel, but a necessary signal of seriousness.

* * *

## 6\. Three types and reference people for validation
**\[Internal + External research\]** The segment breaks down into three types. This is a working classification for the outreach strategy — each type requires a separate approach and gives different benefit to True BDD as a project.
### Type A — Industry veteran building an "AI-native" product
**Profile.** A veteran with 10–20+ years of experience, often with a name that is recognized in the technical community. Has a reputation through previous work (a programming language, IDE, framework, OS), is now building their own spec-driven or AI-native product. Has an academic-style attitude to the problem — publishes lectures, articles, discusses systems design. Often European.
**Canonical example: Andrey Breslav.** Ex-lead designer of the Kotlin language (2010–2020, ~7 million developers). Now founder of **CodeSpeak** — a product that generates production code from markdown specifications instead of traditional code. Stage: alpha, March 2026. Speaks at Cambridge University with the lecture "From Kotlin to CodeSpeak", discusses language design and the influence of LLMs. **\[Internal: observation\]** This is **the closest ideological relative of Peter's True BDD** among all the candidates — Breslav is literally building what Peter talks about as his own approach. The difference is in the radicalness of the thesis: CodeSpeak generates code from specifications; True BDD goes further — code is disposable, the documentation is the source of truth.
**Why valuable for True BDD:** Breslav formalizes a kindred thesis with his own language engineering in the background. Peter's conversation with him is not "I came to recruit you", but "we have the same thesis, let's discuss tradeoffs". If such a conversation takes place, even if it does not end in a joint project, it validates the True BDD thesis and gives Peter a reference partner for future public communication.
**Outreach strategy for type A:**
*   Thorough study of public materials (CodeSpeak alpha, the Cambridge lecture, threads on X).
*   A technical post by Peter about his own approach with a reference to CodeSpeak as a kindred example.
*   A DM or email with a concrete technical question / observation about the tradeoffs of both approaches.
*   A request for a 30-minute conversation not to "present True BDD", but to "exchange observations".

**Other candidates for type A (for further research):** Patrick Debois ("the father of DevOps", public advocate of Tessl), Gojko Adzic (BDD pioneer, critic of SDD), potentially other ex-lead designers of languages and frameworks who pivoted into an AI-native direction.

* * *

### Type B — Solo maintainer → viral community builder
**Profile.** An engineer who started with their own project (often solo), and over a short arc of time grew it to viral scale — tens/hundreds of thousands of GitHub stars, millions of visits, a real community of users. Often from a European environment, with a characteristic indie-hacker / vibe-coder ethos. Active on X, keeps a blog, posts streams on Twitch / YouTube.
**Canonical example: Peter Steinberger.** An Austrian "vibe coder" who started with the one-man project WhatsApp Relay and in half a year grew it to **100,000+ GitHub stars and 2 million visits in one week**. The OpenClaw project was recently acquired by OpenAI. After the acquisition Steinberger publicly asks for a solution for working with the flow of PRs that overloads him — a canonical illustration of the AI-slop pain of the maintainer segment.
**Why valuable for True BDD:** Steinberger is not an academic veteran but a practitioner with real experience of how the community consumes tools. His public cry about PR overload is a signal that he is **right now** looking for solutions that help a maintainer manage scale without loss of quality. If Peter's True BDD has a point of contact with this problem (documentation as a filter for incoming contributions, specs as a test suite), then this is a natural entry point. Separately, Steinberger has large-scale public reach on X, which makes him a potential ambassador of the idea if it appeals to him.
**Outreach strategy for type B:**
*   Following public posts on X and the blog.
*   A useful comment or thread expansion under one of his posts about AI slop or maintainer burnout — with a concrete technical contribution, not just "respect".
*   If a dialogue catches fire — a DM with a link to concrete material (for example, a draft True BDD manifesto that addresses his pain).
*   AIE Europe 2026 and subsequent IRL events — a probable place of meeting.

**Other candidates for type B (for further research):** Dax Raad / SST / OpenCode (140K+ stars, 850+ contributors, 6.5M monthly devs), Paul Gauthier (Aider, 43.9K stars, solo), Andrew Christianson (RA.Aid, OCV Catalyst). Among the fresher ones — any maintainers of projects that make >10K stars in the last 6 months.

* * *

### Type C — Project lead of a mature Open Source AI tool
**Profile.** Founder/CEO, CTO or **staff engineer** of a funded OSS project that is already at a stage with a real product, a community, possibly seed/Series A funding. A technical leader, not only a founder. Active in public discourse through podcasts, conference talks, GitHub releases, blog posts. Focused on enterprise adoption, governance, audit, scale.
**Important:** it is precisely here that both roles named by Peter at 27:09 intersect — **founders** of funded OSS projects (Saoud Rizwan, Brian Madison) and **staff engineers** in them (key technical leads of Cline, Continue, OpenCode, Roo Code, Kilo Code, who are not founders but hold the technical axis of the product). The candidate pool in type C is broader thanks to staff-level engineers, who are often less publicly visible than their founders, but really make the technical decisions.
**Canonical examples:**
*   **Cline (Saoud Rizwan, San Francisco).** **57.9K stars, 4M+ developers**, leader in governance and audit among OSS coding agents. $32M Series A+Seed July 2025. Apache 2.0. A principled position: "inference cannot be the business model".
*   **Roo Code.** A fork of Cline with the modes **Architect / Code / Debug / Custom**, a perfect 5.0 user rating. The architectural feature — workflow modes — is a direct ideological relative of the True BDD thesis about separate roles for specification / implementation / validation.
*   **Kilo Code.** **$8M seed with a GitLab co-founder on board**. Positions itself as an "agentic engineering platform". A fresh player with a strong write-up in the DevOps community.
*   **OpenCode (Dax Raad / SST).** 140K+ stars, 850+ contributors, OpenCode Black $200/month unlimited tier launched on 9 January 2026. One of the fastest-growing OSS projects of this year.
*   **Aider (Paul Gauthier, Santa Barbara).** 43.9K stars, ex-CTO of Groupon, ex-Inktomi; maintains the Aider Polyglot Leaderboard as the de facto eval standard.
*   **OpenHands.** A large community-driven project with an active contributor base.
*   [**Continue.dev**](http://Continue.dev) **(Ty Dunn / Nate Sesti, San Francisco).** YC alum; $5.1M; a pivot towards "AI checks in CI".
*   **goose (Block / Square).** Donated to the Linux Foundation Agentic AI Foundation at the end of 2025.

**Why valuable for True BDD:** Project leads of type C have professional weight for validating the True BDD thesis in the community, access to their own OSS communities as a potential channel, and — most importantly — real experience of building the very thing that Peter is thinking about theoretically. If Peter gets a 30-minute conversation with Saoud Rizwan (founder of Cline) or Brian Madison (founder of BMAD), this gives validation that is most likely unavailable through the other types. If it is possible to reach a staff-level engineer in one of these projects — that is no less valuable given the possibility of a real code contribution to True BDD.

**Outreach strategy for type C:**

*   Quality public communication around their projects — pull requests, issues with a technical contribution, comments under public posts.
*   Podcast presence on the same shows where they have appeared (Latent Space, Tech Lead Journal, AI Engineer podcast).
*   Shared AIE events (Europe April 2026 has already taken place; WF SF 2026 is the next point).
*   Through warm acquaintances — podcast interviewers are themselves trust nodes (swyx, Henry Suryawirawan, Nathan Labenz).

**Other candidates for type C (for further research):** Brian Madison (BMAD-METHOD, Chicago; Tech Lead Journal #255 alum), Dane Schneider (Plandex), Meng Zhang (Tabby — relevant for regulated industries), the teams of Anthropic Claude Code, Sourcegraph Amp, Cognition Devin.

* * *

### Common observations across the three types
**\[Internal: observation\]** The three types give **different entry points and different forms of partnership**:
*   **Type A** — a probable intellectual partner for the thesis development of True BDD; the lowest risk that he will go somewhere, but also a narrow form of cooperation (exchange, not commitment). These are predominantly founders of new AI-native projects.
*   **Type B** — a probable ambassador / public advocate; wide reach, but a high risk that attention will be dispersed. These are predominantly solo-maintainer-founders of viral OSS projects.
*   **Type C** — a probable joint-project partner or contributing engineer; the highest chance of a real code contribution, but also the highest competition with Big Tech offers. Here founders and staff engineers of funded OSS projects are combined — and this is the most precise match with Peter's words at 27:09.

Strategically, it is worth Peter starting with types A and B — there the probability of a quality first conversation is higher, the entry threshold is lower, there is less competition with venture capital. Type C is a longer game, but potentially with the greatest leverage.

* * *

## 7\. Open questions for validation with Peter
This block is what the document asks to clarify before the strategy is fixed. Part of the initial questions has already received answers from Peter — we have moved them into the main text of the document.
**\[What Peter has already clarified, recorded for future versions of the document\]**
*   ✅ Project name: **True BDD** (BDD = Behavior-Driven Development).
*   ✅ Essence of the product: to move the source of truth from the code to the documentation — so that AI can fully restore the code and the project having access exclusively to the documentation. _"So that the code can be deleted along the way."_
*   ✅ Type/format: a tool / console utility. **Not** a platform, **not** a service, **not** a framework (Peter explicitly excluded these). In the future it may grow into a platform.
*   ✅ Stage: a prototype that already performs real actions.
*   ✅ Target audience: founders and staff engineers of AI-coding OSS projects (27:09 of the transcript of 24 April).
*   ✅ Exception for developers: non-public developers are not the TA; public ones (talks, podcasts, articles) get into the TA.
*   ✅ Geography: without limitations.
*   ✅ Funding stage: without limitations.

**\[What still needs clarification\]**

**Readiness for a public launch with True BDD.** The prototype already performs real actions — the question is whether and when Peter is ready to show it publicly (a repo on GitHub, a demo video, a manifesto article, a blog post on the S&F site, or in his own space). The LinkedIn presence strategy depends on whether there is a working artifact that can be referred to in posts and DMs. Without an artifact the strategy is limited to topics of AI development in general, without a link to Peter's concrete instrument.

**Readiness to publicly articulate True BDD.** The strategy assumes that Peter is ready to write long technical posts with his own position, to answer the comments of thought leaders, potentially to appear on a podcast (Latent Space, Tech Lead Journal, Cognitive Revolution). If not — the strategy needs reworking.

**Channels outside LinkedIn in background mode.** The question of when and how Boarlabz / Peter plan to activate an X presence, a GitHub repo for True BDD, potentially Substack/blog. The document does not decide this, but records: without a cross-platform presence, reaching the core IC audience on LinkedIn alone will be difficult.

**Peter's time budget.** How many hours/week is Peter ready to invest in content production + interaction? This determines which formats to bet on (PDF carousels require production, text posts — less).

**Success metrics.** At the meeting of 24 April 2026 Peter voiced the goal of "1–2 partners". What does "find a partner" mean for him? A first professional conversation? A joint blog post? A joint talk at AIE? A commit to the True BDD repo? Boarlabz needs an explicit KPI so as not to optimize for vanity metrics.

**Priority among the types.** Does Peter agree with the recommendation to start with A and B (lower threshold, higher quality of the first conversation) before C (higher leverage, but higher competition with VC)?

**Concrete first candidates for outreach.** Has Peter already had preliminary contact with anyone from the list (Andrey Breslav, Peter Steinberger, Saoud Rizwan, Brian Madison, Dax Raad, Paul Gauthier)? Are there others whom we missed?

**Positioning of True BDD relative to competitors.** True BDD is more radical than BMAD/Kiro/Spec Kit/Tessl (all of them leave the code as the center of truth; True BDD makes it disposable). How does Peter want to formulate this positioning publicly? Is he ready for direct comparisons in posts? This affects the tone and format of communication.

* * *

**General note about the methodology of this document.** The internal block (Peter's statements from transcripts and project knowledge) we did not invent — where something is missing, it is written directly "check with Peter". The external research took fresh sources of 2025-2026: Latent Space / swyx, AI Engineer Summit official materials, GitHub blog, Anthropic / AWS / Tessl / Cursor official communications, TechCrunch / Fortune / The Register, arxiv preprints, podcast transcripts, [agent-wars.com](http://agent-wars.com), [openclaw.ai](http://openclaw.ai), [coderabbit.ai](http://coderabbit.ai). The name of the German bank that bought BankAI is not disclosed in view of an NDA. Figures with a distinct marketing origin (for example, "5M+ Cline installs", "4M+ developers") are left as they are, but they should be read with caution.
