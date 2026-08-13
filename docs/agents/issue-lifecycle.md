# Interview Arc Live Issue Lifecycle

This contract governs Live issues, implementation, verification, release, and
closure. Cross-repository changes also follow the owning sibling repository's
lifecycle and use separate, cross-linked issues and PRs.

## Intake and routing

Live owns its native macOS room, recording, local transcript/session recovery,
agent/TTS Adapters, compact presentation, specialty work surfaces, signing, and
installation. Interview Arc owns hosted APIs, D1/R2, website, and publication.
Interview Arc Voice owns the system-wide dictation application and reusable
audio code it exports.

Before implementation:

1. inspect current `main` and search open/closed issues;
2. reproduce bugs safely when applicable;
3. update an existing issue or create an implementation-ready issue;
4. record dependencies and paired repository work;
5. choose Fast, Standard, or Reliability verification.

Reliability is mandatory for recording, transcription, endpointing,
persistence, synchronization, privacy, credentials, crash recovery, signing,
or any behavior that could silently lose or corrupt interview work.

## Implementation and PR

- Work on a feature branch and preserve unrelated changes.
- Link the PR using `Refs #<issue>`; do not auto-close on merge.
- Keep each vertical slice independently testable and exclude unapproved scope.
- Update domain terms and ADRs when decisions change.
- Test through Module Interfaces. Use deterministic, public-safe fixtures.
- Record changed behavior, verification, risks, rollback, and known limits.

### Engineering record authorship

Every pull request owns one compact Engineering receipt. This is implementation
work, not a separate operation that the user must remember to request.

1. During issue intake, classify the planned change as `none` or one material
   Engineering record type from
   [`docs/engineering/pull-request-history.md`](../engineering/pull-request-history.md).
2. For material work, author its canonical public-safe rich Markdown record on
   the implementation branch before its receipt refers to it, or select an
   existing exact `id@revision` at the pull-request head whose reviewed cluster
   genuinely covers the change. Author evidence-backed diagrams only when they
   clarify verified structure or flow; CI never invents them.
3. Push the first coherent public-safe commit and open a **draft pull request**
   when its Live repository number is not yet known.
4. Run `python3 scripts/new-engineering-receipt.py --pr <number> ...`, commit
   exactly one `docs/engineering/changes/pr-<number>.md`, and select the matching
   Engineering-impact checkbox. `None` requires a concrete reason of at least
   12 characters.
5. Request review only after the receipt, every required rich record/reference,
   and the PR classification agree. CI validates canonical authorship. Arc's
   build derives JSON, search, backlinks, Statistics, immutable links to
   authored diagram assets, a portable static HTML export, and the website
   projection; it does not create their narrative or diagram content.

Run `python3 scripts/new-engineering-receipt.py --help` for exact examples.
Automatic projection never means automatic narrative.

## Verification and release

- Run focused tests locally and require clean hosted CI.
- A SwiftUI preview or source build is not release evidence.
- Before distribution, package the exact merged-main tree, sign it with the
  approved local identity, run a staged smoke, install those exact bytes, and
  verify the installed application for the selected lane.
- Do not merge, install, notarize, deploy, or close without the authorization
  and verification required by the current user request.

## Execution ledger

Implementation PRs and coordinator handoffs keep a chronological ledger of the
meaningful work actually performed. Record exact Pacific timestamps when
instrumented, repeated hosted runs and their reason, external waits, artifacts,
retention, and provider-exposed metered usage. Use `unknown` rather than
inventing missing request time, duration, or cost. Omit actions that did not
happen. The ledger is administrative and never enters a practice transcript.

## Resolution

After authorized merge/release verification, comment with the PR, merge
commit, released artifact, completed date, root cause or design intent, change,
verification, known limitations, and documentation. Close only after the
selected lane's required verification. Reopen the same issue for recurrence of
the same behavior.
