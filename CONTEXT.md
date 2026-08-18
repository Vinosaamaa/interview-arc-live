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

### Continuous Conversation

The default Turn Mode for new Sessions. While the Candidate Floor is open,
Live locally detects speech, creates durable Segments, transcribes finalized
audio, evaluates the accumulated answer, and may complete the canonical Hand
off after Endpoint Grace. Interviewer speech remains half-duplex in the first
shipment: candidate capture arms only after playback ends or is explicitly
stopped.

### Floor Hold

A durable candidate intent that suppresses automatic Hand off while a longer
answer is in progress. Activating **Hold floor** keeps silence and semantic
endpoint proposals from yielding the floor; **Send answer** ends the hold and
uses the same canonical Hand off transition after active Segment evidence is
durable.

### Hand off

The durable transition that commits one Candidate Turn and permits an
Interviewer Turn. It may be explicit or proposed by the selected Turn Mode.

### Candidate Turn

One logical candidate answer. It may contain multiple Segments separated by
thinking or work. Segments are never sent to the interviewer independently.

### Interviewer Turn

One canonical response containing rich `displayMarkdown` and concise
`spokenText` under one stable identity.

### Interviewer Utterance

The durable local-speech identity owned by one Interviewer Turn. It references
that Turn plus a fingerprint of its exact `spokenText`; it never duplicates or
rewrites the canonical text. Speech lifecycle cannot block interview progress.

### Synthesis Attempt

One durably authorized local generation operation for an Interviewer
Utterance. Retry creates a new Attempt while retaining the Utterance identity
and any previously selected valid audio. Provider/model/profile provenance and
privacy-safe WAV integrity metadata remain attached to the Attempt.

### Selected Interviewer Audio

The most recent fully validated 24-kHz mono WAV chosen for an Interviewer
Utterance. It is private derived media identified by a validated filename and
expected size, duration, format, and SHA-256—not a path or source of truth for
the Interviewer Turn.

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

The policy controlling capture and Hand off. New Sessions default to
`Continuous Conversation`; restored Sessions preserve their recorded mode.
`Cue Only`, `Patient Auto`, and `Manual` remain explicit compatibility and
recovery modes.

### Endpoint Proposal

A non-authoritative semantic result—`likely_continue`, `likely_end`, or
`ambiguous`—derived from the accumulated answer and current Activity context.
It may start a cancellable grace period but does not itself mutate durable
conversation state.

### Endpoint Evaluation

One durably authorized semantic-classifier request triggered by one concrete
Segment. It records that triggering Segment plus the ordered IDs of every
selected transcript candidate in the accumulated answer. It retains those
stable evidence identities and a context fingerprint, not duplicated
transcript or prompt text. An interrupted Evaluation is recorded without
automatically replaying the provider request.

### Endpoint Grace

One durable, cancellable four-second wait between a current `likely_end`
Endpoint Evaluation and Patient Auto's canonical Hand off. Keep my floor,
resumed speech, a Turn Mode change, or Board or Notes activity cancels it. A
pending grace is reconciled as interrupted after relaunch rather than silently
replayed.

### Session Manifest

The canonical, monotonically revisioned recovery record for an Interview Room
Session. Audio exports are derived from it and never replace it.

### Work Surface

The specialty-specific artifact area: system-design Board, coding workspace,
or behavioral Story Kit.

### Behavioral Room

The Behavioral specialty presentation of one Interview Room Session. Full and
compact Presentations share the same session identity. It can open locally
without hosted `/live/v1` behavioral writes. Hosted lease, turn-pair, clip,
and finish wait on Interview Arc issue #389. The live sidecar never carries a
preferred or model answer.

### STARL Coverage

Situation, Task, Action, Result, and Learning tracked as filled, current, or
empty during the live answer. Coverage is not a score.

### Coached Discovery

An explicit mode switch from interviewer to coaching after the candidate cannot
answer cold. It is not a hidden hint.

### Board Document

The versioned, bounded canonical editable source for one system-design Board.
Its boxes, connectors, labels, and strokes are data; opening or rendering the
Document cannot execute markup, fetch an external resource, or interpret a
filesystem path. Each box carries a bounded Node Kind so the live canvas and
derived artifacts render the same semantic symbol without guessing from its
label.

### Board Editor Adapter

The replaceable local interaction surface that projects one Board Document
into an editor and returns only the supported bounded boxes, connectors,
labels, and strokes. It may use a bundled third-party canvas, but it never
owns revision history, persistence, Turn evidence, or exports. Invalid or
unavailable Adapter output leaves the canonical Board Document unchanged and
the native editor available.

### Board Revision

An immutable, session-owned snapshot of one explicitly saved Board Document.
It has a stable identity and ordinal; later edits affect only the current
draft and never rewrite Revision history.

### Turn Board Attachment

The explicit `no board` or exact Board Revision evidence associated with one
Candidate Turn. Hand off persists it atomically with the Turn. A later command
may fill a `no board` association once but cannot substitute a different
Revision afterward.

### Board Export

One durably authorized attempt to derive and retain a selected Board
Revision's canonical source, deterministic SVG, and deterministic PNG as a
validated bundle. Its operation identity, intended session-relative artifact
identities, settings, and lifecycle survive interruption; no successful
bundle is visible until all three artifacts pass integrity checks.

### Presentation

A view of one Interview Room Session. Full and compact Presentations never own
separate recording, model, transcript, or persistence state.

## Invariants

- One Activity has at most one Live interaction writer.
- One Hand off creates at most one Candidate Turn and one matching Interviewer
  Turn, even after retries.
- One current `likely_end` Endpoint Evaluation owns at most one Endpoint Grace,
  and automatic completion uses the same at-most-once Hand off transition as
  the explicit action.
- Continuous Conversation may arm capture only during Candidate Floor. It does
  not listen through Interviewer TTS or infer a Candidate Turn from speech over
  playback in the first shipment.
- Floor Hold cancels or suppresses Endpoint Grace and automatic Hand off until
  **Send answer** explicitly releases it.
- Acoustic silence may finalize one Segment but never commits a Candidate Turn
  without current durable semantic and grace policy.
- Accepted transitions advance the Session Manifest revision monotonically.
- Every nonempty audio-derived transcript candidate remains visible with an
  explicit quality state.
- A provider side effect occurs only after its exact Segment or Transcription
  Attempt authorization is durable.
- Every newly persisted Interviewer Turn atomically owns one pending
  Interviewer Utterance.
- A speech provider runs only after its exact Synthesis Attempt authorization
  is durable; replaying a command never repeats generation or playback.
- Speech failure, Stop, Mute, or model absence never changes canonical Turn
  content or blocks Candidate Floor, Hand off, Finish, or recovery.
- A failed transcription never deletes the Source Recording.
- No client invents speech, hidden model memory, an Accepted verdict, or a
  durable write receipt.
