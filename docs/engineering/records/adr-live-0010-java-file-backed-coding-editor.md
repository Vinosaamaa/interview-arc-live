---
schemaVersion: 1
id: adr-live-0010-java-file-backed-coding-editor
revision: 1
type: adr
status: accepted
title: Java File-Backed Coding Editor
repository: interview-arc-live
capabilityIds: ["interview-room-session"]
createdAt: 2026-08-17
reconstructed: false
confidence: verified
unknowns: []
modules: ["coding-room-model","coding-source-store","leetcode-controller-client"]
interfaces: ["coding-harness-run","in-room-submit"]
seams: ["session-to-coding-source","live-to-leetcode-controller"]
adapters: ["java-nstextview-editor","leetcode-playwright-controller","leetcode-java-harness"]
relatedRecords: ["capability-dossier-deep-interview-room-session@1"]
decisions: ["0010-java-file-backed-coding-editor"]
incidents: []
features: ["java-first-coding-room"]
capabilities: ["warm-controller-preflight","in-room-submit"]
amends: []
supersedes: []
learningRefs: []
sources: [{"label":"Issue #69","url":"https://github.com/Vinosaamaa/interview-arc-live/issues/69","kind":"issue"},{"label":"Pull request #73","url":"https://github.com/Vinosaamaa/interview-arc-live/pull/73","kind":"pull-request"},{"label":"ADR 0010","url":"https://github.com/Vinosaamaa/interview-arc-live/blob/feature/69-coding-room/docs/adr/0010-java-file-backed-coding-editor.md","kind":"documentation"}]
verification: {"state":"verified","evidenceRefs":["issue:69","pull-request:73","adr:0010","test:CodingRoomModelTests"]}
visibility: public-safe
publicationEligibility: eligible
issue: 69
pr: 73
release: null
run: null
---
# Java File-Backed Coding Editor

Live's coding room is a parallel specialty projection of the same Interview Room Session. The work surface is one evolving Java file, not a Board and not a fake in-app judge.

## Decision

The editor is a native macOS NSTextView over that file. Java 21 is enabled; Python stays visible and disabled. Quick/Full invoke `scripts/leetcode-java-harness.mjs` directly, stream output, cancel the previous run on a later click, and may report only Locally verified. After the Java file loads, Warm Controller Preflight runs `ensure` then `navigate`. In-Room Submit calls the checked-in Playwright controller with a unique invocation ID, recovers `receipt` once if output is ambiguous, and retries only on a later explicit click. Hand off stays live. Live never copies `browser-profiles/leetcode-submitter`.
