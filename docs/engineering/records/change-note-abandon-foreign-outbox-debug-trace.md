---
schemaVersion: 1
id: change-note-abandon-foreign-outbox-debug-trace
revision: 1
type: change-note
status: accepted
title: Abandon Foreign-Session Outbox 404s And Emit Public-Safe Traces
repository: interview-arc-live
capabilityIds: ["hosted-practice-authority","system-design-room"]
createdAt: 2026-08-17
reconstructed: false
confidence: verified
unknowns: []
modules: ["hosted-practice-session","system-design-room-model"]
interfaces: ["hosted-practice-session","live-debug-trace"]
seams: ["outbox-to-receipt-recovery","hosted-today-to-local-coordinator"]
adapters: []
relatedRecords: ["architecture-review-hosted-practice-authority@1"]
decisions: ["0009-authoritative-hosted-practice-session"]
incidents: []
features: []
capabilities: ["abandon-foreign-outbox","public-safe-debug-trace"]
amends: []
supersedes: []
learningRefs: []
sources: [{"label":"Issue #72","url":"https://github.com/Vinosaamaa/interview-arc-live/issues/72","kind":"issue"},{"label":"Issue #19","url":"https://github.com/Vinosaamaa/interview-arc-live/issues/19","kind":"issue"},{"label":"Pull request #74","url":"https://github.com/Vinosaamaa/interview-arc-live/pull/74","kind":"pull-request"}]
verification: {"state":"verified","evidenceRefs":["issue:72","issue:19","pull-request:74"]}
visibility: public-safe
publicationEligibility: eligible
issue: 72
pr: 74
release: null
run: null
---
# Abandon Foreign-Session Outbox 404s And Emit Public-Safe Traces

A previous room can leave a prepared mutation in the private outbox. After relaunch the holder session is new, so receipt lookup 404s. ADR 0009 forbids replaying that body because it would rewrite the old fence. The previous client marked `recoveryRequired(receipt_not_found)` and returned before creating the local coordinator, so Board claimed the room was still restoring and Record stayed disabled.

## Change

`HostedPracticeSession.recover` now removes a foreign-session row when the receipt is `receipt_not_found`, continues the drain, and lets `open()` acquire a fresh lease. Same-session 404s still receipt-then-replay. If hosted connection is recovery-required or offline but Today already has an activity, `SystemDesignRoomModel.open` still binds the local coordinator. Record remains gated on a writable lease.

`LiveDebugTrace` writes allow-listed command, phase, result-code, and count fields to the `app.interviewarc.live` unified log. Tokens, transcripts, audio, private IDs, and paths are rejected.
