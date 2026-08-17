---
schemaVersion: 1
id: change-note-live-floor-timer-waveform
revision: 1
type: change-note
status: accepted
title: Tick Hosted Floor Timer And Drive Recording Waveform From Microphone Levels
repository: interview-arc-live
capabilityIds: ["interview-room-session"]
createdAt: 2026-08-17
reconstructed: false
confidence: verified
unknowns: []
modules: ["system-design-room-presentation","voice-core-segment-recorder"]
interfaces: ["full-room-waveform-layout","full-room-hosted-timer-layout"]
seams: ["recorder-to-floor-waveform"]
adapters: ["answer-recorder-driver"]
relatedRecords: ["change-note-truthful-idle-floor-rail@1","adr-live-0007-retained-full-and-compact-presentations@1"]
decisions: []
incidents: []
features: []
capabilities: ["truthful-live-floor-metering"]
amends: []
supersedes: []
learningRefs: []
sources: [{"label":"Issue #75","url":"https://github.com/Vinosaamaa/interview-arc-live/issues/75","kind":"issue"},{"label":"Pull request #76","url":"https://github.com/Vinosaamaa/interview-arc-live/pull/76","kind":"pull-request"}]
verification: {"state":"verified","evidenceRefs":["issue:75","pull-request:76","test:SystemDesignRoomLayoutTests.testHostedElapsedTextFormatsWholeSeconds","test:SystemDesignRoomLayoutTests.testRecordingWaveformUsesMicrophoneDecibelsAndStaysIdleWhenQuiet"]}
visibility: public-safe
publicationEligibility: eligible
issue: 75
pr: 76
release: null
run: null
---
# Tick Hosted Floor Timer And Drive Recording Waveform From Microphone Levels

The hosted floor-rail `MM:SS` was computed from `runningSince` plus `Date()` without a clock, so SwiftUI left the label frozen until another chrome event redrew the rail. `LiveWaveform` drew a hardcoded bar array while recording, so the wave did not follow the microphone.

## Change

The hosted timer label is wrapped in a one-second `TimelineView` and formatted by `FullRoomHostedTimerLayout`. The Voice adapter forwards `AnswerRecorder` power history into the room model. Recording bars use those decibel samples plus the Voice pulse; idle still draws no bars. Reduce Motion drops the pulse only. Compact does not grow a second timer. Hand off enablement is unchanged.
