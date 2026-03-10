---
name: os-hub-transcripts
description: >
  Find, download, and organize all meeting transcripts related to the OS Hub account.
  Trigger when user mentions OS Hub transcripts, opensupplyhub.org, "[OS Hub]" calendar events,
  or wants to download/organize OS Hub meeting transcripts.
---

# OS Hub Transcript Collector

Collect all OS Hub meeting transcripts from Google Calendar + Google Drive → download → split → organize locally.

**Strategy:** Minimize API calls. Fetch data, save locally, then process everything with a local script.

**Working directory:** `./os-hub-work/` (relative to project root)
**Output directory:** `./OS HUB Transcripts/`

## Step 1: Fetch calendar events → local JSONL

Search Google Calendar for OS Hub events. Save raw results locally.

1. Use `gcal_list_events(q="[OS Hub]", timeMin="2024-01-01T00:00:00", timeMax=<today>, maxResults=250)`.
   Paginate through ALL pages with `pageToken`. Save each response to `./os-hub-work/cal-page-*.json`.
2. Same with `gcal_list_events(q="opensupplyhub.org", ...)`. Save to `./os-hub-work/cal-osh-page-*.json`.
3. Extract events locally with jq:
   ```bash
   for f in ./os-hub-work/cal-*.json; do
     jq -c '.events[]? | {id: .id, summary: .summary, date: (.start.dateTime // .start.date)}' "$f"
   done > ./os-hub-work/all_events.jsonl
   ```
4. Deduplicate:
   ```bash
   sort -t'"' -k4,4 -u ./os-hub-work/all_events.jsonl > ./os-hub-work/all_events_deduped.jsonl
   ```

**Output:** `all_events_deduped.jsonl`

## Step 2: Extract unique meeting names (local only)

```bash
jq -r '.summary' ./os-hub-work/all_events_deduped.jsonl | sort | uniq -c | sort -rn > ./os-hub-work/meeting_names.txt
```

**Output:** `meeting_names.txt`

## Step 3: Search Google Drive → local JSONL

Run 3 searches to cover naming variations:
1. `searchGoogleDocs(searchQuery="[OS Hub] Transcript", searchIn="name", maxResults=50)`
2. `searchGoogleDocs(searchQuery="[OS Hub] Transcription", searchIn="name", maxResults=50)`
3. `searchGoogleDocs(searchQuery="OS Hub Transcript", searchIn="name", maxResults=50)`

Combine results. Deduplicate by document ID. Save to `./os-hub-work/transcript_docs.jsonl`:
```json
{"id":"<doc-id>","name":"<doc-title>"}
```

**Output:** `transcript_docs.jsonl`

## Step 4: Download all docs → raw text files

For EACH doc in `transcript_docs.jsonl`:
- `readGoogleDoc(documentId=<id>, format="text")` → save to `./os-hub-work/raw/<doc-id>.txt`

**Parallelize** using 5 Agent subagents, each handling a batch of ~10 docs.

If a doc fails, log to `./os-hub-work/errors.log` and continue.

**Output:** `./os-hub-work/raw/*.txt`

## Step 5: Create and run local processing script

Write `./os-hub-work/process-transcripts.ts` and execute with `npx tsx`.

The script must:

### 5a. Read inputs
- Read `transcript_docs.jsonl` for doc metadata
- Read each `./os-hub-work/raw/<id>.txt` file

### 5b. Parse and split transcripts
Each call in a transcript starts with this header pattern:
```
Topic: <meeting name>
Date: <human date>, <time> UTC
Transcription
```

For each raw file:
- Count occurrences of `/^Topic: /m` — if >1, it's a multi-call file
- Split at each `Topic:` boundary
- For each segment, extract:
  - **Meeting name** from `Topic: <name>` line
  - **Date** from `Date: <date string>` line → parse to `yyyy.mm.dd`

### 5c. Organize into folder structure
```
./OS HUB Transcripts/
  <call-name>/
    <yyyy.mm.dd>-<slug>.md
```

Rules:
- `<call-name>`: Strip `[OS Hub]` prefix, trim whitespace. E.g. `[OS Hub] Standup` → `Standup`
- `<slug>`: kebab-case of call name. E.g. `bizdev`, `sprint-planning`
- Each `.md` file content:
  ```markdown
  # <Meeting Name> — <yyyy.mm.dd>

  <transcript content>
  ```

### 5d. Run it
```bash
npx tsx ./os-hub-work/process-transcripts.ts
```

## Step 6: Report summary

Output:
- Total unique meeting names
- Total calendar events found
- Total transcript docs downloaded
- Total individual call transcripts extracted and saved
- Breakdown by call name
- Meetings with NO transcript found
- Errors encountered
