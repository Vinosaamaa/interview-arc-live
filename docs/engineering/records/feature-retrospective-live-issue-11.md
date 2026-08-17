---
schemaVersion: 1
id: feature-retrospective-live-issue-11
revision: 1
type: feature-retrospective
status: released
title: Add durable Groq endpoint shadow mode
repository: interview-arc-live
capabilityIds: ["live-issue-11"]
createdAt: 2026-08-09
reconstructed: true
confidence: high
unknowns: ["Attachment bodies and workflow logs were not quoted."]
modules: ["Sources:InterviewArcLive","Sources:InterviewArcLiveCore","Sources:InterviewArcLiveEndpointSmoke"]
interfaces: [".github/workflows/swift.yml"]
seams: ["room presentation ↔ deep session domain","reviewed tree ↔ packaged macOS artifact"]
adapters: ["Sources/InterviewArcLive/EndpointShadowPresentation.swift","Sources/InterviewArcLive/SystemDesignRoomModel.swift","Sources/InterviewArcLive/SystemDesignRoomView.swift","Sources/InterviewArcLiveCore/GroqEndpointClassifier.swift","Sources/InterviewArcLiveCore/InterviewRoomSession.swift","Sources/InterviewArcLiveCore/SegmentSpeechCoordinator.swift"]
relatedRecords: []
decisions: []
incidents: []
features: []
capabilities: ["live-issue-11"]
amends: []
supersedes: []
learningRefs: []
sources: [{"label":"Pull request #12","url":"https://github.com/Vinosaamaa/interview-arc-live/pull/12","kind":"pull-request"}]
verification: {"state":"verified","evidenceRefs":["pull-request:12","head-commit:1da88c6e4731a28ca0233d0606433b774b433c5c","merge-commit:b442689bfc1769f53ba1c3ca71c21f95535490e5"]}
visibility: public-safe
publicationEligibility: eligible
issue: 11
pr: 12
release: null
run: null
---

# Add durable Groq endpoint shadow mode

Evidence-indexed reconstruction of pull request #12. This record preserves the reviewed public-safe module, interface, seam, and adapter inventory from that change. It does not reconstruct unavailable motivation, success, attachment bodies, workflow logs, or deployment receipts.

## Historical limits

Dependent receipts link this exact revision. Unrecorded impact remains unknown.
