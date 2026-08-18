---
schemaVersion: 1
id: adr-live-0010-default-continuous-conversation
revision: 1
type: adr
status: accepted
title: Default new Live sessions to durable Continuous Conversation
repository: interview-arc-live
capabilityIds: ["continuous-conversation","floor-hold","interview-room-session"]
createdAt: 2026-08-17
reconstructed: false
confidence: high
unknowns: ["Runtime implementation and installed audio verification remain pending under issue #90."]
modules: ["interview-room-session","segment-speech-coordinator","endpoint-grace","interviewer-speech-coordinator","room-presentations"]
interfaces: ["turn-mode","floor-hold","continuous-conversation-state"]
seams: ["candidate floor ↔ local acoustic segmentation","durable segment evidence ↔ semantic endpoint evaluation","interviewer playback ↔ candidate capture re-arming"]
adapters: ["local candidate audio adapter","Groq transcription and endpoint adapters","local interviewer speech adapter"]
relatedRecords: ["adr-live-0004-durable-segmented-speech@1","feature-retrospective-live-issue-11@1"]
decisions: ["default-continuous-conversation","durable-floor-hold","first-shipment-half-duplex"]
incidents: []
features: ["continuous-conversation","floor-hold"]
capabilities: ["automatic-local-speech-segmentation","semantic-automatic-hand-off","long-answer-floor-hold"]
amends: []
supersedes: []
learningRefs: []
sources: [{"label":"Issue #90","url":"https://github.com/Vinosaamaa/interview-arc-live/issues/90","kind":"issue"},{"label":"Pull request #91","url":"https://github.com/Vinosaamaa/interview-arc-live/pull/91","kind":"pull-request"},{"label":"ADR 0004","url":"https://github.com/Vinosaamaa/interview-arc-live/blob/main/docs/adr/0004-durable-segmented-speech.md","kind":"documentation"}]
verification: {"state":"not-recorded","evidenceRefs":[]}
visibility: public-safe
publicationEligibility: eligible
issue: 90
pr: 91
release: null
run: null
---

# Default new Live sessions to durable Continuous Conversation

New Interview Room Sessions default to a half-duplex Continuous Conversation
mode. Live automatically arms local capture only during Candidate Floor,
durably segments and transcribes speech, evaluates the accumulated answer, and
uses Endpoint Grace plus the canonical at-most-once Hand off. Restored Sessions
preserve their stored Turn Mode.

A durable Floor Hold suppresses automatic completion across long pauses and
multiple Segments. Send answer releases that hold only after active Segment
evidence is durable, then invokes the same canonical Hand off.

The first shipment does not listen through interviewer TTS or infer a
Candidate Turn from speech over playback. Autonomous barge-in and full-duplex
audio remain separate decisions.
