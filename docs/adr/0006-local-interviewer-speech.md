# ADR 0006: Keep local interviewer speech derived, explicit, and recoverable

Status: Accepted

## Context

An Interviewer Turn must remain useful as exact displayed text even when a
large local model is absent, generation fails, playback is stopped, or the app
relaunches. Local TTS adds model installation, streaming PCM, private WAV
storage, cancellation, and crash windows; distributing those rules across
SwiftUI, MLX callbacks, and AVAudioEngine would lose locality.

## Decision

Each newly persisted Interviewer Turn atomically creates one stable
Interviewer Utterance that references the Turn and a SHA-256 of its exact
`spokenText`. The Utterance never owns copied text. A retry creates a fresh
Synthesis Attempt under the same Utterance and retains prior selected audio
until replacement validation succeeds.

`InterviewRoomSession` owns stable identities, lifecycle validation, command
idempotency, monotonic Manifest revisioning, and authorization/outcome
persistence. `InterviewerSpeechCoordinator` is the deep orchestration Module:
it owns automatic eligibility, provider/playback single-flight, Stop/Mute,
stream validation, finalization order, and recovery. Provider, private WAV
storage, and playback are real Seams with production and deterministic test
Adapters. No MLX value, URL, filesystem path, or provider-specific voice type
crosses a Core Interface.

Automatic eligibility is process-local: only ready, unmuted Interviewer Turns
first observed after attach enter a FIFO, and each is durably authorized only
after the prior generation reaches a terminal outcome. Restored history never
enters that FIFO. Stop and Mute share one joined cancellation finalizer; it
cancels both the Core consumer and provider producer, stops output immediately,
and preserves the prepared model for an explicit Retry.

The production provider pins the reviewed `Vinosaamaa/mlx-audio-swift` fork at
commit `a228dc056c6b298a2f5aff7f10e3aed537577fa0`, based on upstream
`Blaizzy/mlx-audio-swift` v0.1.3 commit
`d302a5c6080d2bb97bae38c7418f82abb76013b6`. The fork adds a source-compatible,
joinable Qwen generation handle so Stop/Mute can await the actual MLX producer
before a retry owns the model. The provider also pins the immutable
`mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit` model revision
`049ef77fe8816b536193c0c25f9a214d17921282`. The `mara-v1` fingerprint includes
language, conditioning, max tokens, temperature, top-p, resolved top-k/min-p,
repetition penalty/context, and streaming interval. Tuning creates a new named
profile rather than mutating prior provenance.

Readiness inspection, restore, Retry, and app startup never download. The
first 1.838-GiB transfer requires explicit `userAuthorizedDownload`, verifies
the complete revision allowlist in sibling staging, and atomically promotes a
receipt-backed snapshot only after size/hash validation. Removal is scoped to
that public model revision and never touches Session Manifests or utterance
audio.

Generation streams only finite 24-kHz mono Float PCM, capped at 100 seconds,
through playback while writing a deterministic private partial WAV. A final
WAV is validated and atomically renamed before success can become durable.
Replay validates its full persisted identity, format, duration, byte count,
and SHA-256. Diagnostics retain only bounded identities and metrics, never
Turn text, audio, paths, credentials, or provider bodies.

Relaunch never downloads, regenerates, or auto-plays. Recovery may adopt a
valid deterministic final WAV for a still-authorized Attempt without provider
work; otherwise it discards partial output and records `interrupted`. Legacy
Manifests decode with empty Utterance history and may backfill pending
Utterances without speaking them.

## Consequences

Speech remains optional derived presentation instead of interview state. The
Session Manifest has additional lifecycle history and revisions, but a model,
storage, provider, or playback failure cannot erase or delay canonical Turns.
The installed package must carry and verify MLX runtime resources, while the
large model remains an explicit separately managed local asset. The installed
speech smoke projects the already manifest-verified `default.metallib` into its
private ephemeral working directory because its standalone helper is not hosted
by the application bundle; the production application continues loading the
canonical SwiftPM resource bundle from `Contents/Resources`.

## Selectable local engines (issue #99)

The owner requires both Qwen and Kokoro for comparison during actual practice. The application selects `LocalSpeechEngine` independently of `InterviewerProvider`. Qwen remains the default and retains its existing storage path, model revision, and `mara-v1` provenance. Kokoro uses `mlx-community/Kokoro-82M-bf16` revision `a71e4d38b236d968966a2002c4c895dbd12b1c3c`, the `af_heart` voice, English pronunciation, and fixed speed 1.0. Its combined allowlist is 336,759,320 bytes with a 1 GiB preparation budget.

The existing model store and bounded synthesis implementation now live in `InterviewArcLiveLocalSpeechAdapter`. Both engines use staged hash verification and atomic promotion. Only Qwen derives a tokenizer; Kokoro admits no extra runtime files. Kokoro pronunciation resources are pinned separately at `beshkenadze/kitten-tts-g2p` revision `9c692b92682d959d9013a9cfe6a49541997add18`, and every resource hash participates in the combined snapshot receipt.

The pinned MLX package's public Misaki processor only supports an automatic download to its global cache. Live vendors its 16 MIT-licensed English pronunciation source files, excluding that downloader, and supplies verified private resources through a local `TextProcessor`. This bounded downstream copy avoids changing a second repository or adopting a different MLX version. Source/license receipts ship in `KokoroEnglishG2PNOTICE.txt`; no weights are committed. Reconcile this copy when the dependency exposes a reviewed local-resource initializer.

Kokoro generates bounded text chunks on one owned task; cancellation joins the actual MLX work before releasing the model. `InterviewerSpeechCoordinator.replaceProvider` stops playback, joins synthesis, discards pending automatic eligibility, and unloads the previous model before selecting the replacement. Switching never downloads or replays history. Future attempts use the replacement provenance; earlier WAVs remain replayable through the existing player.
