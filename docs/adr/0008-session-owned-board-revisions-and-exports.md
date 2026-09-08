# ADR 0008: Keep Board revisions, Turn evidence, and export authorization in the Session

- Status: Accepted
- Date: 2026-08-10
- Issue: #17

## Context

The system-design Board has an editable draft, immutable saved evidence,
historical inspection, and fallible filesystem rendering. If Presentations or
export callers chose Revision identities and attached them independently, a
retry or relaunch could save the same draft twice, attach a mutable latest
Board to an old Candidate Turn, or report an artifact before its complete
bundle was durable and validated.

## Decision

`InterviewRoomSession` owns one bounded, versioned Board Document draft,
ordered immutable Board Revisions, historical selection, exact Candidate Turn
attachments, and Board Export operation lifecycles in the canonical Session
Manifest. Revision and Export identities are deterministic functions of the
Session and command identities. Legacy manifests decode to an empty Board and
legacy Candidate Turns decode to explicit `no board` evidence.

Box Node Kind is canonical source data rather than a presentation inference
from label text. Legacy boxes decode to `generic`; every Presentation and
derived format renders the same stored kind.

Hand off validates and persists either `no board` or one exact existing Board
Revision in the same Candidate Turn transition before interviewer work. A
later explicit, idempotent command may attach one existing Revision to a
Candidate Turn that still says `no board`; it cannot replace a Revision that
is already associated.

Export authorization persists the selected Revision, declared deterministic
settings, and validated session-relative intended source/SVG/PNG identities
before any renderer or filesystem side effect. A separate outcome command
accepts success only when all three integrity records exactly match that
authorization. Failure or interruption leaves Revision and Turn identities
unchanged and permits a fresh explicit retry.

The editor, Draw.io-compatible codec, renderer, and private artifact store are
Adapters behind this Interface. Derived SVG and PNG never replace the
canonical Board Document.

## Consequences

- Full and compact Presentations observe one immutable Session snapshot and
  cannot invent revision, attachment, or export ordering.
- Relaunch restores draft, Revision history, selected history, Turn evidence,
  and export lifecycle without automatic save, attachment, or rendering.
- Local exports remain private, session-relative derived artifacts; hosted
  synchronization and publication require a separate contract.

## Interviewer context (issue #99)

An explicitly attached Board Revision now accompanies the current answer through
`InterviewerRequest.attachedBoard`. Core resolves that exact immutable revision;
the Codex adapter sends its structured boxes, connectors, labels and strokes as
quoted interview data. This does not grant file or tool access. Unattached drafts,
private scratch notes and exported files remain outside the AI request.

A diagram larger than 256 KiB of encoded document data is rejected before Hand
off commits the answer; the candidate can choose a smaller saved revision or no
attachment. Nothing is silently truncated. Provider failure and explicit retry
keep the same revision even if the draft subsequently changes.
