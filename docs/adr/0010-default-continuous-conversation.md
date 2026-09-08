# ADR 0010: Default to durable Continuous Conversation

- Status: Accepted
- Date: 2026-08-17
- Issue: #90

## Context

Live currently exposes the persistence boundaries of segmented speech as
primary conversation controls: Record segment, Stop segment, and Hand off.
Those controls are valuable recovery seams, but requiring them for every turn
makes a practice interview feel like operating a recorder rather than speaking
with an interviewer.

Issue #48 made Patient Auto complete the canonical Hand off at an explicit
finalized-Segment boundary. It deliberately left acoustic speech-boundary
detection to a following slice. The first natural-conversation shipment must
add that boundary without weakening the durable Segment, transcription,
endpoint, grace, and at-most-once Hand off contracts.

Long system-design and behavioral answers also need a deliberate way to keep
the floor. Ordinary pauses cannot be treated as that intent: silence is
ambiguous, and a model prediction must not overrule an explicit candidate
choice.

## Decision

New Interview Room Sessions default to `Continuous Conversation`. Existing
Session Manifests preserve their recorded Turn Mode.

During Candidate Floor, Live locally detects speech and creates a durable
Segment before capture. Local acoustic VAD may finalize that Segment after
silence. Live then follows the existing pipeline: retain the Source Recording,
authorize Groq transcription durably, select transcript evidence, run semantic
endpoint evaluation, and, for a current `likely_end`, complete Endpoint Grace
and the canonical at-most-once Hand off. After the Interviewer Turn and local
speech playback complete, Live re-arms Candidate Floor automatically.

Acoustic event handling never waits for a network transcription. The coordinator
serializes local capture boundaries and owns a separate ordered transcription
queue, allowing the next Segment to record while earlier audio waits for Groq.
Handoff remains blocked until every included Segment has selected evidence.
New Interviewer Turns enter one application delivery path for local speech and
hosted pair synchronization, whether initiated by a button or Endpoint Grace.
Quit and End disarm input and join owned work before releasing hosted authority.

System Design uses one VoiceCore acoustic input for detection and recording.
The 400 ms pre-roll and subsequent speech remain in a bounded in-memory buffer
while durable capture authorization and timer startup finish. Setup exceeding
15 seconds fails visibly instead of silently dropping the answer's beginning.
Only authorized capture creates a private source M4A. Automatic startup requests
microphone permission explicitly; denial and input failures surface in the room.
Pause preserves active recording and exposes Resume in both room sizes.

The normal Continuous Conversation presentation does not require Record,
Stop, or Hand off. Those actions remain available as explicit recovery and
compatibility controls when automatic capture is unavailable or a retained
Session uses another mode.

Continuous Conversation adds one durable two-state candidate control:

- **Hold floor** records a Floor Hold and cancels or suppresses Endpoint Grace
  and automatic Hand off. Local VAD may continue finalizing multiple Segments,
  but none may yield the Candidate Floor.
- **Send answer** releases the Floor Hold. After any active Segment and its
  selected evidence are durable, it invokes the same canonical Hand off used
  by automatic and manual completion.

These are the only two user-facing conversation states in the first shipment:
Automatic and Hold floor. Floor Hold is a temporary durable state inside
Continuous Conversation, not another Turn Mode. Legacy Turn Modes remain
decodable and available only as recovery or advanced behavior.

The first shipment supports candidate barge-in without adopting simultaneous
two-speaker dialogue. While interviewer TTS plays, its exact output frames are
the far-end reference for local echo cancellation. Local speech-start
detection receives only the cleaned near-end signal. Confirmed candidate speech
stops playback and stale generation, preserves a bounded pre-roll, durably
opens Candidate Floor, and then records normal Segment evidence. Unconfirmed
noise or residual playback cannot create a Candidate Turn or leave the device.

Every capture, boundary, transcription, endpoint, hold, grace, and Hand off
transition remains manifest-owned and recoverable. Module boundaries emit
public-safe traces containing command, phase, result code, and counts only;
they never log audio, transcripts, credentials, private IDs, or paths.

## Consequences

- The default interaction feels like a conversation while retaining the same
  durable evidence and at-most-once transitions as the explicit workflow.
- Silence can end an audio Segment but cannot independently commit a Candidate
  Turn. Semantic endpoint policy, Endpoint Grace, and Floor Hold remain
  authoritative.
- Long answers gain explicit non-interruption intent without requiring the
  candidate to manage each recording interval.
- Microphone permission, credential, provider, or recovery failures degrade to
  visible manual controls; they never fabricate a transcript or Hand off.
- Local VAD, re-arming, termination recovery, and Hold-floor reconciliation add
  lifecycle complexity and require headed audio tests plus relaunch coverage.
- Simultaneous overlapping candidate/interviewer dialogue remains deferred;
  interruption itself is part of the first shipment.
