---
schemaVersion: 1
id: change-note-behavioral-room-local-slice
revision: 1
type: change-note
status: accepted
title: Open A Local Behavioral Specialty Room
repository: interview-arc-live
capabilityIds: ["specialty-work-surfaces","interview-room-session"]
createdAt: 2026-08-17
reconstructed: false
confidence: high
unknowns: ["Hosted GitHub Actions compile and test results for the presentation-coordinator wiring were not available at authoring time."]
modules: ["session-manifest","behavioral-room-model","behavioral-work-surface","interview-room-presentation-coordinator"]
interfaces: ["activity-specialty","interview-room-session","interview-room-presented-specialty"]
seams: ["session-to-presentations"]
adapters: ["behavioral-room-view","compact-behavioral-room-view"]
relatedRecords: ["capability-dossier-deep-interview-room-session@1"]
decisions: []
incidents: []
features: []
capabilities: ["local-behavioral-room"]
amends: []
supersedes: []
learningRefs: []
sources: [{"label":"Issue #70","url":"https://github.com/Vinosaamaa/interview-arc-live/issues/70","kind":"issue"},{"label":"Pull request #71","url":"https://github.com/Vinosaamaa/interview-arc-live/pull/71","kind":"pull-request"},{"label":"Interview Arc issue #389","url":"https://github.com/Vinosaamaa/interview-arc/issues/389","kind":"issue"}]
verification: {"state":"not-recorded","evidenceRefs":[]}
visibility: public-safe
publicationEligibility: eligible
issue: 70
pr: 71
release: null
run: null
---
# Open A Local Behavioral Specialty Room

Live could present System Design only. This slice adds `ActivitySpecialty.behavioral` and a local Behavioral room that the presentation coordinator can show in the shared full/compact Interview Room without hosted `/live/v1` behavioral writes.

## Change

`ActivitySpecialty` now includes `behavioral`. `BehavioralRoomModel` owns a local Interview Room Session with specialty `.behavioral` and does not call hosted lease, turn-pair, or finish. The work surface is a Story kit (at most three candidates), project and resume kits bound by `projectId` / `sourceClaimId`, STARL coverage states rather than a score, and an explicit coached-discovery mode switch. The live sidecar has no preferred or model answer field. Hosted Pause/End remain disabled with an honest chip; local Hand off, record, and finish still use the existing session engine. Window menu item `Behavioral Room (local)` switches the shared presentation to Behavioral instead of opening a second window.
