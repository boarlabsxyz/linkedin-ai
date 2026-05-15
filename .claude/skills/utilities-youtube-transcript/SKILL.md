---
name: utilities-youtube-transcript
description: >
  Downloads a YouTube video's transcript as a clean timestamped text file. Tries
  yt-dlp first; falls back to a browser-driven Playwright path only when YouTube
  rate-limits yt-dlp (HTTP 429). Use this skill whenever the user provides a
  YouTube URL and says "download transcript", "download transcripts", "get the
  transcript", "fetch captions", or "transcribe this video". The output is a
  cached file at `tmp/transcripts/yt-<videoId>.<lang>.clean.txt` plus parseable
  metadata (TITLE, CHANNEL, UPLOAD_DATE, LANG) on stdout.
---

# YouTube Transcript Download

Thin orchestrator. The real work happens in two sub-agents that share a single
output contract — the skill picks which one to run.

## Inputs

1. **YouTube URL** (required) — any form: `watch?v=`, `/live/`, `/shorts/`, `youtu.be/`.
2. **Language** (optional, default `en`) — original-spoken-language code is best
   for non-English videos (`ru`, `uk`, `es`, `de`, `fr`, `ja`, …).

## The shared contract

Both sub-agents print exactly one of two things as their final message:

**Success — five lines:**

```
TRANSCRIPT_PATH=/abs/path/to/yt-<videoId>.<lang>.clean.txt
TITLE=<video title>
CHANNEL=<channel name>
UPLOAD_DATE=YYYYMMDD
LANG=<resolved language code>
```

**Failure — one line:**

```
ERROR=<RATE_LIMITED|NO_CAPTIONS|BAD_URL|NETWORK|UNKNOWN>
```

with human-readable details on stderr / in the agent's prose.

## Flow

### 1. Try the VTT path

Spawn the `utilities-youtube-transcript-vtt` sub-agent via the Agent tool.

Prompt template:

> Download the transcript for this YouTube video using the shared shell script.
>
> **URL:** `<youtube-url>`
> **LANG:** `<lang or "en">`
>
> Report back in the shared contract — either the five `KEY=VALUE` lines on
> success, or one `ERROR=...` line on failure.

Parse the agent's final block.

- If it begins with `TRANSCRIPT_PATH=` → **done.** Echo the five lines to the user
  and stop.

### 2. On `ERROR=RATE_LIMITED` only, fall back to Playwright

Spawn the `utilities-youtube-transcript-playwright` sub-agent via the Agent tool.

Prompt template:

> The VTT path failed with HTTP 429 (YouTube rate-limited yt-dlp). Drive the
> MCP Playwright browser to scrape the transcript directly.
>
> **URL:** `<youtube-url>`
> **LANG:** `<lang or "en">`
>
> Open a new tab (never replace an existing one), open the watch page, click
> "Show transcript", scrape the segments, normalize timestamps to `HH:MM:SS`,
> and write the same cache files the VTT path would have written:
>
> - `tmp/transcripts/yt-<videoId>.<lang>.clean.txt`
> - `tmp/transcripts/yt-<videoId>.meta.tsv`
>
> Then report in the shared contract.

Parse the agent's final block.

- Success → echo the five lines. The cache is now populated, so future runs hit
  the VTT path immediately.
- `ERROR=...` → surface both agents' errors to the user and stop. Do not retry
  in a loop.

### 3. On any other ERROR — do not fall back

If the VTT agent returns `ERROR=NO_CAPTIONS`, `ERROR=BAD_URL`, `ERROR=NETWORK`,
or `ERROR=UNKNOWN`, surface it to the user. Playwright is not a universal
"try harder" — it can't fix a video that genuinely has no captions, and there's
no point opening a browser if the URL is malformed.

## Notes for the implementer

- **Cache compatibility.** Both sub-agents write to the same paths under
  `tmp/transcripts/`. After a successful Playwright run, calling the skill again
  on the same URL will hit the cache via the VTT agent — no Playwright, no
  network.
- **No retries inside the skill.** Each sub-agent runs once. If both fail, the
  user gets a clear two-step error report and decides what to do.
- **No file rewrites.** The skill never touches the transcript file itself; the
  sub-agents own that.
