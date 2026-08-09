# ADR 0003: Use Groq GPT-OSS for the first semantic endpoint implementation

Status: Accepted

## Context

Patient interviews require question-aware endpointing. An audio-only detector
cannot know whether a grammatically complete answer omitted another requested
part. OpenAI Realtime adds metered duplicate audio processing, and SmartTurn
does not receive the interviewer question or Work Surface context.

## Decision

The first endpoint pipeline is acoustic VAD, Groq Whisper, then Groq
`openai/gpt-oss-20b` for semantic classification. The classifier receives the
exact question and requested parts, accumulated Candidate Turn, latest Segment,
silence duration, specialty/stage, explicit cue, and recent Work Surface
activity. Its strict result is `likely_continue`, `likely_end`, or `ambiguous`
with a reason code; generated confidence is not treated as calibrated.

SmartTurn and OpenAI Realtime are excluded from the first implementation.
`Hand off` remains available, resumed speech cancels an Endpoint Proposal, and
Patient Auto begins as an experimental/shadow-tested mode.

## Consequences

The classifier understands multipart questions and Activity context but cannot
hear prosody independently of transcription. VAD, grace timing, explicit cues,
and Work Surface signals remain application policy. The Groq Adapter stays
replaceable and credentials remain outside source.
