---
schemaVersion: 1
id: change-note-truthful-idle-floor-rail
revision: 1
type: change-note
status: accepted
title: Keep Idle Floor Quiet And Hand Off As Sibling Chrome
repository: interview-arc-live
capabilityIds: ["interview-room-session"]
createdAt: 2026-08-17
reconstructed: false
confidence: verified
unknowns: []
modules: ["system-design-room-presentation"]
interfaces: ["full-room-waveform-layout"]
seams: ["session-to-presentations"]
adapters: ["full-presentation","compact-presentation"]
relatedRecords: ["capability-dossier-deep-interview-room-session@1","adr-live-0007-retained-full-and-compact-presentations@1"]
decisions: []
incidents: []
features: []
capabilities: ["truthful-idle-floor-chrome"]
amends: []
supersedes: []
learningRefs: []
sources: [{"label":"Issue #60","url":"https://github.com/Vinosaamaa/interview-arc-live/issues/60","kind":"issue"},{"label":"Pull request #68","url":"https://github.com/Vinosaamaa/interview-arc-live/pull/68","kind":"pull-request"}]
verification: {"state":"verified","evidenceRefs":["issue:60","pull-request:68","test:SystemDesignRoomLayoutTests.testWaveformUsesTheRailWithoutPretendingToBeRecordedAudio"]}
visibility: public-safe
publicationEligibility: eligible
issue: 60
pr: 68
release: null
run: null
---
# Keep Idle Floor Quiet And Hand Off As Sibling Chrome

Idle floor chrome was drawing a live-looking violet waveform and presenting Hand off as a filled bot CTA even when no segment existed. That is product behavior, not copy: waveform motion must be truthful, and Hand off must remain available without dominating Record or hosted finish chrome.

## Change

`LiveWaveform` still draws the quiet baseline. `FullRoomWaveformLayout.barHeight(level:canvasHeight:isActive:)` returns `0` when `isActive` is false, so idle draws no bars, and returns the existing `max(3, level * height * 0.88)` while recording (`model.canStopRecording`). Compact and full rails share `floorRailContent(compact:)`, so both presentations change together.

Hand off now uses `RoomChromeButtonStyle` like Record and Keep my floor. Enablement, shortcuts, labels, hosted Start/Pause/Set result/End, Cue Only, and Patient Auto are unchanged.
