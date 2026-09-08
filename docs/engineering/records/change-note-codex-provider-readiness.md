---
schemaVersion: 1
id: "change-note-codex-provider-readiness"
revision: 1
type: "change-note"
status: "accepted"
title: "Use protocol readiness and a provider-neutral interviewer boundary"
repository: "interview-arc-live"
capabilityIds: ["interview-room-session"]
createdAt: "2026-09-07"
reconstructed: false
confidence: "verified"
unknowns: ["Hosted XCTest and installed application verification pending"]
modules: ["codex-app-server-interviewer-runtime", "system-design-room", "behavioral-room"]
interfaces: ["interviewer-provider", "interviewer-runtime"]
seams: ["session-to-interviewer-runtime"]
adapters: ["codex-app-server"]
relatedRecords: ["change-note-groq-keychain-codex-pin@1"]
decisions: ["0005-codex-app-server-private-runtime"]
incidents: []
features: []
capabilities: ["protocol-based-interviewer-readiness"]
amends: []
supersedes: []
learningRefs: []
sources: [{"label": "Issue #58", "url": "https://github.com/Vinosaamaa/interview-arc-live/issues/58", "kind": "issue"}]
verification: {"state": "verified", "evidenceRefs": ["runtime:synthetic-codex-0.153.4-response", "build:swift6-core-adapter-smoke"]}
visibility: "public-safe"
publicationEligibility: "eligible"
issue: 58
pr: 100
release: null
run: null
---
# Protocol readiness and interchangeable interviewer providers

The exact CLI comparison rejected Codex 0.153.4 before an interviewer request, despite its protocol supporting the existing adapter. Live now checks the executable, authenticated App Server handshake, isolated thread configuration, and canonical response directly. It never invokes a version command or maintains a version allowlist. Protocol and authentication failures still preserve the saved answer and require explicit retry.

Room readiness, errors, and response injection use the Core `InterviewerProvider` contract. A single application composition point selects Codex today. Future Pi, Cursor subscription, or other integrations implement the same contract; speech selection remains independent. No additional provider is implemented or billed automatically.

## Verification and delivery limits

Swift 6 strict-concurrency builds of the real Core, Codex adapter, and smoke executable passed. A synthetic authenticated System Design exchange using Codex 0.153.4 completed successfully in 8.45 seconds; no prompt, response, account, or credential values were logged. Regression fixtures now reject any version-command invocation and retain authentication, malformed protocol, tool isolation, and cancellation coverage. Hosted XCTest and installed UI verification remain pending; the installed application was not replaced.

## Execution ledger

2026-09-07: reproduced the exact-version rejection, removed the gate, extracted provider-neutral room contracts, compiled the native modules, and ran the synthetic response smoke. Exact per-action Pacific timestamps and provider usage were not instrumented and are unknown. The existing shared Swift module cache contains relocated precompiled headers; focused compilation used strict context hashes in that same cache.

## Risks and rollback

A future CLI may change its protocol; actual protocol validation will then report a recoverable failure. Revert this change to restore the former implementation, including its restrictive version gate. Merge, release, installation, and issue closure require their own authorization and receipts.
