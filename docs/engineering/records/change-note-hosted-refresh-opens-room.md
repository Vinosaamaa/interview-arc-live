---
schemaVersion: 1
id: change-note-hosted-refresh-opens-room
revision: 1
type: change-note
status: accepted
title: Open The System Design Room After Hosted Today Refresh
repository: interview-arc-live
capabilityIds: ["hosted-practice-authority","system-design-room"]
createdAt: 2026-08-17
reconstructed: false
confidence: verified
unknowns: []
modules: ["system-design-room-model"]
interfaces: ["hosted-practice-controller"]
seams: ["hosted-today-to-local-coordinator"]
adapters: []
relatedRecords: ["capability-dossier-deep-interview-room-session@1"]
decisions: ["0009-authoritative-hosted-practice-session"]
incidents: []
features: []
capabilities: ["hosted-refresh-binds-room"]
amends: []
supersedes: []
learningRefs: []
sources: [{"label":"Issue #19","url":"https://github.com/Vinosaamaa/interview-arc-live/issues/19","kind":"issue"},{"label":"Pull request #67","url":"https://github.com/Vinosaamaa/interview-arc-live/pull/67","kind":"pull-request"}]
verification: {"state":"verified","evidenceRefs":["issue:19","pull-request:67"]}
visibility: public-safe
publicationEligibility: eligible
issue: 19
pr: 67
release: null
run: null
---
# Open The System Design Room After Hosted Today Refresh

Launch with no System Design activity returned before creating the local coordinator. Refreshing Today after an activity appeared left that coordinator nil, so the room stayed empty until quit.

## Change

`refreshHostedAuthority` now uses the same bind rule as a later integration-token save: when hosted Today has an activity and the local coordinator is missing, `open()` runs. An existing coordinator is left in place.
