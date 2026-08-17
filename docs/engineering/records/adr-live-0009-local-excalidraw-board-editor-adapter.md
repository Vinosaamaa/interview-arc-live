---
schemaVersion: 1
id: adr-live-0009-local-excalidraw-board-editor-adapter
revision: 1
type: adr
status: accepted
title: Embed a local Excalidraw Board editor
repository: interview-arc-live
capabilityIds: ["live-adr-excalidraw-adapter"]
createdAt: 2026-08-11
reconstructed: true
confidence: high
unknowns: ["Attachment bodies and workflow logs were not quoted.","Sensitive source values and nonessential risky evidence links were omitted from this reconstructed record."]
modules: ["Sources:InterviewArcLive"]
interfaces: [".github/workflows/swift.yml"]
seams: ["revisioned Board domain ↔ bundled Excalidraw runtime","reviewed tree ↔ packaged macOS artifact"]
adapters: ["Resources/InterviewArcLive.icns","Resources/InterviewArcLive.iconset/icon_128x128.png","Resources/InterviewArcLive.iconset/icon_16x16.png","Resources/InterviewArcLive.iconset/icon_256x256.png"]
relatedRecords: []
decisions: []
incidents: []
features: []
capabilities: ["live-adr-excalidraw-adapter"]
amends: []
supersedes: []
learningRefs: []
sources: [{"label":"Pull request #30","url":"https://github.com/Vinosaamaa/interview-arc-live/pull/30","kind":"pull-request"}]
verification: {"state":"verified","evidenceRefs":["pull-request:30","head-commit:ade34549c07b42a8d3463013ceeb226799af79a2","merge-commit:516e5dfaa753013464352f93686cbe380c6cbcd8"]}
visibility: public-safe
publicationEligibility: eligible
issue: 17
pr: 30
release: null
run: null
---

# Embed a local Excalidraw Board editor

Evidence-indexed reconstruction of pull request #30. This record preserves the reviewed public-safe module, interface, seam, and adapter inventory from that change. It does not reconstruct unavailable motivation, success, attachment bodies, workflow logs, or deployment receipts.

## Historical limits

Dependent receipts link this exact revision. Unrecorded impact remains unknown.
