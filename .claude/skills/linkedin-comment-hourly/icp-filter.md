# ICP gate for the LinkedIn feed filter

A feed post is accepted only when **both** gates pass:

1. the post is on-topic per [`interests.md`](interests.md), and
2. the **author** belongs to Peter's ICP.

This file is the pipeline's half of gate 2. The rubric itself is
[`sources/icp.md`](../../../sources/icp.md) — the canonical ICP document synced from ClickUp by the
`sync-sources` skill, handed to the classifier verbatim. What follows are the decision rules for
judging that rubric **from a LinkedIn card**, plus two hand-curated override lists.

Tune this file (or `sources/icp.md` upstream in ClickUp) to widen or narrow the gate — no code
change needed.

## Who is in

The short form of `sources/icp.md` §1 and §6:

- **Founder** of an AI-coding / agentic-coding / spec-driven-development project — coding agents,
  IDE extensions, CLI coding tools, agent frameworks, and the infrastructure directly around them.
  Open source is the norm for this segment, but a founder building the same category closed-source
  still counts if they hold the technical axis.
- **Staff-level engineer** in such a project — tech lead, architect, principal/staff IC, core
  maintainer. The people who decide where the product goes, not people who merely work there.
- **Solo maintainer** of a notable OSS project in that space.
- **A publicly visible developer** in that space — speaks at conferences, hosts a podcast, publishes
  technical writing, is the public face of the project. This is `sources/icp.md`'s explicit
  exception to "ordinary developers are not the ICP".

Geography, company size and funding stage are **not** criteria.

## Who is out

- Anyone whose AI work is applied rather than tool-building: AI features inside a non-developer
  product, AI consulting, AI-for-marketing/sales/recruiting/legal, "AI transformation".
- Executives without a hands-on technical axis — VP Sales, CMO, COO, fractional CTO-for-hire,
  agency owners, recruiters.
- Founders of startups outside the AI-coding category, however good the post is.
- Investors, analysts, researchers with no product, content creators, community managers,
  developer-relations staff who are not also the project's technical lead.
- Ordinary engineers at big AI labs or AI startups with no public technical leadership signal.

## How to judge from a card

The evidence in a feed card is the author's **name**, their **headline**, and the **post body**.
Use all three. The headline alone is not enough and has produced real misses — SpecStory's
co-founder was rejected by a headline-only classifier because the company's name doesn't say what it
builds.

- The post body is often the strongest evidence available: someone writing about their own agent's
  architecture, their repo's issue backlog, their release notes or their eval harness is telling you
  what they build, whatever their headline says.
- Titles inflate. "Founder & CEO" of an unnamed consultancy is not the ICP; "maintainer" of a real
  coding-agent repo is.
- A recognizable AI-coding project name in the headline or body (Cursor, Cline, Aider, Continue,
  OpenCode, Roo Code, Kilo Code, OpenHands, Claude Code, Codex, Windsurf, Zed, Kiro, Spec Kit,
  BMAD, Tessl, SpecStory, Plandex, Devin, goose, Tabby, …) plus a leadership or maintainer role is a
  strong accept. The list is illustrative, not exhaustive — new projects appear constantly.
- Do not infer seniority, domain or open-source involvement that is not written down somewhere in
  the evidence.

### Confidence

Report `icp_confidence: "high"` only when the evidence settles it either way:

- **high + true** — role and project category are both visible.
- **high + false** — the author is clearly in an unrelated domain or an unrelated role.
- **low** — anything else: a company name that doesn't disclose what it builds, a role word without
  a project, an AI-adjacent post from someone whose position you cannot place, a headline that is
  empty, purely promotional, or in a language you can't resolve.

`low` is not a failure. It routes the author to a profile probe, which reads their actual profile
page and decides from that. Guessing `high` to avoid the probe is the expensive mistake — it either
burns a real ICP author into the seen-set or ships a ticket for someone off-target.

## Always accept

Authors listed here skip the classifier and the profile probe entirely — their posts are accepted
whenever the post is on-topic. Use this for people you already know belong, and to repair a
false negative the moment you notice one.

One LinkedIn profile URL per bullet. Everything else on the line is a note for humans and is
ignored; lines without a `linkedin.com/in/...` URL are ignored entirely, so headings and prose like
this paragraph are safe.

```
- https://www.linkedin.com/in/some-slug — why they belong (optional note)
```

<!-- Empty by design as of 2026-08-17 — add people below. -->

## Never accept

Authors listed here are rejected before any LLM call, regardless of what they post. Use this for
people the classifier keeps letting through.

Same format as above.

<!-- Empty by design as of 2026-08-17 — add people below. -->
