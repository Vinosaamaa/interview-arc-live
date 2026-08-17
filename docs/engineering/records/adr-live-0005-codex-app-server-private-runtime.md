---
schemaVersion: 1
id: adr-live-0005-codex-app-server-private-runtime
revision: 1
type: adr
status: accepted
title: Generate real interviewer turns through Codex App Server
repository: interview-arc-live
capabilityIds: ["live-adr-0005-codex-app-server-private-runtime"]
createdAt: 2026-08-09
reconstructed: true
confidence: high
unknowns: ["Attachment bodies and workflow logs were not quoted.","Sensitive source values and nonessential risky evidence links were omitted from this reconstructed record."]
modules: ["Sources:InterviewArcLive","Sources:InterviewArcLiveCodexAdapter","Sources:InterviewArcLiveCodexSmoke","Sources:InterviewArcLiveCore"]
interfaces: [".github/workflows/swift.yml"]
seams: ["room presentation ↔ deep session domain","session domain ↔ Codex App Server adapter","reviewed tree ↔ packaged macOS artifact"]
adapters: ["Sources/InterviewArcLive/SystemDesignRoomModel.swift","Sources/InterviewArcLive/SystemDesignRoomView.swift","Sources/InterviewArcLiveCodexAdapter/CodexAppServerInterviewerRuntime.swift","Sources/InterviewArcLiveCodexAdapter/CodexAppServerProcess.swift","Sources/InterviewArcLiveCodexSmoke/main.swift","Sources/InterviewArcLiveCore/InterviewRoomSession.swift"]
relatedRecords: []
decisions: []
incidents: []
features: []
capabilities: ["live-adr-0005-codex-app-server-private-runtime"]
amends: []
supersedes: []
learningRefs: []
sources: [{"label":"Pull request #10","url":"https://github.com/Vinosaamaa/interview-arc-live/pull/10","kind":"pull-request"}]
verification: {"state":"verified","evidenceRefs":["pull-request:10","head-commit:b4fc0095e642dcd850f477e9a906227f5f319774","merge-commit:b32d279cc88faf399d421a95797854acf1460f90"]}
visibility: public-safe
publicationEligibility: eligible
issue: 9
pr: 10
release: null
run: null
---

# Generate real interviewer turns through Codex App Server

Evidence-indexed reconstruction of pull request #10. This record preserves the reviewed public-safe module, interface, seam, and adapter inventory from that change. It does not reconstruct unavailable motivation, success, attachment bodies, workflow logs, or deployment receipts.

## Historical limits

Dependent receipts link this exact revision. Unrecorded impact remains unknown.
