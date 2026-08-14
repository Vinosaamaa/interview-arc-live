---
schemaVersion: 1
id: architecture-review-hosted-practice-authority
revision: 1
type: architecture-review
status: accepted
title: Hosted Practice Authority for the Native System Design Room
repository: interview-arc-live
capabilityIds: ["hosted-practice-authority","system-design-room","recoverable-live-session"]
createdAt: 2026-08-11
reconstructed: false
confidence: verified
unknowns: []
modules: ["interview-arc-live-hosted-client","interview-room-session"]
interfaces: ["live-v1-client","hosted-practice-snapshot","hosted-mutation-outbox"]
seams: ["room-to-hosted-authority","hosted-client-to-live-v1","outbox-to-private-storage"]
adapters: ["url-session-live-v1-transport","keychain-integration-token-store","private-live-outbox-store","live-event-stream"]
relatedRecords: ["capability-dossier-deep-interview-room-session@1"]
decisions: []
incidents: []
features: []
capabilities: ["authoritative-activity-resume","fenced-hosted-writes","immutable-hosted-turn-pairs","authoritative-timer-and-result"]
amends: []
supersedes: []
learningRefs: []
sources: [{"label":"Hosted Live client issue #19","url":"https://github.com/Vinosaamaa/interview-arc-live/issues/19","kind":"issue"},{"label":"Hosted Live client PR #31","url":"https://github.com/Vinosaamaa/interview-arc-live/pull/31","kind":"pull-request"},{"label":"Hosted Live API issue #222","url":"https://github.com/Vinosaamaa/interview-arc/issues/222","kind":"issue"},{"label":"Live v1 contract","url":"https://github.com/Vinosaamaa/interview-arc/blob/main/docs/contracts/live-v1.md","kind":"documentation"}]
verification: {"state":"verified","evidenceRefs":["issue:19","pull-request:31","run:31489446259","paired-api-merge:58f437f4dc86bc3f22d3b8abcbd64a0490e7e5b1","paired-deployment:31373812145","runtime:hosted-authority-recovery"]}
visibility: public-safe
publicationEligibility: eligible
issue: 19
pr: 31
release: null
run: null
---
# Hosted Practice Authority for the Native System Design Room

## Question

Interview Arc owns Today, activity identity, timers, results, and published candidate/interviewer evidence in D1. Interview Arc Live owns native recording, transcription, interviewer generation, speech, Board drafts, and crash recovery. The native app needed a responsive local room without creating a second authority for state that must remain consistent across clients and relaunches.

The architecture question was therefore not simply how to call an HTTP API. It was how to preserve immediate native interaction and recoverable local provider work while ensuring that retries, concurrent installations, auth loss, and ambiguous network outcomes cannot fork or duplicate hosted evidence.

## Constraints

- The deployed `/live/v1` projection is authoritative for the selected activity, timer, result, canonical committed pairs, and hosted completion.
- Live must never copy a browser session or accept a caller-supplied owner identity. A revocable personal integration token resolves the owner server-side.
- Two Live installations must not concurrently mutate one activity.
- Every mutation must survive interruption before or after its response without changing its logical identity or silently discarding evidence.
- Local source recordings, provider work, Board drafts/revisions/exports, and recovery state remain private and native-owned.
- Hosted Board synchronization, automatic handoff, global dictation, and provider replacement are outside this slice.

## Alternatives reviewed

### Treat the local manifest as authority and synchronize opportunistically

Rejected. The website and other clients already use D1 for Today, timers, results, and transcript evidence. A second native authority would require conflict resolution for concurrent writers and could not truthfully determine which timer, result, or pair sequence won.

### Reuse browser endpoints, cookies, or Cloudflare Access state

Rejected. Those interfaces are not a stable native protocol, would blur owner resolution, and would require retaining browser authentication material in the app. The dedicated bearer integration token is revocable, owner-resolved, and stored only in Live's Keychain namespace.

### Send network requests directly from the room model

Rejected. Views and the room orchestration layer would each need to reproduce lease fencing, operation identity, digest validation, durable ordering, retry classification, receipt lookup, clock correction, and reconnect behavior. That would make recovery shallow and inconsistent.

### Use `/live/v1` behind a deep hosted-client Module

Accepted. `InterviewArcLiveHostedClient` owns authoritative reads, leases, stable mutation identity, private outbox ordering, receipt recovery, timer correction, event invalidation, and explicit recovery states behind one immutable snapshot and command Interface.

## Decision

The native room is a recoverable client of `/live/v1`:

- A dedicated Keychain account stores the Interview Arc integration token, with an explicit until-quit alternative. Groq, Codex, and local speech credentials are not reused.
- Today and the selected System Design activity are read before the room treats local state as current. The hosted question and stable activity identity select the local session recovery namespace.
- A retained installation UUID and fresh process/session UUID acquire a 90-second writer lease. Mutations carry the current fencing token, and the client renews every 30 seconds while writable.
- Every hosted mutation is written to a credential-partitioned, fsync-backed private outbox before network I/O. Ambiguous outcomes recover through the immutable receipt endpoint before exact replay is considered.
- Changed operation reuse, stale fences, foreign holders, auth loss, and evidence conflicts stop automatic drain and surface a recovery state. The client never edits an outbox record to force progress.
- Candidate and interviewer turns are committed as one immutable pair only after both local turns are durable. Hosted canonical sequence drives the server projection.
- Optional clips use staged metadata followed by checksum-validated authenticated upload. Failed media never removes an accepted text pair.
- Server event envelopes are invalidation hints only. Disconnects use bounded 15, 30, 60, then 120-second rereads, plus immediate foreground and reconnect refresh.
- Finish-next completes the current hosted activity atomically, rereads the next activity, and acquires a distinct lease rather than pretending a client-side lease transfer occurred.

## Ownership boundary

The local `InterviewRoomSession` remains authoritative for the in-progress candidate floor, segment/source recording recovery, provider attempts, Board evidence, and the exact local state needed to produce the next complete pair. It is not authoritative for hosted activity lifecycle, timer, result, committed pair order, or cross-client visibility.

The hosted client does not receive Board source, export bundles, provider threads, partial transcript streams, browser cookies, Cloudflare Access tokens, or public object URLs. This boundary keeps the hosted protocol narrow and prevents a synchronization feature from absorbing native provider and artifact ownership.

## Failure behavior

- Signed out: preserve local private state, present connection setup, and make hosted mutations unavailable.
- Offline or disconnected: preserve the outbox, stop automatic writes, and reread through the bounded recovery schedule.
- Lease held by another installation: project a truthful read-only state and never steal an unexpired lease.
- Stale fence or changed idempotency payload: stop replay and require explicit recovery.
- Ambiguous POST: lookup the stable operation receipt before retransmitting the identical request.
- Quit: flush local Board and Notes durability, then await the hosted outbox and lease cleanup through one AppKit terminate-later gate.

## Consequences

The native room gains a truthful hosted question, timer, result, canonical Turnline pairs, finish/finish-next, and recoverable writer state without inventing a second hosted source of truth. The cost is a deeper client Module and explicit read-only/recovery states, but those states make concurrency and ambiguity visible instead of hiding data loss behind optimistic UI.

The design also keeps remaining System Design gaps explicit. Patient Auto still requires its own authoritative handoff policy, Cue Only remains a separate presentation/endpointing slice until integrated, and system-wide push-to-talk belongs to Interview Arc Voice rather than this hosted authority.

## Verification

- The paired `/live/v1` API merged and deployed through Interview Arc issue #222.
- PR #31 previously passed its full hosted Swift run and all review gates on exact head `c31dfa9`.
- The rebased local branch strict-compiles current Core, Hosted Client, and the full current app with complete concurrency checking and warnings as errors.
- The hosted test target typechecks against the rebased Modules.
- The executable recovery harness passes authoritative projection, lease, timer, outbox replay, private clip, and reconnect-backoff contracts against freshly compiled current libraries.

## Release boundary

The integration remains local and unpushed after rebasing onto current `main`. A replacement PR head, hosted clean CI, an authorized merge, and an exact installed-artifact smoke with an owner-provisioned integration token remain required before issue #19 can close.
