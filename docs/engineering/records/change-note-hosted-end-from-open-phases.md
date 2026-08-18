---
schemaVersion: 1
id: change-note-hosted-end-from-open-phases
revision: 1
type: change-note
status: accepted
title: End A Hosted Interview From Candidate Floor Without Silent No-Op
repository: interview-arc-live
capabilityIds: ["hosted-practice-authority","interview-room-session"]
createdAt: 2026-08-17
reconstructed: false
confidence: verified
unknowns: []
modules: ["interview-room-session","system-design-room-model"]
interfaces: ["interview-room-command","hosted-practice-session"]
seams: ["room-to-hosted-finish"]
adapters: ["full-presentation"]
relatedRecords: ["change-note-abandon-foreign-outbox-debug-trace@1","architecture-review-hosted-practice-authority@1"]
decisions: ["0009-authoritative-hosted-practice-session"]
incidents: []
features: []
capabilities: ["hosted-activity-finish"]
amends: []
supersedes: []
learningRefs: []
sources: [{"label":"Issue #72","url":"https://github.com/Vinosaamaa/interview-arc-live/issues/72","kind":"issue"},{"label":"Issue #1","url":"https://github.com/Vinosaamaa/interview-arc-live/issues/1","kind":"issue"},{"label":"Pull request #92","url":"https://github.com/Vinosaamaa/interview-arc-live/pull/92","kind":"pull-request"}]
verification: {"state":"verified","evidenceRefs":["test:InterviewRoomSessionTests.testFinishCompletesFromCandidateFloorWhenNoCaptureIsInFlight","test:SystemDesignRoomFinishTests.testFinishInterviewReportsWhenTheLocalRoomIsNotOpen","pull-request:92"]}
visibility: public-safe
publicationEligibility: eligible
issue: 72
pr: 92
release: null
run: null
---
# End A Hosted Interview From Candidate Floor Without Silent No-Op

End returned false with no message when the local coordinator was missing, and Core `finish` only accepted `.ready` or `.interviewerTurn`. A restored YOU-turn room therefore looked like End did nothing. Hosted finish also ran after local completion, so a hosted gate could leave the local room looking ended while Today stayed open.

## Change

Core `finish` now completes from candidate floor or interviewer processing when no capture is in flight. The room reports why End cannot run, including an unopened coordinator. Hosted `finish` is attempted first while the writer lease is writable; local completion follows only after that hosted command succeeds. In-flight recording still fail-closes. Hosted result and pair gates remain the Interview Arc contract and now surface their existing public-safe copy.
