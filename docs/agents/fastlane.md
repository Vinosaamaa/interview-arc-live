# Interview Arc Live Fastlane

Use this lane for an explicit fastlane, fast-fix, or skip-unnecessary-work
request. It shortens feedback time, never correctness or authorization.

1. Reuse the owning issue, branch, and clean worktree; start from current
   `main` and preserve unrelated work.
2. Reproduce the user-visible failure end to end before editing. Inspect only
   the owning contract, source, diagnostics, and focused tests.
3. For canvas bugs, use the Excalidraw trace and
   `scripts/report-board-chrome-diagnostics.py`; do not guess. Trace pointer
   input, accepted scene, persistence, host/WebView lifecycle and frame, and
   toolbar/footer geometry.
4. Make the smallest complete fix and run focused regression, parser/lint,
   generated-resource, and diff checks. Avoid repeated equivalent broad suites.
5. Prove UI changes locally before CI. Web-resource injection is valid only
   when native code and the native/web bridge are unchanged. Otherwise build
   one exact disposable app, ad-hoc sign it, use an isolated state root, and
   test the real interaction with real pointer input.
6. An embedded-canvas pass requires one accepted scene, one retained web
   session, and stable viewport/chrome after the gesture. Keep a retained
   `WKWebView` as an AppKit child, not a reused represented view.
7. Open one PR only after local proof. Run hosted macOS CI once for that exact
   candidate; merge, install, or release only with explicit authorization.
8. Record the outcome, rollback point, hosted receipt, and verified worktree/
   branch cleanup in the owning issue. Never attach it to practice transcripts.

Escalate to Reliability for possible data loss/corruption, credential or
privacy exposure, recording/transcription loss, crashes, destructive recovery,
or irreversible migration. Fastlane never grants missing authorization.
