# Engineering pull-request history protocol

Engineering history has two deliberately separate layers. The separation keeps the complete timeline factual and inexpensive while preserving deep technical narrative where it is useful.

| Layer | Coverage | Canonical source | Purpose |
| --- | --- | --- | --- |
| Pull Request Receipt | One compact receipt for every merged pull request | `docs/engineering/changes/pr-<number>.md` | Complete chronological change inventory |
| Rich Engineering Record | Material changes or a reviewed cluster of related changes | `docs/engineering/records/*.md` | Architecture, decisions, incidents, retrospectives, and capability context |

The receipt contract is versioned by `docs/contracts/engineering-pull-request-receipt.schema.json`. The six rich record types remain Change Note, ADR, Architecture Review, Feature Retrospective, Postmortem, and Capability Dossier. Tooling must not silently reinterpret an accepted v1 document.

## Forward authoring protocol

The implementation coordinator owns the receipt as part of the pull request. The user does not need to request a separate Journal operation.

1. Open or identify the pull request so its Live repository number is known.
2. Add exactly one compact receipt at `docs/engineering/changes/pr-<number>.md`.
3. Record a public-safe title and one factual summary paragraph of at most 280 characters.
4. Classify a small or non-material pull request as `none` and leave `richRecordRefs` empty.
5. For a material pull request, add the appropriate rich record and link its exact `id@revision` from `richRecordRefs`.
6. Let CI validate the classification, receipt, and rich-record linkage. Arc deterministically projects reviewed Live receipts from an exact trusted commit pin.
7. Merge and release through Live's normal verification workflow.

CI does not invent motivation, architecture, root cause, impact, prose, or diagrams from a diff. The coordinator authors the factual receipt and any required rich record while it has the implementation context. Canonical state is Markdown in Git; generated JSON and HTML are disposable Arc projections, not a database or second source of narrative truth.

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

Do not inflate a small receipt into a rich record. Do not compress architecture, incident causality, or a multi-PR migration into a 280-character receipt.

## Diagrams

Receipts do not require diagrams. A rich record may include a repository-native, public-safe diagram when verified structure, data flow, control flow, ownership, or before/after architecture is materially clearer visually. The coordinator authors that diagram from evidence and links it from the rich record; CI never invents a diagram from a diff.
