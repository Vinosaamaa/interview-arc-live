---
schemaVersion: 1
id: capability-dossier-deep-interview-room-session
revision: 1
type: capability-dossier
status: accepted
title: Deep Interview Room Session
repository: interview-arc-live
capabilityIds: ["interview-room-session", "durable-turns", "specialty-work-surfaces"]
createdAt: 2026-08-12
reconstructed: false
confidence: verified
unknowns: []
modules: ["interview-room-session"]
interfaces: ["session-commands", "immutable-session-snapshot", "session-manifest-store"]
seams: ["session-to-persistence", "session-to-semantic-endpointing", "session-to-presentations"]
adapters: ["file-session-manifest-store", "groq-endpoint-classifier", "full-presentation", "compact-presentation"]
relatedRecords: []
decisions: []
incidents: []
features: []
capabilities: []
amends: []
supersedes: []
learningRefs: []
sources: [{"label":"Live domain context","url":"https://github.com/Vinosaamaa/interview-arc-live/blob/main/CONTEXT.md","kind":"documentation"},{"label":"ADR 0001 — separate Live application","url":"https://github.com/Vinosaamaa/interview-arc-live/blob/main/docs/adr/0001-separate-live-application.md","kind":"documentation"},{"label":"ADR 0002 — deep Interview Room Session","url":"https://github.com/Vinosaamaa/interview-arc-live/blob/main/docs/adr/0002-deep-interview-room-session.md","kind":"documentation"},{"label":"Live adoption issue #41","url":"https://github.com/Vinosaamaa/interview-arc-live/issues/41","kind":"issue"}]
verification: {"state":"not-recorded","evidenceRefs":[]}
visibility: public-safe
publicationEligibility: eligible
issue: 41
pr: 42
release: null
run: null
---
# Deep Interview Room Session

Interview Arc Live centers durable technical mock interviews on one deep Interview Room Session Module bound to one stable Interview Arc Activity.

## Capability

The Session owns phase, Turn Mode, ordered Candidate and Interviewer Turns, stable operation identities, revisioned work-surface evidence, and recovery state. A provider thread is a replaceable runtime binding rather than the Session identity.

Candidate silence may finalize an audio Segment but never commits a Candidate Turn. Hand off is the durable transition that closes one logical answer, even when it contains multiple speech segments or working pauses.

## Module boundary

The `InterviewRoomSession` Interface accepts domain commands and returns immutable snapshots. The implementation owns transition validation, stable Turn identity, idempotency, manifest revisioning, persistence order, and recovery.

Callers cannot mutate stored Session state directly. This keeps ordering and recovery rules local rather than distributing them through SwiftUI presentations, provider callbacks, and storage code.

## Seams and Adapters

Persistence and semantic endpointing are Seams because deterministic test and production Adapters both exist. The Session Manifest is the canonical monotonically revisioned recovery record; combined audio is a derived export.

Full and compact Presentations are Adapters over one Session. They never own separate recording, model, transcript, or persistence state. Specialty work surfaces attach exact revision evidence to Candidate Turns without replacing the Turn or Session identity.

## Separate application boundary

Live remains a separate repository, process, bundle identity, Keychain service, Application Support root, preferences domain, hotkey namespace, and microphone owner. It does not read Voice queues or depend on the Voice application running.

Live may use explicit, versioned package functionality at a compatibility-tested Seam. It does not share Voice credentials, storage, preferences, recorder ownership, or delivery state.

## Privacy and recovery

Every nonempty best provider transcript candidate remains visible with an explicit quality state. A failed transcription never deletes the source recording, and a provider side effect begins only after its exact durable authorization.

Credentials and runtime evidence remain in Live-owned private storage. Canonical public Engineering evidence contains no recording, transcript, credential, model artifact, private identifier, or machine-specific path.

## Consequences

The Session Interface carries strong ordering and error contracts, while providers, persistence, work surfaces, and Presentations can evolve independently. State-machine failures retain locality, and recovery can resume from the Session Manifest without inventing hidden model memory or durable write receipts.

This adoption changes no native runtime or visible interface. The Arc Engineering Journal Module owns commit-pinned ingestion, privacy validation, correction history, search, Statistics, and reader parity.

## Interview view

The deep Module prevents a common orchestration failure: putting transition rules in views and provider callbacks. One small command/snapshot Interface hides ordering, durable authorization, stable identity, and recovery complexity from every Adapter.

The durable boundary is the Session Manifest, not a provider thread or combined audio file. That choice lets the app replace endpoint, persistence, speech, and Presentation Adapters without losing the candidate's canonical interview history.
