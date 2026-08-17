# Decisions — conversational ledger

Choices made in conversation — what was chosen, why, and what was rejected —
extracted from task transcripts by the context archivist (`.claude/hooks/context.py`).
Append-only; newest at the bottom. A superseded entry is struck through, never
deleted.

## 2026-07-20 — The task implemented and live-tested a self-healing weekly LinkedIn stats pipeline, repaired the runner architecture, and merged the healed scrape and watchdog cleanup.

_transcript: 20260720-114324-f671ba95-i-want-also-to-create-make-the-workflow.md_

- Use the native `osx-arm64` package for the Mac Studio’s self-hosted GitHub Actions runner rather than retaining a persistent `arch -arm64` scraper wrapper; Peter chose the permanent reinstall after the old runner was proven to execute under Rosetta (2026-07-20T14:10:46Z).

## 2026-07-25 — The task created a timestamped transcript and a snapshot-driven article digest for a YouTube fundraising video after comparing frame-selection methods.

_transcript: 20260725-150058-15284ba4-the-linkedin-post-generation-i-need-two.md_

- For the mixed keynote-and-UI screencast, slide extraction used a hybrid approach: transcript sections determined narrative coverage, settled scene-cluster candidates supplied frames, and perceptual hashing removed repeats; uniform sampling missed brief visuals, raw scene detection produced duplicates or transitions, fixed transcript offsets were unreliable, and edge-density scoring required special handling for sparse summary slides because it favored dense UI (empirically compared and visually verified 2026-08-15T08:23:52Z).
- Speaker attribution used Soniox `stt-async-v5` for diarized turns followed by LLM inference from explicit transcript evidence, with confidence/evidence recorded, spelling normalized across modules, and unresolved speakers retained as `Speaker N`; this met the no-intervention preference without unsupported guesses (implemented and output-verified 2026-08-16T11:06:41Z).
