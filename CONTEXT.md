# Interview Arc Live Domain Context

## Purpose

Interview Arc Live is a standalone native macOS room for spoken technical mock
interviews. It projects durable Interview Arc activity state into a focused
conversation and specialty work surface. Interview Arc Voice remains the
system-wide dictation companion.

## Glossary

### Interview Room

The Live experience bound to one Activity. It owns the current Interview Room
Session and may be presented full-size or compactly.

### Activity

The owner-scoped Interview Arc practice item. Its stable `activityId` selects
the specialty contract. Persona or provider changes never change the Activity.

### Interview Room Session

The ordered, recoverable state for one Activity while Live owns interaction.
It includes phase, Turns, mode, revision, and artifact references. A model
thread is a replaceable runtime binding, not the Session identity.

### Candidate Floor

The interval in which the candidate may speak, think, code, or draw. Silence
may finalize an audio Segment but never ends the Candidate Floor by itself.

### Hand off

The durable transition that commits one Candidate Turn and permits an
Interviewer Turn. It may be explicit or proposed by the selected Turn Mode.

### Candidate Turn

One logical candidate answer. It may contain multiple Segments separated by
thinking or work. Segments are never sent to the interviewer independently.

### Interviewer Turn

One canonical response containing rich `displayMarkdown` and concise
`spokenText` under one stable identity.

### Segment

One finalized candidate audio interval with stable identity, timing,
transcription attempts, and quality. Multiple Segments may belong to one
Candidate Turn.

### Transcription Attempt

One durably authorized provider request for a Segment. A retry is a new
Attempt; replaying an existing operation ID never sends audio again.

### Source Recording

The private, session-owned M4A produced for one Segment. It remains canonical
recovery evidence when transcription fails; provider upload chunks are
temporary derivatives.

### Best Transcript Candidate

The deterministic selected nonempty provider result for a Segment. Quality
controls its evidence status, never whether the text remains visible.

### Turn Mode

The policy controlling Hand off: `Cue Only`, experimental `Patient Auto`, or
`Manual`.

### Endpoint Proposal

A non-authoritative semantic result—`likely_continue`, `likely_end`, or
`ambiguous`—derived from the accumulated answer and current Activity context.
It may start a cancellable grace period but does not itself mutate durable
conversation state.

### Endpoint Evaluation

One durably authorized semantic-classifier request at a specific selected
Segment-evidence boundary. It retains stable evidence identities and a context
fingerprint, not duplicated transcript or prompt text. An interrupted
Evaluation is recorded without automatically replaying the provider request.

### Session Manifest

The canonical, monotonically revisioned recovery record for an Interview Room
Session. Audio exports are derived from it and never replace it.

### Work Surface

The specialty-specific artifact area: system-design Board, coding workspace,
or behavioral Story Kit.

### Presentation

A view of one Interview Room Session. Full and compact Presentations never own
separate recording, model, transcript, or persistence state.

## Invariants

- One Activity has at most one Live interaction writer.
- One Hand off creates at most one Candidate Turn and one matching Interviewer
  Turn, even after retries.
- Accepted transitions advance the Session Manifest revision monotonically.
- Every nonempty audio-derived transcript candidate remains visible with an
  explicit quality state.
- A provider side effect occurs only after its exact Segment or Transcription
  Attempt authorization is durable.
- A failed transcription never deletes the Source Recording.
- No client invents speech, hidden model memory, an Accepted verdict, or a
  durable write receipt.
