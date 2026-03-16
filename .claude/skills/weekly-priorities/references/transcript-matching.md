# Transcript Matching Rules

How to find and match Google Drive transcripts to calendar events.

## Search Patterns

For each calendar event, search Google Drive using multiple naming patterns:

1. `searchGoogleDocs(searchQuery="<event summary> Transcript", searchIn="name", maxResults=10)`
2. `searchGoogleDocs(searchQuery="<event summary> Transcription", searchIn="name", maxResults=10)`
3. If the event summary contains brackets like `[Project]`, also try without the brackets.

## Matching Logic

- **Fuzzy-match** event summary against document name — exact match is not required.
- **Date tolerance:** Document date should be within 1 day of the event date (transcripts sometimes carry the next day's date).
- **Multiple matches:** If several transcripts match one event, pick the one with the closest date match.

## Downloading

For each matched transcript:

1. `readGoogleDoc(documentId=<id>, format="text")`
2. Save to `./weekly-priorities/raw/<YYYY-MM-DD>-<event-slug>.txt`

## Reporting

After matching, report to the user:

```
Transcripts found: <Y> out of <N> events

Missing transcripts for:
- <event name> (<date>)
- <event name> (<date>)

Proceeding with <Y> transcripts.
```

## Error Handling

If `readGoogleDoc` fails for a specific transcript, log it in the "missing transcripts" report and continue with the rest. One failed download should not abort the entire flow.
