---
schemaVersion: 1
id: change-note-live-historical-backfill-gate
revision: 1
type: change-note
status: accepted
title: Live Validates Bounded Historical Engineering Batches
repository: interview-arc-live
capabilityIds: ["engineering-evidence"]
createdAt: 2026-08-16
reconstructed: false
confidence: verified
unknowns: []
modules: ["engineering-policy"]
interfaces: ["engineering-historical-backfill-batch"]
seams: ["pull-request-receipt-to-historical-manifest"]
adapters: ["github-issue-comment-authorization"]
relatedRecords: ["capability-dossier-deep-interview-room-session@1"]
decisions: []
incidents: []
features: []
capabilities: ["bounded-historical-publication","residual-link-authorization"]
amends: []
supersedes: []
learningRefs: []
sources: [{"label":"Live historical backfill issue #52","url":"https://github.com/Vinosaamaa/interview-arc-live/issues/52","kind":"issue"}]
verification: {"state":"verified","evidenceRefs":["issue:52","parser:passed"]}
visibility: public-safe
publicationEligibility: eligible
issue: 52
pr: null
release: null
run: null
---
# Live Validates Bounded Historical Engineering Batches

Live already required one numbered forward receipt. Historical publication still needed a bounded, add-only gate so reconstructed receipts could land without rewriting accepted history or inferring missing evidence.

## Change

The Live pull-request workflow now vendors the shared historical-batch contract and validates a publication pull request against it. A historical PR keeps one forward `reconstructed: false` receipt classified `None`, adds at most twenty reconstructed receipts, and may add at most eight reconstructed rich records. The numbered manifest must enumerate those documents exactly, stay add-only against the pull-request base, and cite an owning-repository comment whose entire body is the residual-link authorization sentence.

Hosted validation reads that comment through GitHub and requires repository-owner authorship. The gate does not authorize history rewrites, evidence deletion, visibility changes, or later batches. Product runtime behavior is unchanged.
