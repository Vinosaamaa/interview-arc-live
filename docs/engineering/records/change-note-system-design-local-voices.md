---
schemaVersion: 1
id: "change-note-system-design-local-voices"
revision: 1
type: "change-note"
status: "accepted"
title: "Complete System Design speech lifecycle with selectable local engines"
repository: "interview-arc-live"
capabilityIds: ["interview-room-session"]
createdAt: "2026-09-07"
reconstructed: false
confidence: "verified"
unknowns: ["Hosted XCTest, Metal package, dual-engine runtime and headed session verification pending"]
modules: ["local-speech-adapter", "interviewer-speech-coordinator", "segment-speech-coordinator", "system-design-room"]
interfaces: ["interviewer-speech-provider", "interviewer-provider"]
seams: ["session-to-interviewer-speech", "session-to-interviewer-runtime"]
adapters: ["qwen3-tts", "kokoro", "codex-app-server"]
relatedRecords: ["change-note-codex-provider-readiness@1"]
decisions: ["0005-codex-app-server-private-runtime", "0006-local-interviewer-speech"]
incidents: []
features: ["selectable-local-voices"]
capabilities: ["system-design-interview"]
amends: []
supersedes: []
learningRefs: []
sources: [{"label": "Issue #99", "url": "https://github.com/Vinosaamaa/interview-arc-live/issues/99", "kind": "issue"}, {"label": "Issue #58", "url": "https://github.com/Vinosaamaa/interview-arc-live/issues/58", "kind": "issue"}]
verification: {"state": "verified", "evidenceRefs": ["build:swift6-local-speech-typecheck", "build:swift6-core-strict-concurrency", "runtime:synthetic-codex-0.153.4-response"]}
visibility: "public-safe"
publicationEligibility: "eligible"
issue: 99
pr: null
release: null
run: null
---
# System Design speech lifecycle and selectable local voices

This is one integrated System Design delivery, including the recurring Codex blocker, provider-neutral AI boundary, local voice selection, and session lifecycle fixes. It is not ready for merge or installation until the remaining end-to-end checks are recorded below.

## Behavior

The Mara menu selects Qwen or Kokoro independently of the AI provider. Qwen remains the default; selection survives relaunch. Each engine has its own explicit, verified model download and scoped removal. Kokoro's English af_heart voice, weights, and pronunciation assets total 336,759,320 bytes. Existing Qwen receipts and model paths remain valid.

Switching joins model preparation/cancellation and current synthesis before releasing the old model. Saved WAVs and their attempt provenance stay immutable; a later Generate/Retry records the selected engine. A replay waiting for validation cannot restart after Stop or switching.

The opening greeting previously completed before speech attached, causing it to be treated as historical audio and remain silent. Speech now attaches before the new opening response and observes that response normally; reopening history still never auto-plays it. End disarms continuous input and joins speech before committing session completion, without discarding the transcript or prior recordings.

## Implementation

`InterviewArcLiveLocalSpeechAdapter` deepens the existing model store and bounded speech implementation with two real model loaders. Qwen retains its joined upstream streaming handle. Kokoro uses bounded text chunks and an owned MLX task. The small vendored MIT English pronunciation module excludes the upstream automatic global-cache downloader; exact source and license receipts are included. No model weights, audio, transcripts, or credentials are committed.

A compile-time diagnostic build can open an isolated local room for headed verification. Release builds retain the hosted activity binding and do not expose this path.

## Verification matrix

- AI: real authenticated Codex 0.153.4 synthetic response passed; the version gate is absent.
- Native build: the AI-only application built successfully; updated Core strict-concurrency compilation and the dual-engine adapter typecheck passed.
- Regression coverage added: persisted engine choice, exact Kokoro allowlist, non-Qwen model receipts, bounded Unicode text, preserved audio and provenance after switching, joined producer cancellation, delayed replay cancellation, opening speech versus restore, and End during synthesis.
- Pending: hosted XCTest and Metal package; real Qwen/Kokoro synthesis and playback; headed microphone/transcription/board/hold/mute/recovery/End session checks. These remain release blockers, not inferred successes.

## Execution ledger

2026-09-07: combined the AI fix and voice implementation into issue #99 after the owner requested one PR with multiple commits. Native dependency compilation was bounded to two jobs after memory pressure. The full AI application build completed in 553.33 seconds. A separate Swift 6 typecheck of the real dual-engine MLX adapter passed. Exact per-action Pacific timestamps and provider-reported usage were not instrumented and are unknown. No merge, install, release, or cleanup occurred.

## Risks and rollback

Local models require an initial download and Apple Silicon/Metal support. Kokoro is English-only in this slice and uses a fixed voice; it is not a voice-cloning feature. Runtime testing must establish actual audio and interruption behavior on the target Mac. Revert the voice/lifecycle commits to restore the original Qwen-only path; previously stored WAVs remain portable.
