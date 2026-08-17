# Interview Arc Live Agent Instructions

Read `README.md`, `CONTEXT.md`, relevant ADRs under `docs/adr/`, and
`docs/agents/issue-lifecycle.md` before changing this repository.

Interview Arc Live is a separate experimental native macOS technical mock-
interview application. It must not depend on Interview Arc Voice running or
share Voice's queues, credentials, storage, preferences, hotkeys, or recorder
ownership. The sibling `interview-arc` repository owns hosted Interview Arc
state and APIs; `interview-arc-voice` owns the system-wide dictation client.

Do not create or change a thread Goal unless the user explicitly asks.

## Product invariants

- One `InterviewRoomSession` is bound to one Interview Arc activity.
- A Candidate Turn is one logical answer, even when it contains multiple audio
  segments or working pauses.
- Silence may finalize a segment; it never commits a Candidate Turn by itself.
- `Hand off` is always available. Cue Only, Patient Auto, and Manual remain
  explicit turn-taking modes.
- The first semantic endpoint Adapter is Groq `openai/gpt-oss-20b`. Do not add
  SmartTurn or OpenAI Realtime without a new approved issue and ADR.
- Preserve every nonempty best Groq transcript candidate verbatim with an
  explicit quality state. Never fabricate missing speech.
- Each Interviewer Turn owns one canonical `displayMarkdown`/`spokenText` pair.
- The Session Manifest is canonical. Combined audio is a derived export.
- Keep credentials in a Live-specific Keychain service and runtime data under
  a Live-specific Application Support root. Never commit credentials, audio,
  transcripts, model caches, private IDs, personal paths, or personal contact
  information.

## Architecture

Use the vocabulary and process from `improve-codebase-architecture`:

- Prefer a deep Module: high leverage behind a small Interface.
- The Interface is the test surface; test observable behavior through it.
- Apply the deletion test before extracting a Module.
- Introduce a Seam only when at least two Adapters are real.
- Optimize for locality: ordering, recovery, and invariants belong in the
  Module that owns them, not in every caller.
- Do not split files into shallow pass-through Modules or expose state mutators
  merely to make tests easy.

Record new domain terms in `CONTEXT.md`. Record durable architectural choices
as ADRs instead of duplicating narrative across guides.

## Source control and verification

- Every product change starts with an issue and uses a feature branch/PR.
- Link PRs with `Refs #<issue>`; merge does not close an issue automatically.
- Preserve unrelated dirty files and never commit generated credentials,
  recordings, transcripts, model artifacts, or local session state.
- Run local `swift test` when a compatible full Xcode/XCTest toolchain is
  available. A CLT-only Fastlane may use focused build/typecheck, JS/runtime,
  and headed-app proof instead; do not install full Xcode solely for local
  XCTest. Hosted XCTest must pass before merge.
- Recording, transcription, persistence, privacy, synchronization, signing,
  and recovery changes use the Reliability lane.
- Do not merge, install, or release without explicit user authorization.

## Fastlane

When the user says `fastlane`, `fast fix`, `fast iteration`, or explicitly asks
to skip unnecessary work, read and follow `docs/agents/fastlane.md`. Prove UI
and bundled-web fixes in one exact disposable app before spending a hosted CI
run. Fastlane shortens the feedback loop; it never weakens the Reliability,
privacy, destructive-action, authorization, or release-integrity rules above.

## Agent skills

### Issue tracker

Issues and PRDs live in GitHub Issues. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the five canonical triage labels. See `docs/agents/triage-labels.md`.

### Domain docs

This is a single-context repository with `CONTEXT.md` and `docs/adr/`. See
`docs/agents/domain.md`.
