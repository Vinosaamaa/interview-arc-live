# Interview Arc Live Fastlane

Use this lane when the user explicitly asks for a fast fix, fast iteration,
Fastlane, or to skip unnecessary work. It supplements this repository's issue
lifecycle and does not lower the correctness bar for the changed behavior.

## Objective

Turn one observed failure into one locally proven release candidate before
using the slow hosted macOS package pipeline. Fastlane optimizes the feedback
loop, not the evidence standard.

## Required path

1. Reuse the owning issue, branch, and clean issue worktree when they already
   exist. Update the issue once with corrected scope and avoid duplicate plans.
2. Start from current `main`. Inspect only the affected contract, source,
   diagnostics, and focused tests. Preserve unrelated work.
3. Reproduce a bug end to end as the user experiences it before changing code.
   For a canvas interaction, capture pointer input, accepted scene, persistence
   publication, SwiftUI/AppKit host lifecycle, child-WebView frame, and DOM
   toolbar/footer geometry in one ordered diagnostic trace.
4. Make the smallest complete change. Keep ordering and recovery rules in the
   owning module rather than distributing compensating fixes across callers.
5. Run the narrowest meaningful regression tests plus parser, lint, generated-
   resource, and diff checks for the files that changed. Do not repeatedly run
   broad equivalent suites without a concrete failure reason.
6. Prove UI and bundled-resource changes locally before hosted CI:
   - Resource injection into an existing app is valid only when the native
     binary and native-to-web bridge are unchanged.
   - If native and web layers changed, build one disposable app containing both
     exact layers. Ad-hoc sign that copy, launch only its exact path, and use an
     isolated state root; never read or write the normal Application Support
     store during a smoke test.
   - Use real pointer input for pointer defects. Accessibility movement is
     semantic evidence, not proof of raw dragging behavior.
   - For an embedded canvas, require one accepted scene, one retained web
     session, and stable viewport/chrome across the complete gesture. SwiftUI
     wrapper reconstruction is allowed; a retained `WKWebView` must be an
     AppKit child behind the represented host, not the directly reused
     represented view.
7. Open one PR only after focused checks and the required headed smoke pass.
   Review the exact diff and actionable automated feedback. Push a correction
   only for new evidence, not as a substitute for local reproduction.
8. Run the hosted macOS pipeline once for the locally approved candidate. If
   the same user instruction authorizes merge and release, merge after required
   checks pass, verify exact merged `main`, and test the exact packaged artifact.
9. Record the outcome, rollback point, hosted receipt, and worktree/branch
   cleanup in the issue. Do not attach engineering ledgers to practice
   activities or transcripts.

## Canvas diagnostic invariant

The Excalidraw trace and `scripts/report-board-chrome-diagnostics.py` are the
standard regression path for canvas flashing, snap-back, selection loss, or
toolbar movement. Do not guess at CSS, saving, or scene reconciliation when the
trace can distinguish them. The report must show stable WebView viewport and
chrome geometry after the gesture settles; scene identity and native baseline
must advance without an echo reload.

## Stop or escalate

Leave Fastlane for the Reliability lane when evidence reveals silent data loss
or corruption, authentication or permission failure, credential exposure,
recording/transcription loss, crash, destructive recovery, or an irreversible
migration. State the escalation once and continue through the owning issue.

Fastlane never supplies missing authorization for merge, installation,
release, destructive mutation, practice-result changes, submissions, or
activity completion.
