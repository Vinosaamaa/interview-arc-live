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

The first shipment remains half-duplex. Capture is not armed while interviewer
TTS is playing. Candidate speech over playback is not silently promoted into a
turn; the candidate must stop playback or wait for it to finish. Autonomous
barge-in, echo cancellation, and full-duplex audio require a separate decision.

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
- Automatic barge-in and full-duplex speech are intentionally deferred.
