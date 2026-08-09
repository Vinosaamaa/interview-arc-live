# ADR 0004: Durable segmented candidate speech

- Status: Accepted
- Date: 2026-08-09
- Issue: #5

## Context

A Candidate Turn may include several spoken intervals separated by thinking,
coding, or drawing. Microphone and provider calls are fallible side effects;
neither may be allowed to erase a playable recording, duplicate a request, or
commit an answer merely because one audio interval ended.

## Decision

`InterviewRoomSession` owns ordered Segment and Transcription Attempt state in
the canonical Session Manifest. It durably accepts each reservation or
provider authorization before the corresponding side effect. Replaying the
same command ID returns its prior receipt; only a fresh explicit retry ID may
authorize another provider request.

Each Segment keeps one private Source Recording under Live's session root and
stores only a validated relative M4A identity in the Manifest. The URL returned
by the recorder after finalization is authoritative because microphone recovery
may replace the initially reserved file. Provider chunks are disposable.

Every nonempty Groq result is persisted verbatim. Selection is deterministic:
`verified`, then `best_available`, then `possible_contamination`; word and
character count break ties, followed by the earlier Attempt. Empty results keep
the Source Recording retryable and never invent text. Explicit Hand off joins
the selected Segment transcripts in order into one Candidate Turn.

The VoiceCore dependency is pinned at one merged revision and isolated behind
the `InterviewArcLiveVoiceAdapter` target. Live never imports Voice delivery,
dictation, planner, storage-root, or credential behavior.

## Consequences

- Relaunch can show the exact last durable Segment state and requires explicit
  authorization before replaying an interrupted provider request.
- SwiftUI observes immutable state and cannot call the microphone, filesystem,
  or Groq directly.
- Live pays the build cost of VoiceCore's current transitive dependencies until
  a narrower shared audio package has demonstrated leverage.
- Automatic silence segmentation, semantic handoff, D1/R2 delivery, and
  cross-app microphone leases remain separate decisions.
