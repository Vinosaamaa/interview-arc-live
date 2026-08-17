---
schemaVersion: 1
id: adr-live-0007-retained-full-and-compact-presentations
revision: 1
type: adr
status: accepted
title: Project one room into full and compact presentations
repository: interview-arc-live
capabilityIds: ["live-adr-retained-presentations"]
createdAt: 2026-08-10
reconstructed: true
confidence: high
unknowns: ["Attachment bodies and workflow logs were not quoted."]
modules: ["Sources:InterviewArcLive"]
interfaces: ["no explicit public interface file changed"]
seams: ["repository-internal change; no cross-boundary seam evidenced"]
adapters: ["Sources/InterviewArcLive/CompactRoomPresentation.swift","Sources/InterviewArcLive/CompactSystemDesignRoomView.swift","Sources/InterviewArcLive/InterviewArcLiveApp.swift","Sources/InterviewArcLive/InterviewRoomPresentationCoordinator.swift","Sources/InterviewArcLive/SystemDesignRoomModel.swift","Sources/InterviewArcLive/SystemDesignRoomView.swift"]
relatedRecords: []
decisions: []
incidents: []
features: []
capabilities: ["live-adr-retained-presentations"]
amends: []
supersedes: []
learningRefs: []
sources: [{"label":"Pull request #20","url":"https://github.com/Vinosaamaa/interview-arc-live/pull/20","kind":"pull-request"}]
verification: {"state":"verified","evidenceRefs":["pull-request:20","head-commit:a2539809edb4b0ccc33c748503ee34ac15b7125f","merge-commit:25e5073b38c1b7d1751d7a323a9a533ceefae4e4"]}
visibility: public-safe
publicationEligibility: eligible
issue: 16
pr: 20
release: null
run: null
---

# Project one room into full and compact presentations

Evidence-indexed reconstruction of pull request #20. This record preserves the reviewed public-safe module, interface, seam, and adapter inventory from that change. It does not reconstruct unavailable motivation, success, attachment bodies, workflow logs, or deployment receipts.

## Historical limits

Dependent receipts link this exact revision. Unrecorded impact remains unknown.
