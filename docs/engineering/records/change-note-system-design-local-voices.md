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
unknowns: ["Hosted XCTest, exact Metal package, physical microphone and interactive controls pending"]
modules: ["local-speech-adapter", "interviewer-speech-coordinator", "segment-speech-coordinator", "system-design-room"]
interfaces: ["interviewer-speech-provider", "interviewer-provider"]
seams: ["session-to-interviewer-speech", "session-to-interviewer-runtime"]
adapters: ["qwen3-tts", "kokoro", "codex-app-server"]
relatedRecords: ["change-note-codex-provider-readiness@1"]
decisions: ["0005-codex-app-server-private-runtime", "0006-local-interviewer-speech", "0010-default-continuous-conversation"]
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
pr: 100
release: null
run: null
---
# System Design speech lifecycle and selectable local voices

This is one integrated System Design delivery, including the recurring Codex blocker, provider-neutral AI boundary, local voice selection, and session lifecycle fixes. It is not ready for merge or installation until the remaining end-to-end checks are recorded below.

## Behavior

The Mara menu selects Qwen or Kokoro independently of the AI provider. Qwen remains the default; selection survives relaunch. Each engine has its own explicit, verified model download and scoped removal. Kokoro's English af_heart voice, weights, and pronunciation assets total 336,759,320 bytes. Existing Qwen receipts and model paths remain valid.

Switching joins model preparation/cancellation and current synthesis before releasing the old model. Saved WAVs and their attempt provenance stay immutable; a later Generate/Retry records the selected engine. A replay waiting for validation cannot restart after Stop or switching.

The opening greeting previously completed before speech attached, causing it to be treated as historical audio and remain silent. Speech now attaches before the new opening response and observes that response normally; reopening history still never auto-plays it. End disarms continuous input and joins speech before committing session completion, without discarding the transcript or prior recordings.

Successful Groq and hosted-token Keychain reads are reused in actor-local memory. Background transcription, endpoint classification, lease requests, and token fingerprints no longer reopen Keychain after that successful read. Save, replacement, until-quit override, and removal invalidate the previous cached value; save verification and rollback still access the real backend. A new store reads Keychain again, so external Keychain changes require reopening the app. Keychain access controls remain unchanged.

Automatic handoff now uses the same delivery path as manual handoff: the reply is
spoken and the candidate/interviewer text pair is synchronized to the website.
Pair writes serialize, retries preserve local evidence, and recovery does not
repeat speech. Capture checks the hosted writer before side effects and starts
the activity timer after durable capture authorization. Website storage covers
completed text pairs; standalone opening greetings, source recordings, TTS WAVs,
board drafts, and private notes remain local in this application flow.

Recording continues while previous segments transcribe in order. Acoustic
boundaries queue during local finalization instead of being dropped; unresolved
segments prevent premature AI handoff. Quit joins transcription and preserves
active audio; End quiesces input before hosted completion. The same acoustic tap
now supplies detection and private AAC recording, including bounded onset audio.
Permission denial and startup errors are visible. Pause has an explicit Resume
control and truthful paused status in full and compact rooms.

## Implementation

`InterviewArcLiveLocalSpeechAdapter` deepens the existing model store and bounded speech implementation with two real model loaders. Qwen retains its joined upstream streaming handle. Kokoro uses bounded text chunks and an owned MLX task. The small vendored MIT English pronunciation module excludes the upstream automatic global-cache downloader; exact source and license receipts are included. No model weights, audio, transcripts, or credentials are committed.

A compile-time diagnostic build can open an isolated local room for headed verification. Release builds retain the hosted activity binding and do not expose this path.

## Verification matrix

- AI: real authenticated Codex 0.153.4 synthetic response passed; the version gate is absent.
- Native build: the complete application including board-aware AI built successfully in 152.94 seconds; updated Core strict-concurrency compilation and the dual-engine adapter typecheck also passed.
- Regression coverage added: persisted engine choice, exact Kokoro allowlist, non-Qwen model receipts, bounded Unicode text, preserved audio and provenance after switching, joined producer cancellation, delayed replay cancellation, opening speech versus restore, and End during synthesis.
- Real local voices: Qwen and Kokoro each passed synthesis, finite PCM/WAV validation, playback and Stop on an M1 Pro. For the fixed short phrase, Qwen first audio was 4,201 ms and total generation 10,591 ms; Kokoro first audio and total generation were 7,408 ms. These used the existing Metal resource with development binaries, not a release-equivalent package.
- Real Groq endpoint: the automatic Hand off smoke passed on a diagnostic rerun. One earlier invariant failure had insufficient diagnostics; its cause remains unknown. The helper now emits bounded stage/category diagnostics without payloads or credentials.
- Board context: found and fixed the missing AI diagram path. Explicitly attached immutable revisions now cross the provider-neutral request, with a 256 KiB limit enforced before answer commit. Unattached drafts and private notes remain excluded.
- Diagnostic isolation: a compiled probe reproduced macOS normalization of `/private/tmp` to `/tmp`. Both paths now use identical resolution, invalid roots fail closed, and the compiled probe confirms the intended root.
- Connected component flow (explicit speech observation in the harness): a synthetic recording passed through the production Groq transcriber, floor hold, real board-aware Codex reply, automatic Kokoro speech, Qwen replacement/retry, replay of the prior Kokoro WAV, mute, End during active generation, and file-backed session/notes/board/audio recovery. This did not exercise microphone capture or a hosted activity.
- Board: packaged WKWebView editor runtime passed at widths 780, 992, and 1280, including native bridge state and canonical document retention; exact assets/offline policy/resource notices/icon checks passed.
- Native room: the actual System Design room model opened with real AI and speech, switched engines, and rendered at 992 and 1280 pixels. Read-only hosted Today access also passed. Neither check created or modified a hosted practice activity.
- Credential regression coverage: repeated requests reuse one successful backend read, fresh stores reauthorize, replacement/removal discard the cache, failed save verification reloads durable state, and missing/denied reads remain retryable. A standalone runtime check compiled from the actual stores passed these cases with synthetic backends and no OS Keychain access. The complete native app rebuilt in 36.61 seconds. Hosted XCTest remains pending.
- Automatic application wiring: a standalone runner using the actual room model,
  coordinators, speech store, and hosted outbox passed automatic opening/reply
  playback, one website pair, timer startup, writer denial, outbox recovery,
  replay deduplication, overlapping capture/transcription, Pause/Resume, and Quit
  joining both STT and a delayed AI response with its final website save.
  Audio events, STT/AI/TTS, and hosted transport were synthetic; it did not read
  Keychain, open a physical microphone, or write a real hosted activity.
- Shared audio input: synthetic PCM passed through the production detector,
  recorder, AAC encoder, private file store, and integrity inspector. All 21,504
  input frames survived delayed startup and decoded successfully. Denied
  permission, Pause during permission startup, and the bounded onset buffer also
  passed without physical microphone access.
- Native Automatic-mode views rendered successfully at 1280 and 992 pixels and
  in the compact room, using synthetic session data. Visual review confirmed
  Pause/Resume, legible paused status, and hands-free instructions. The final
  complete native build passed in 108.69 seconds.
- Hosted run 34174412565 built the package and tests successfully, then found
  seven assertion failures: temporary-path aliases (two), Kokoro chunk whitespace
  preservation (one), and stale Codex-specific presentation expectations (four).
  Fixes are included; local actual-module checks passed path aliases and text
  preservation. A new exact-head hosted result is still required.
- Pending: hosted XCTest and Metal package; headed microphone and interaction checks. Native UI automation timed out and macOS denied fallback accessibility access. These remain verification blockers, not inferred successes.

## Execution ledger

2026-09-07: combined the AI fix and voice implementation into issue #99 after the owner requested one PR with multiple commits. Native dependency compilation was bounded to two jobs after memory pressure. The full AI application build completed in 553.33 seconds. A separate Swift 6 typecheck of the real dual-engine MLX adapter passed. Exact per-action Pacific timestamps and provider-reported usage were not instrumented and are unknown. No merge, install, release, or cleanup occurred. The first Engineering policy run rejected an overlong compact summary, then all 32 policy tests passed after correction. Earlier source runs were superseded by necessary isolation, board-context, and credential fixes. The automatic-mode audit then reproduced missing voice/website delivery and dropped resumed speech while STT was pending; application-level synthetic regressions now exercise those paths. The repeated password prompt report exposed per-request Keychain reads as well as separately built diagnostic identities; synthetic regression checks verified the process-memory reuse fix without requesting OS credentials.

## Risks and rollback

Local models require an initial download and Apple Silicon/Metal support. Kokoro is English-only in this slice and uses a fixed voice; it is not a voice-cloning feature. Runtime testing must establish actual audio and interruption behavior on the target Mac. Revert the voice/lifecycle commits to restore the original Qwen-only path; previously stored WAVs remain portable.
