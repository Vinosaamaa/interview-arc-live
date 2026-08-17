---
schemaVersion: 1
id: adr-live-0004-durable-segmented-speech
revision: 1
type: adr
status: accepted
title: Capture and recover segmented candidate speech
repository: interview-arc-live
capabilityIds: ["live-adr-durable-segmented-speech"]
createdAt: 2026-08-09
reconstructed: true
confidence: high
unknowns: ["Attachment bodies and workflow logs were not quoted.","Sensitive source values and nonessential risky evidence links were omitted from this reconstructed record."]
modules: ["Sources:InterviewArcLive","Sources:InterviewArcLiveCore","Sources:InterviewArcLiveVoiceAdapter"]
interfaces: [".github/workflows/swift.yml"]
seams: ["room presentation ↔ deep session domain","Live segmented speech ↔ exact VoiceCore adapter","reviewed tree ↔ packaged macOS artifact"]
adapters: ["Sources/InterviewArcLive/CandidateSegmentPresentation+Core.swift","Sources/InterviewArcLive/CandidateSegmentPresentation.swift","Sources/InterviewArcLive/GroqCredentialSetupView.swift","Sources/InterviewArcLive/InterviewArcLiveApp.swift","Sources/InterviewArcLive/SystemDesignRoomModel.swift","Sources/InterviewArcLive/SystemDesignRoomView.swift"]
relatedRecords: []
decisions: []
incidents: []
features: []
capabilities: ["live-adr-durable-segmented-speech"]
amends: []
supersedes: []
learningRefs: []
sources: [{"label":"Pull request #6","url":"https://github.com/Vinosaamaa/interview-arc-live/pull/6","kind":"pull-request"}]
verification: {"state":"verified","evidenceRefs":["pull-request:6","head-commit:e919018fdaa519f0cf1949e9e48c5de4de1600d4","merge-commit:502a1cfd114ccd8ae2d7118b59fcafa49753e5a0"]}
visibility: public-safe
publicationEligibility: eligible
issue: 5
pr: 6
release: null
run: null
---

# Capture and recover segmented candidate speech

Evidence-indexed reconstruction of pull request #6. This record preserves the reviewed public-safe module, interface, seam, and adapter inventory from that change. It does not reconstruct unavailable motivation, success, attachment bodies, workflow logs, or deployment receipts.

## Historical limits

Dependent receipts link this exact revision. Unrecorded impact remains unknown.
