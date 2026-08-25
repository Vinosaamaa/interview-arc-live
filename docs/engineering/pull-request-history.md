# Engineering pull-request history protocol

Engineering history has two deliberately separate layers. The separation keeps the complete timeline factual and inexpensive while preserving deep technical narrative where it is useful.

| Layer | Coverage | Canonical source | Purpose |
| --- | --- | --- | --- |
| Pull Request Receipt | One compact receipt for every merged pull request | `docs/engineering/changes/pr-<number>.md` | Complete chronological change inventory |
| Rich Engineering Record | Material changes or a reviewed cluster of related changes | `docs/engineering/records/*.md` | Architecture, decisions, incidents, retrospectives, and capability context |

The receipt contract is versioned by `docs/contracts/engineering-pull-request-receipt.schema.json`. The six rich record types remain Change Note, ADR, Architecture Review, Feature Retrospective, Postmortem, and Capability Dossier. Tooling must not silently reinterpret an accepted v1 document.

### Version 1 frontmatter encoding

Version 1 uses a deliberately restricted encoding, not general YAML:

- **Grammar:** write one unique, nonempty `key: value` pair per line. Parsing splits on the first colon, so later colons and apostrophes remain part of an unquoted value.
- **String scalars:** use either an unquoted string or a JSON double-quoted string. An unquoted value must be nonempty and must not begin with a single quote, pipe, greater-than sign, ampersand, asterisk, or exclamation mark.
- **Structured values:** use JSON syntax for arrays, objects, booleans, integers, and `null`.
- **Rejected YAML features:** do not use block lists, multiline scalars, anchors, aliases, tags, or single-quoted scalars.

This representation keeps the Python policy gate and Arc's deterministic JavaScript projection aligned without a parser dependency or ambiguous implicit YAML types.

## Forward authoring protocol

The implementation coordinator owns the receipt as part of the pull request.
The user does not need to request a separate Journal operation. Follow
[`Engineering record authorship`](../agents/issue-lifecycle.md#engineering-record-authorship):
classify the change during issue work, author or select any exact rich record
before review, use a draft pull request to obtain the Live repository number,
then scaffold and commit its numbered receipt. Material work may add a record or
reuse an exact existing rich record whose reviewed cluster genuinely covers the
change.

After the pull request number is known, run:

```sh
python3 scripts/new-engineering-receipt.py \
  --pr <number> \
  --title "<exact pull-request title>" \
  --summary "<one public-safe factual paragraph>" \
  --classification none
```

Run `python3 scripts/new-engineering-receipt.py --help` for complete
non-material and material examples. The helper is non-interactive, makes no
GitHub, network, Xcode, installation, or runtime call, and refuses unsafe values
or an existing target.

CI does not invent motivation, architecture, root cause, impact, prose, or
diagrams from a diff. The coordinator authors the factual receipt and any
required rich record while it has the implementation context. Canonical state
is Markdown in Git; generated JSON and the portable static HTML export are
disposable Arc projections, not a database or second source of narrative truth.

## Compact receipt example

```markdown
---
schemaVersion: 1
repository: interview-arc-live
pr: 57
title: Correct compact panel spacing
classification: none
richRecordRefs: []
reconstructed: false
confidence: verified
unknowns: []
headCommit: null
mergeCommit: null
mergedAt: null
sources: [{"label":"Pull request #57","url":"https://github.com/Vinosaamaa/interview-arc-live/pull/57","kind":"pull-request"}]
verification: {"state":"verified","evidenceRefs":["pull-request:57"]}
visibility: public-safe
publicationEligibility: eligible
---
# Correct compact panel spacing

Corrected local spacing without changing a Module, Interface, durable state, or application boundary.
```

The Arc generator derives the receipt source commit, immutable source permalink, and source timestamp from Git. These values do not appear in frontmatter, so a pull request never predicts the commit that will contain its own receipt.

`headCommit`, `mergeCommit`, and `mergedAt` are optional historical facts. Leave them `null` unless authoritative evidence verifies the exact value. Supplied facts require verified evidence references.

## Materiality

A receipt is always required, but rich prose is not. Use a rich record when a change materially affects a Module or Interface, schema or migration, cross-repository protocol, durable state or ownership rule, dependency boundary, security, privacy, reliability, accessibility, performance, incident repair, or a difficult-to-reverse tradeoff.

Apply these decision tests consistently:

| Category | Material when the pull request… | Typical evidence |
| --- | --- | --- |
| Module or Interface | changes an accepted command, snapshot, invariant, ownership rule, or Adapter boundary | public API diff, state-transition test, accepted ADR |
| Schema or migration | changes a persisted format, compatibility rule, recovery path, or data conversion | schema diff, migration/recovery test |
| Cross-repository protocol or dependency | changes a hosted/native contract, package boundary, trusted pin, or release ordering | paired issues/PRs, compatibility test, exact commit pin |
| Security, privacy, or reliability | changes authorization, credentials, private media, durable ordering, retry, recovery, signing, or data-loss behavior | threat/privacy review, failure-path test, release evidence |
| Accessibility or performance | changes user-reachable semantics or a measured resource/latency budget, rather than local formatting | accessibility verification or before/after measurement |
| Incident repair | fixes a verified production or release failure with an evidence-backed cause and prevention action | timeline, logs, failing test, prevention check |
| Difficult-to-reverse decision | adds a long-lived dependency, application boundary, canonical source, or operational commitment | alternatives, tradeoffs, accepted ADR |

After the materiality test passes, choose the record type by its evidence scope: Change Note for one material behavior change; ADR for one accepted durable decision; Architecture Review for an alternatives/constraints evaluation; Feature Retrospective for a reviewed multi-PR feature or migration; Postmortem for a verified incident and prevention work; Capability Dossier for a capability described by several exact records or repositories.

Do not inflate a small receipt into a rich record. Do not compress architecture, incident causality, or a multi-PR migration into a 280-character receipt.

An accepted rich-record file and exact revision are immutable in place and are not deleted. Correct one by adding a reviewed new revision, amendment, or superseding record as a separate document so existing receipt references remain resolvable and historical changes stay explicit.

Each rich-record Markdown file is limited to 65,536 UTF-8 bytes so pull-request policy validation remains bounded.

## Historical backfill protocol

A backfill coordinator uses the same contracts. Each publication pull request keeps its own forward-authored `reconstructed: false` receipt and selects `None` with a concrete reason because the batch publishes historical evidence without asserting a new current architecture change. It also adds exactly one `docs/engineering/backfill/pr-<current-pr-number>.json` manifest conforming to `docs/contracts/engineering-historical-backfill-batch.schema.json`.

The required validation gate rejects unmanifested files, modifications or deletions of accepted history, repository/path/PR mismatches, forward receipts masquerading as reconstructed history, dangling rich records, and material receipts whose exact `id@revision` targets are missing or have the wrong type. Rich owners land before, or in the same bounded batch as, the receipts that depend on them.

`recordRefs` enumerates the exact union of rich revisions used by every receipt in the batch, including already-accepted owners. `addedRecordRefs` is its schema-bounded subset added by this pull request.

The authorization URL is not merely format-checked. Hosted validation reads the owning-repository comment, requires repository-owner authorship, and requires the exact sentence `I authorize publication of this bounded historical Engineering backfill batch under the residual-link policy.` This authorization approves the identified bounded batch; it does not authorize history rewrites, evidence deletion, visibility changes, or later batches.

The batch manifest is review metadata, not narrative content. Canonical historical receipts and rich Markdown remain the only content sources.

## Diagrams

Receipts do not require diagrams. A rich record may include a repository-native, public-safe diagram when verified structure, data flow, control flow, ownership, or before/after architecture is materially clearer visually. The coordinator authors that diagram from evidence and links it from the rich record; CI never invents a diagram from a diff.
