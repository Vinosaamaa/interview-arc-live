---
schemaVersion: 1
id: adr-live-0001-separate-live-application
revision: 1
type: adr
status: accepted
title: Build the standalone system-design session foundation
repository: interview-arc-live
capabilityIds: ["live-adr-0001-separate-live-application"]
createdAt: 2026-08-09
reconstructed: true
confidence: high
unknowns: ["Attachment bodies and workflow logs were not quoted.","Sensitive source values and nonessential risky evidence links were omitted from this reconstructed record."]
modules: ["Sources:InterviewArcLive","Sources:InterviewArcLiveCore"]
interfaces: [".github/workflows/swift.yml"]
seams: ["room presentation ↔ deep session domain","reviewed tree ↔ packaged macOS artifact"]
adapters: ["Sources/InterviewArcLive/InterviewArcLiveApp.swift","Sources/InterviewArcLive/SystemDesignRoomModel.swift","Sources/InterviewArcLive/SystemDesignRoomView.swift","Sources/InterviewArcLiveCore/FileSessionManifestStore.swift","Sources/InterviewArcLiveCore/GroqEndpointClassifier.swift","Sources/InterviewArcLiveCore/InterviewRoomSession.swift"]
relatedRecords: []
decisions: []
incidents: []
features: []
capabilities: ["live-adr-0001-separate-live-application"]
amends: []
supersedes: []
learningRefs: []
sources: [{"label":"Pull request #4","url":"https://github.com/Vinosaamaa/interview-arc-live/pull/4","kind":"pull-request"}]
verification: {"state":"verified","evidenceRefs":["pull-request:4","head-commit:46cc9c2932072db8a6b57a4fc63223311392933e","merge-commit:7f7b6d9ce7b04173509e177d2591b49dbb33fe45"]}
visibility: public-safe
publicationEligibility: eligible
issue: 3
pr: 4
release: null
run: null
---

# Build the standalone system-design session foundation

Evidence-indexed reconstruction of pull request #4. This record preserves the reviewed public-safe module, interface, seam, and adapter inventory from that change. It does not reconstruct unavailable motivation, success, attachment bodies, workflow logs, or deployment receipts.

## Historical limits

Dependent receipts link this exact revision. Unrecorded impact remains unknown.
