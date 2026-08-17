---
schemaVersion: 1
id: adr-live-0006-local-interviewer-speech
revision: 1
type: adr
status: accepted
title: Stream and recover local Qwen interviewer speech
repository: interview-arc-live
capabilityIds: ["live-adr-0006-local-interviewer-speech"]
createdAt: 2026-08-10
reconstructed: true
confidence: high
unknowns: ["Attachment bodies and workflow logs were not quoted."]
modules: ["Sources:InterviewArcLive","Sources:InterviewArcLiveCodexSmoke","Sources:InterviewArcLiveCore","Sources:InterviewArcLiveEndpointSmoke","Sources:InterviewArcLiveQwenAdapter","Sources:InterviewArcLiveSpeechOutputAdapter"]
interfaces: [".github/workflows/swift.yml"]
seams: ["room presentation ↔ deep session domain","reviewed tree ↔ packaged macOS artifact"]
adapters: ["Sources/InterviewArcLive/InterviewerSpeechPresentation.swift","Sources/InterviewArcLive/SystemDesignRoomModel.swift","Sources/InterviewArcLive/SystemDesignRoomView.swift","Sources/InterviewArcLiveCodexSmoke/InterviewArcLiveCodexSmoke.swift","Sources/InterviewArcLiveCore/InterviewRoomSession.swift","Sources/InterviewArcLiveCore/InterviewerSpeechCoordinator.swift"]
relatedRecords: []
decisions: []
incidents: []
features: []
capabilities: ["live-adr-0006-local-interviewer-speech"]
amends: []
supersedes: []
learningRefs: []
sources: [{"label":"Pull request #14","url":"https://github.com/Vinosaamaa/interview-arc-live/pull/14","kind":"pull-request"}]
verification: {"state":"verified","evidenceRefs":["pull-request:14","head-commit:c650cb91ba177632f8325a7e110b0627715dc00f","merge-commit:c135e508536130458e89dc6296db948c95e60ca0"]}
visibility: public-safe
publicationEligibility: eligible
issue: 13
pr: 14
release: null
run: null
---

# Stream and recover local Qwen interviewer speech

Evidence-indexed reconstruction of pull request #14. This record preserves the reviewed public-safe module, interface, seam, and adapter inventory from that change. It does not reconstruct unavailable motivation, success, attachment bodies, workflow logs, or deployment receipts.

## Historical limits

Dependent receipts link this exact revision. Unrecorded impact remains unknown.
