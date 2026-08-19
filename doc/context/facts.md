# Facts — conversational ledger

Dated empirical discoveries about external systems, extracted from task
transcripts by the context archivist (`.claude/hooks/context.py`). Append-only;
newest at the bottom.

## 2026-07-21 — The task ran the LinkedIn comment-hourly drafting and Slack-delivery stages from an existing gather contract without repeating feed gathering.

_transcript: 20260721-075639-a8bbd0c0-run-linkedin-comment-hourly-using-the-pr.md_

- The Google Drive REST bridge returned `500 unauthorized_client` for all prep-refs downloads across fresh tokens and multiple documents; this was verified as systemic rather than document-specific, so drafting fell back to the existing local cache and kept its manifest unchanged for retry (2026-07-21T08:19:17Z).

## 2026-07-16 — The task audited the LinkedIn comment-generation workflow, backfilled full post text into analytics and Grafana, and investigated missing July 2026 dashboard data.

_transcript: 20260716-130906-3b7e2b57-i-wanto-change-way-to-create-comments-to.md_

- The cached ICP reference was nearly identical to the True BDD factsheet, so the comment pipeline's intended ICP-fit check provided no independent audience signal; whether the configured Google Doc ID was wrong or the upstream ICP document had been overwritten remained unresolved (2026-07-16T13:11:28Z).

## 2026-07-18 — The task mapped the artifacts used for LinkedIn comment drafting and verified whether ClickUp’s API can create custom fields on the Posts list.

_transcript: 20260718-063319-58efb3a9-lets-take-a-look-at-what-artifacts-are-u.md_

- As of 2026-07-18, ClickUp’s public API could read existing custom-field definitions and set or remove field values on tasks, but could not create or edit custom-field definitions; new fields therefore had to be created in the ClickUp UI first (2026-07-18T07:00:50Z).

## 2026-07-18 — The task explored moving LinkedIn analytics to ClickUp, corrected a task-type naming hallucination, created an MCP gap ticket, migrated comment automation to GitHub Actions, and diagnosed a failed weekly scrape.

_transcript: 20260718-190554-372ee591-next-task-is-it-use-clicku-as-source-of.md_

- As of 2026-07-20, ClickUp task payloads exposed only a numeric `custom_item_id`, while the available ClickUp MCP tools and REST proxy exposed no workspace task-type registry lookup, so those tools could distinguish types by ID but could not resolve their actual names (2026-07-20T10:00:35Z).
- ClickUp has no composite/object custom-field type; nested weekly analytics must therefore be modeled as related tasks or stored as opaque JSON in a Text Area field (verified 2026-07-20T09:49:52Z).
- ClickUp’s Custom Fields by task type beta allows fields to be scoped to a custom task type instead of exposing every field across the list; Formula and List-to-List Relationship fields cannot be type-scoped (verified 2026-07-20T09:49:52Z).

## 2026-07-20 — The task implemented and live-tested a self-healing weekly LinkedIn stats pipeline, repaired the runner architecture, and merged the healed scrape and watchdog cleanup.

_transcript: 20260720-114324-f671ba95-i-want-also-to-create-make-the-workflow.md_

- The Mac Studio’s previous GitHub Actions runner binaries were x86_64-only and live Runner and Chrome processes carried Rosetta’s `P_TRANSLATED` flag; after reinstalling the arm64 runner, job Chrome ran natively and the in-job A/B confirmed the runner-only scrape slowdown disappeared (binary/process verification 2026-07-20T14:07:37Z; A/B confirmation 2026-07-20T14:30:07Z).

## 2026-07-22 — The task verified whether Z.ai’s ZCode development environment is open source.

_transcript: 20260722-061036-62eef0e2-did-context-py-was-called-after-new-task.md_

- As of 2026-07-25, ZCode itself was closed source: its site distributed compiled desktop binaries without a source repository or open-source license, and Z.ai’s GitHub organization exposed only a ZCode feedback tracker; the open components were the GLM-5.2 model weights and `zai-coding-plugins`, not the ZCode app (verified 2026-07-25T12:19:22Z).

## 2026-07-25 — The task began planning changes to LinkedIn post generation so completed posts go to ClickUp and LinkedIn links shared by humans in Slack are also processed, using iterative Codex review and testing.

_transcript: 20260725-150058-15284ba4-the-linkedin-post-generation-i-need-two.md_

- The Slack connector’s REST proxy returned paginated raw channel-history JSON using an `oldest` watermark; bot-authored messages carried `bot_id` while human-authored messages did not, providing a deterministic author filter (live-verified 2026-07-25T15:39:21Z).
- The available ClickUp REST proxy was read-only, so creating tasks in the target list required the ClickUp MCP `createTask` tool (live-verified 2026-07-25T15:39:21Z).
- ClickUp’s indexed/rendered task representation did not reliably preserve the literal Markdown `_key: …_` identity footer, although the key remained available in the full REST-proxy description; adoption therefore needed the exact Source URL plus a full-description check (live-verified 2026-07-25T18:35:46Z).
- In the tested Slack REST-bearer flow, Sonnet treated the mint request as credential exfiltration and returned no parseable token; pinned Haiku succeeded with connector context in the system prompt, and probing the bearer before use caught altered or placeholder output (live-verified 2026-07-25T18:35:46Z).
- The ClickUp Posts list was fully reconciled with `dashboards/li-stats/posts/`: every tracked post and repost had exactly one published task with its post URL in the Source field, with no duplicate or unknown Source URLs (verified 2026-07-27T21:55:16Z).
- Reconciling ClickUp tasks with LinkedIn posts requires NFKC-normalized full-text comparison because LinkedIn’s styled Unicode defeats plain-text matching and can make already-published posts appear unmatched (verified 2026-07-27T21:55:16Z).
- The ClickUp MCP `createTask` connector could not set custom task type ID `1010`, so tasks created during the backfill used the default task type even though hand-created post tasks used that custom type (observed 2026-07-27T21:55:16Z).
- As of 2026-08-13, the Slack MCP’s only write methods accepted a channel or thread target plus a single Slack-mrkdwn text string: formatted text including bold and labeled hyperlinks worked, but Block Kit, attachments, and file or image uploads were unavailable, and the REST escape hatch exposed only GET endpoints (live-verified 2026-08-13T20:54:01Z).
- As of 2026-08-14, ClickUp folder `a-brain` (`901515828753`) in the AWESOME space contains the Awesome MCP product backlog in Tasks list `901523076242` and meeting records in Transcripts list `901525028333` (live-read 2026-08-14T06:34:04Z).
- As of 2026-08-14, the scoped a-brain backlog contained no ticket requesting Slack message editing/deletion, reactions, file or image uploads, message search, Block Kit or rich formatting, or events/subscriptions (live-read 2026-08-14T06:41:45Z).
- The scoped backlog contained completed ClickUp tickets for document update/deletion (`86c9pkqwh`), image upload (`86c9jbrf2`), and formatted Markdown content (`86c9mr5kd`), plus open high-priority HubSpot tickets for search (`86cb4hpyy`) and engagement writes (`86cb4hq5q`); no event/subscription ticket was found (live-read 2026-08-14T06:41:45Z).
- As of 2026-08-14, the ClickUp connector already exposed task-event subscription tools (`subscribeToTaskEvents`, `listTaskEventSubscriptions`, and `debugTaskEventSubscription`), while the Slack connector exposed no corresponding event/subscription capability (live-verified 2026-08-14T06:41:45Z).
- ~~As of 2026-08-14, ClickUp MCP `createTask` and `updateTask` could write rich descriptions through `markdownContent`, but MCP `getTask` and the REST proxy returned only flattened plain text; tables surfaced as mangled `[table-embed:…]` markers, so an agent could not reconstruct a ticket template’s formatting from either read path (live-verified 2026-08-14T07:04:12Z).~~ _(superseded 2026-07-25)_
- ~~As of 2026-08-14, ClickUp MCP `createTask` and `updateTask` could write rich descriptions through `markdownContent`, whereas MCP `getTask` and the REST proxy exposed flattened text and table-embed markers; despite that loss of raw markup, the flattened description retained enough recognizable section structure (`## User Story` rendered as `User Story`) to reconstruct and successfully update the ticket, so this workflow did not demonstrate a connector gap (read/write behavior live-verified 2026-08-14T07:04:12Z; successful reconstruction confirmed by Peter 2026-08-14T07:06:32Z).~~ _(superseded 2026-07-25)_
- As of 2026-08-14, ClickUp MCP `createTask` and `updateTask` could write rich descriptions through `markdownContent`, but readback remained flattened: MCP `getTask` exposed flattened descriptions and table embeds, while the REST task response’s two text fields were plain-text `description` and `text_content`, with no `markdown_description` key. The flattened section structure was nevertheless sufficient to reconstruct and successfully update the ticket, so this workflow did not demonstrate a connector gap (successful reconstruction confirmed by Peter 2026-08-14T07:06:32Z; REST keys rechecked 2026-08-14T07:08:23Z).
- ~~As of 2026-08-15, the ClickUp Docs image connector accepted public JPG/PNG/GIF/BMP/WebP URLs up to 20 MB or base64 input with an approximately 1.5 MB hard limit; a public-URL probe was successfully re-hosted as a publicly reachable, unauthenticated WebP on `clickup.awesome-mcp.xyz` and returned HTTP 200 (schema inspected and URL path live-verified 2026-08-15T09:57:52Z).~~ _(superseded 2026-07-25)_
- As of 2026-08-15, Google Docs image insertion succeeded with a publicly reachable PNG URL but rejected a WebP URL and direct base64; a local image path also failed because the remote connector on `awesome-mcp.xyz` cannot access the Mac filesystem, so ClickUp’s WebP re-host cannot be used as a bridge into Google Docs (live-verified 2026-08-15T09:57:52Z).
- As of 2026-08-15, the available Google Drive connector and REST escape hatch exposed only GET operations and no upload tool, so they could not upload local images to obtain Drive file IDs for Google Docs insertion (verified 2026-08-15T09:57:52Z).
- As of 2026-08-15, Outline was live through the `Knowledge` connector, but its attachment tools could only list existing attachments and resolve downloads; no upload/create-attachment tool or direct Outline API token was available, and the shared REST fallback exposed only GET endpoints marked planned (connector and environment inspected 2026-08-15T10:24:37Z).
- An existing Outline image resolved through `getAttachmentUrl` to a signed S3 URL with a five-minute expiry and returned HTTP 200 as PNG, confirming that already-stored Outline images can be read during that window (live-verified 2026-08-15T10:24:37Z).
- As of 2026-08-16, the tested Soniox key authenticated and completed paid transcriptions, but `/v1/account`, `/v1/me`, `/v1/billing`, and `/v1/organization` all returned 404, so those API paths could not reveal the owning email (live-verified 2026-08-16T11:06:41Z).
- ~~As of 2026-08-16, the locally configured Google Drive `rclone` remote and Drive REST proxy were read-only, while the Google Docs connector successfully created documents in the target folder; export round-trips preserved the text, with Markdown list markers becoming native Docs bullets and an added BOM (live-verified 2026-08-16T11:06:41Z).~~ _(superseded 2026-07-25)_
- As of 2026-08-16, the locally configured Google Drive `rclone` remote and Drive REST proxy were read-only, while the Google Docs connector created documents in the target folder and export round-trips preserved substantive text; Markdown list markers became native bullets with an added BOM, `---` rendered as native horizontal rules, and the verifier tokenized the colon after `**bold**` separately, so those representation changes must be normalized to avoid false content-drift reports (initial behavior live-verified 2026-08-16T11:06:41Z; additional rendering behavior verified 2026-08-16T11:16:05Z).
- As of 2026-08-16, the available ClickUp Docs upload-like tools accepted only public JPG/PNG/GIF/BMP/WebP inputs up to 20 MB or base64 around a 1.5 MB hard limit and re-hosted them externally as WebP; there was no arbitrary-file attachment, Doc rename, or Doc deletion tool, and the REST proxy remained GET-only, so transcript text had to be inserted as page Markdown and `.mp4` files could not be attached (public image path live-verified 2026-08-15T09:57:52Z; schemas and proxy rechecked 2026-08-16T12:03:03Z).
- As of 2026-08-16, `AgriTech Program — Transcripts & Summaries` was stored at `https://app.clickup.com/90151491867/v/dc/2kyq568v-29675` in ClickUp folder Search for funds (`901517334252`) as one multi-tab Doc containing the summaries and complete module transcripts; the separate TrueBDD research Doc was stored at `https://app.clickup.com/90151491867/v/dc/2kyq568v-29695` in folder true-bdd (`901515828756`), and direct readback verified both document bodies against their sources (2026-08-16T12:03:03Z).
- LinkedIn reaction entries expose no timestamp, whereas comment URNs provide exact dates; historical reactions therefore cannot be assigned to a week from one snapshot, making the first reactor snapshot an undated baseline and successive snapshot diffs the available source of weekly attribution (live-verified 2026-08-17T18:38:20Z).
- LinkedIn comments no longer rendered on the tested `/feed/update/<urn>/` post page even after activating the comments control: neither the known comment-article selector nor comment-URN nodes appeared, although an earlier snapshot of the same post contained comments, confirming drift in the existing stats comment path (live-verified 2026-08-17T18:38:20Z).
- ClickUp Docs `editPage` in `append` mode joins existing and appended content with one newline while preserving a leading newline supplied in the payload; prefix an appended chunk with a newline when a paragraph break must survive the chunk boundary (live-probed 2026-08-17T18:48:05Z).
- Greg Ceccarelli’s LinkedIn profile showed him as SpecStory co-founder/CPO working in spec-driven agentic engineering and actively shipping OSS, making him a strong match for Peter’s ICP; nevertheless, the shipped headline-only classifier returned `false` because SpecStory’s domain was unclear from the headline, demonstrating a concrete false-negative mode for people whose company names are not self-describing (profile and classifier cross-checked 2026-08-17T19:29:37Z).
- On the Mac Studio, Playwright launches the `mcp-chrome-linkedin-ai` Chrome profile with `--use-mock-keychain`; LinkedIn cookies created in normally launched Chrome using the macOS Keychain were then silently discarded, so authentication for the pipelines must be established inside the Playwright-launched browser (launch flags and cookie loss live-verified 2026-08-18T10:10:51Z).
