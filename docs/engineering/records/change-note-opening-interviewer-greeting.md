---
schemaVersion: 1
id: change-note-opening-interviewer-greeting
revision: 1
type: change-note
status: accepted
title: Open Every System Design Session With A Specialist Greeting
repository: interview-arc-live
capabilityIds: ["interview-room-session"]
createdAt: 2026-08-17
reconstructed: false
confidence: verified
unknowns: []
modules: ["interview-room-session","system-design-room-model","codex-app-server-interviewer-runtime"]
interfaces: ["interviewer-runtime","interview-room-command"]
seams: ["session-to-interviewer-runtime","session-to-presentations"]
adapters: ["codex-app-server","full-presentation"]
relatedRecords: ["capability-dossier-deep-interview-room-session@1","adr-live-0005-codex-app-server-private-runtime@1"]
decisions: ["0005-codex-app-server-private-runtime"]
incidents: []
features: []
capabilities: ["opening-interviewer-turn"]
amends: []
supersedes: []
learningRefs: []
sources: [{"label":"Issue #77","url":"https://github.com/Vinosaamaa/interview-arc-live/issues/77","kind":"issue"},{"label":"Pull request #78","url":"https://github.com/Vinosaamaa/interview-arc-live/pull/78","kind":"pull-request"}]
verification: {"state":"verified","evidenceRefs":["issue:77","pull-request:78","test:InterviewRoomSessionTests.testOpeningInterviewerTurnPersistsWithoutCandidateThenGivesFloorWithoutAnotherRequest"]}
visibility: public-safe
publicationEligibility: eligible
issue: 77
pr: 78
release: null
run: null
---
# Open Every System Design Session With A Specialist Greeting

A fresh System Design room started in `.ready` and immediately called `giveCandidateFloor`. The Turnline stayed empty, the rail said YOUR FLOOR, and Mara never stated the prompt.

## Change

App `open()` now requests one Opening Interviewer Turn when the restored session is still `.ready` with empty turns. That turn is a normal Interviewer Turn with `replyToTurnID == nil`. Codex receives `kind: opening` and no candidate answer. After it persists, the room is `.interviewerTurn` and the candidate uses existing Give me the floor. Codex failure stays in `.interviewerProcessing` with empty turns until Retry interviewer. Core still allows `ready → giveCandidateFloor` so existing tests can skip opening.

Hosted `/live/v1` pairs remain candidate-then-interviewer. The Opening Turn is local and remains visible above later hosted pairs. An in-progress session that already has candidate turns is not rewritten.
