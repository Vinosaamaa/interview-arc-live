# ADR 0009: Treat `/live/v1` as the hosted practice authority

- Status: Accepted
- Date: 2026-08-11
- Issue: [#19](https://github.com/Vinosaamaa/interview-arc-live/issues/19)

## Context

Interview Arc owns Today, activities, workbenches, timers, results, canonical
candidate/interviewer pairs, and cross-client synchronization. Interview Arc
Live owns the native recording, transcription, interviewer, speech, and Board
experience. Letting both products author overlapping practice state creates
split-brain behavior after retries, relaunches, or concurrent use.

The hosted protocol already supplies short-lived writer leases, fencing tokens,
immutable operation identifiers, receipt lookup, activity revisions, server
time, and invalidation events. The native app needs to honor those contracts
without leaking provider credentials or Board artifacts to the hosted service.

## Decision

Interview Arc Live uses a deep `InterviewArcLiveHostedClient` module at the
application boundary:

- A distinct Interview Arc personal integration token is stored in a dedicated
  Keychain namespace, with an explicit until-quit alternative. Groq, Codex, and
  local speech credentials are never reused or uploaded.
- `GET /live/v1/today` selects the authoritative open System Design activity.
  The room question, activity identity, timer, result, pairs, and finish state
  are projections of hosted state rather than locally invented replacements.
- A durable installation UUID and per-process holder-session UUID acquire the
  90-second writer lease. Mutations carry the current fencing token, and the
  lease renews every 30 seconds while the room is active.
- Every mutation is prepared in a credential-partitioned, fsync-backed private
  outbox before network I/O. Ambiguous operations recover by receipt before the
  exact canonical request body may be replayed; old holder sessions never
  invent a replacement fence or operation identifier.
- Candidate/interviewer pairs are committed only after both local turns are
  durably complete. The server copy becomes the canonical Turnline projection.
- Optional private audio clips use a staged metadata mutation followed by a
  checksum-verified upload. Local bytes remain private and recoverable until
  the server confirms availability.
- WebSocket invalidations use the `interview-arc-live` subprotocol. Disconnects
  fall back to bounded 15/30/60/120-second re-reads. Displayed elapsed time is
  corrected by observed server clock offset.
- Finish-next completes the current activity atomically, re-reads Today and the
  selected next System Design activity, then acquires a fresh writer lease.
- The local app remains authoritative only for source recordings, Groq/Codex/
  local-speech provider work, Board drafts/revisions/exports, and crash recovery
  needed to produce the next canonical hosted pair.

## Consequences

The room fails closed for recording and other mutations when signed out,
offline, fenced, or awaiting an ambiguous receipt. Another active writer yields
a truthful read-only room rather than a destructive takeover. Relaunch can
resume outbox and clip recovery without duplicate turns.

This slice does not add automatic endpoint handoff, global push-to-talk,
Brief/Notes content, or Board upload. Those remain separate product slices and
cannot silently degrade hosted authority or durability.
