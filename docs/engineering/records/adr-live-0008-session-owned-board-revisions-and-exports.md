---
schemaVersion: 1
id: adr-live-0008-session-owned-board-revisions-and-exports
revision: 1
type: adr
status: accepted
title: Deliver the revisioned System Design Board
repository: interview-arc-live
capabilityIds: ["live-adr-revisioned-board"]
createdAt: 2026-08-10
reconstructed: true
confidence: high
unknowns: ["Attachment bodies and workflow logs were not quoted.","Sensitive source values and nonessential risky evidence links were omitted from this reconstructed record."]
modules: ["Sources:InterviewArcLive","Sources:InterviewArcLiveCore"]
interfaces: ["no explicit public interface file changed"]
seams: ["room presentation ↔ deep session domain","revisioned Board domain ↔ bundled Excalidraw runtime"]
adapters: ["Sources/InterviewArcLive/BoardEditorReducer.swift","Sources/InterviewArcLive/BoardNodePresentation.swift","Sources/InterviewArcLive/DeterministicBoardRenderer.swift","Sources/InterviewArcLive/DrawIOBoardCodec.swift","Sources/InterviewArcLive/PrivateBoardArtifactStore.swift","Sources/InterviewArcLive/SystemDesignBoardView.swift"]
relatedRecords: []
decisions: []
incidents: []
features: []
capabilities: ["live-adr-revisioned-board"]
amends: []
supersedes: []
learningRefs: []
sources: [{"label":"Pull request #22","url":"https://github.com/Vinosaamaa/interview-arc-live/pull/22","kind":"pull-request"}]
verification: {"state":"verified","evidenceRefs":["pull-request:22","head-commit:e96a0a5bc5b0fe5847e2f08c47308df57db827b0","merge-commit:ea395e7d8c818551cc6ac09f79f13ebb47bca304"]}
visibility: public-safe
publicationEligibility: eligible
issue: 17
pr: 22
release: null
run: null
---

# Deliver the revisioned System Design Board

Evidence-indexed reconstruction of pull request #22. This record preserves the reviewed public-safe module, interface, seam, and adapter inventory from that change. It does not reconstruct unavailable motivation, success, attachment bodies, workflow logs, or deployment receipts.

## Historical limits

Dependent receipts link this exact revision. Unrecorded impact remains unknown.
