# ADR 0002: Center the implementation on a deep Interview Room Session Module

Status: Accepted

## Context

The product combines phase transitions, stable identities, idempotency,
persistence ordering, recovery, provider work, and two Presentations. Spreading
those rules across view models and provider callbacks would reduce locality and
repeat the orchestration problems already observed in sibling codebases.

## Decision

`InterviewRoomSession` is a deep Module. Its small Interface accepts domain
commands and returns immutable snapshots. Its Implementation owns transition
validation, stable Turn identity, command idempotency, manifest revisioning,
persistence order, and recovery.

Persistence and semantic endpointing are Seams because production and
deterministic-test Adapters are both real. Do not create other provider Seams
until a second Adapter exists. The Module Interface is the behavior-test
surface; callers do not mutate stored state directly.

## Consequences

The Interface carries strong ordering and error contracts, but callers gain
high leverage. State-machine bugs retain locality. SwiftUI Presentations and
future provider Adapters cannot bypass durable transition rules.
