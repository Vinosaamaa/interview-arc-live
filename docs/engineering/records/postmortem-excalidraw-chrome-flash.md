---
schemaVersion: 1
id: postmortem-excalidraw-chrome-flash
revision: 1
type: postmortem
status: accepted
title: Excalidraw Chrome Flash and Scene Snap-back
repository: interview-arc-live
capabilityIds: ["system-design-board","local-excalidraw-editor"]
createdAt: 2026-08-12
reconstructed: false
confidence: verified
unknowns: []
modules: ["board-editor-adapter","interview-room-presentation"]
interfaces: ["board-document-projection","board-scene-publication","swiftui-appkit-host"]
seams: ["native-to-web-board-projection","web-to-native-scene-publication","swiftui-to-appkit-view-hosting"]
adapters: ["bundled-excalidraw-editor","wkwebview-board-host","native-board-fallback"]
relatedRecords: []
decisions: []
incidents: []
features: []
capabilities: ["offline-system-design-canvas","durable-board-draft","immutable-board-revisions"]
amends: []
supersedes: []
learningRefs: []
sources: [{"label":"System Design Board issue #17","url":"https://github.com/Vinosaamaa/interview-arc-live/issues/17","kind":"issue"},{"label":"Excalidraw flash repair PR #44","url":"https://github.com/Vinosaamaa/interview-arc-live/pull/44","kind":"pull-request"}]
verification: {"state":"verified","evidenceRefs":["issue:17","pull-request:44","diagnostic:board-chrome-ndjson","report:board-chrome-diagnostics","staged-app:isolated-profile"]}
visibility: public-safe
publicationEligibility: eligible
issue: 17
pr: 82
release: null
run: null
---
# Excalidraw Chrome Flash and Scene Snap-back

## Executive summary

The embedded System Design canvas had two related user-visible failures. Earlier builds could move an element and then snap it back to its previous position. After the scene bridge was corrected, the objects remained stable but Excalidraw's top toolbar and bottom controls still flashed or appeared to slide rapidly into place after pointer release.

The failures crossed three ownership boundaries: Excalidraw scene state, the native `BoardDocument`, and SwiftUI/AppKit view hosting. Several plausible local fixes reduced symptoms without satisfying the complete interaction invariant. The decisive investigation joined browser pointer and DOM geometry events with native Board state, persistence status, SwiftUI wrapper lifecycle, AppKit hierarchy, and WebView viewport frames in one environment-gated NDJSON trace.

The trace proved two distinct causes:

1. the scene bridge could echo a just-accepted document back into Excalidraw before its native baseline advanced, causing an unnecessary reconciliation and snap-back; and
2. SwiftUI directly represented and later reconstructed the retained `WKWebView`, briefly giving it a viewport exactly twice the stable logical size. Excalidraw correctly repositioned its viewport-relative chrome for that false frame, then repositioned it again when the real frame returned.

The repair advances the bridge baseline before SwiftUI re-entry, avoids controls-only scene churn, and places the retained WebView behind an AppKit-owned host view. SwiftUI now owns only the lightweight host. The host preserves the last stable child viewport across the single reparent boundary while allowing genuine later resizing.

A follow-up selection defect shared the same bridge boundary. A newly drawn
Excalidraw element has a temporary web ID before native code assigns its
canonical Board ID. Re-entrant observation could prune that mapping before the
canonical reconcile completed, so a later callback allocated a different Board
ID and selection appeared to disappear or jump. The final repair retains the
web-ID-to-Board-ID ledger through the accepted callback and rejects stale
observations until publication returns.

## Impact

- Moving, resizing, or editing a Board element could visibly flash the toolbar and footer after pointer release.
- Earlier iterations could reconcile the accepted element back to a stale native location.
- The toolbar could appear to slide quickly from the right edge into its stable centered position.
- Repeated status changes made the defect feel like saving itself was repainting the entire canvas.
- Immutable saved Board revisions were not rewritten by this incident. One separate bootstrap incident had already demonstrated a real unsaved-draft loss path and is documented independently.

## Evidence and detection

Source builds, codec tests, resource probes, and static screenshots all passed while the defect remained. None observed the timing relationship among scene acceptance, native persistence publication, SwiftUI reconstruction, AppKit reparenting, and DOM layout.

The final diagnostic recorder captured, in one ordered trace:

- raw and Excalidraw pointer phases;
- web scene revisions and native acceptance;
- Board status and persistence transitions;
- representable make, update, reuse, and dismantle events;
- AppKit host, superview, window, and frame changes; and
- per-animation-frame geometry for the Excalidraw toolbar, menus, footer, product controls, root, and viewport.

The bounded report rejects a relevant interaction whenever the viewport or editor chrome moves by more than 0.5 points after the gesture settles.

| Measurement | Failing trace | Fixed trace |
| --- | ---: | ---: |
| Top-toolbar x delta | 615.98 pt | 0.00 pt |
| Top-toolbar width delta | 0.00 pt | 0.00 pt |
| Bottom-controls y delta | 1057.00 pt | 0.00 pt |
| Viewport width | 1231 → 2463 pt | 1231 → 1231 pt |
| Viewport height | 1057 → 2114 pt | 1057 → 1057 pt |

The exact 2× width and height transition isolated the backing-scale-shaped host failure. No React remount, page navigation, or Excalidraw reload was required to produce the flash.

## Timeline

All events below occurred on 2026-08-12. Exact times are included only when retained in the diagnostic record.

| Time | Event |
| --- | --- |
| Earlier investigation | Bootstrap publication and native reconciliation were hardened. Unsaved draft preservation improved, but pointer-time reprojection remained. |
| Earlier investigation | The bridge baseline was advanced before observed model mutation. Object snap-back stopped; editor chrome still moved. |
| Earlier investigation | Neighboring SwiftUI rails and the room divider were stabilized. The remaining movement was isolated inside the WebView viewport. |
| 13:23 PDT | A complete cross-layer trace captured the 1231×1057 to 2463×2114 transient viewport and 615.98-point toolbar movement. |
| 13:23–13:28 PDT | The retained WebView was moved behind an AppKit-owned represented host boundary. |
| 13:28 PDT | The same diagnostic mutation and persistence-status transition produced zero toolbar, footer, and viewport geometry delta. |
| 13:32–13:55 PDT | Production source was rebuilt without the diagnostics-only mutation, strict-compiled, runtime-checked, and staged in an isolated application profile. |
| Later owner verification | The clean staged app no longer flashed, and element selection behaved normally. |
| 2026-08-17 follow-up | A clean one-element trace reproduced pre-reconcile identity churn; a stable identity ledger and re-entrant observation gate were added. |
| 2026-08-17 verification | A fresh isolated app created, reselected, moved, autosaved, and retained one selected element with zero chrome or viewport delta. |

## Root cause

### Scene snap-back

The web editor published a changed scene synchronously. Native code accepted it and updated SwiftUI, but the coordinator's loaded-document baseline was advanced too late. Re-entrant observation therefore treated the same accepted document as a new native change and sent it back through `updateScene`. That unnecessary echo could interrupt or reverse the web interaction.

### Chrome flash

The room retained and reused the exact `WKWebView` returned from `NSViewRepresentable.makeNSView`. SwiftUI therefore believed it owned the represented view's frame and lifecycle while the room bridge also expected to retain it across wrapper reconstruction.

When Board status changed, SwiftUI dismantled and remade the wrapper. During that ownership transition AppKit briefly applied a frame whose dimensions were exactly twice the stable logical viewport. Excalidraw's toolbar and footer use viewport-relative positioning, so they moved correctly for the false viewport and then moved back when the true size returned.

Persistence was the trigger for SwiftUI publication, not the geometric root cause. CSS animation, save latency, and Excalidraw itself were not responsible for the false native viewport.

### Follow-up selection loss

The first scene for a newly drawn shape carried only Excalidraw's temporary web
ID. Native decoding assigned a canonical Board ID, but another scene could
arrive before reconciliation replaced the web element ID. During the
synchronous model publication, SwiftUI could also re-enter the coordinator
with a stale document. That observation pruned the temporary-to-canonical ID
mapping, so the next decode allocated another Board ID for the same web shape.

This was not an Excalidraw focus timeout. The trace showed the selected web
shape remaining present while native selection moved among canonical IDs and
then became empty. Persisting the identity ledger, rolling it back only when a
scene is rejected, and suppressing stale observations for the duration of the
accepted callback removed the churn.

## Why earlier approaches were insufficient

1. **Suppressing ordinary full-scene reloads** removed white reload flashes and snap-back paths, but it could not stop the represented WebView's native frame from changing during wrapper reconstruction.
2. **Advancing the scene baseline earlier** closed the synchronous document echo. It fixed object stability but did not change AppKit ownership.
3. **Stabilizing the outer rails and room divider** eliminated neighboring layout motion. The embedded viewport still doubled independently.
4. **Retaining the WebView coordinator** preserved the web session, but directly retaining the represented view created the reparenting failure mode.
5. **Rejecting only zero-sized frames** prevented collapse but missed the failing nonzero 2× frame.
6. **Overriding the represented WebView frame** fought SwiftUI's ownership contract and was not a safe architecture.
7. **Changing CSS or toolbar placement** would have hidden a symptom. The DOM was responding correctly to false native geometry.
8. **Running cold hosted CI after every visual guess** verified compilation repeatedly but provided no pointer-time or viewport evidence, substantially slowing diagnosis.
9. **Using an old native binary with a new web bundle** could not validate the native/web ownership fix. The accepted local loop used one combined native-and-web staged app.

## Resolution

- Advance the accepted native Board baseline before publishing observable model state.
- Keep semantic overlay updates outside the parent Excalidraw render cycle.
- Ignore controls-only scene mutations and use non-history reconciliation for genuine native changes.
- Preserve world-space editing geometry; translate into deterministic revision/export coordinates only at the durable boundary.
- Represent `ExcalidrawBoardHostView`, not the retained WebView, through SwiftUI.
- Keep the retained WebView as an AppKit-owned child of the current host.
- During the one reparent settle boundary, preserve the last stable viewport and reject the exact 2× backing-scale artifact.
- Continue accepting real later resizes, including legitimate large resizes.
- Keep readiness from changing the Board's SwiftUI structure; only a genuine editor failure selects the native fallback.
- Preserve the web-ID-to-Board-ID ledger until canonical reconciliation, and
  prevent stale re-entrant observations from pruning it.

## Corrective and preventive actions

| Priority | Action | Status |
| --- | --- | --- |
| P0 | Advance the bridge baseline before SwiftUI re-entry | Complete locally |
| P0 | Put the retained WebView behind an AppKit-owned represented host | Complete locally |
| P0 | Gate toolbar, footer, and viewport geometry using one interaction trace | Complete locally |
| P0 | Cover empty and 2× reparent artifacts while preserving genuine resize | Complete locally |
| P1 | Keep diagnostics environment-gated and free of automatic production mutation | Complete locally |
| P1 | Stop obsolete diagnostic processes immediately after evidence capture | Adopted |
| P1 | Build and operate one combined native+web isolated app before cold CI | Adopted in coordinator fastlane |
| P1 | Require pointer, scene, persistence, host lifecycle, and DOM geometry in one trace for future canvas flashes | Adopted in coordinator fastlane |
| P1 | Keep a newly created element's canonical ID stable across pre-reconcile scenes | Complete locally |
| P1 | Run exact merged-artifact pointer verification after authorized merge | Pending release verification |

## Durable lessons

1. A viewport-relative web UI can flash without a React remount or page reload. Measure native viewport geometry and DOM chrome in the same frames.
2. A retained `WKWebView` may outlive SwiftUI wrappers, but it must remain an AppKit child behind a stable represented host. Do not reuse it directly as the represented view.
3. A status update is a trigger, not necessarily a cause. Trace scene acceptance, persistence publication, SwiftUI/AppKit lifecycle, and DOM layout before changing save behavior or CSS.
4. Accessibility actions establish semantic behavior, not physical pointer timing. Use a real pointer trace or a deterministic isolated diagnostic mutation.
5. For bundled-web changes, rebuild the web bundle in seconds, combine it with the exact native bridge in a disposable app profile, operate it locally, and run cold CI once after the interaction invariant passes.
6. Do not call a source build, static screenshot, or old-binary resource injection visual acceptance. The evidence must exercise the exact combined native and web code paths.
7. In a bidirectional editor bridge, visual identity and canonical identity are
   separate until reconciliation. Persist their mapping across every accepted
   callback, and test creation, autosave, reselection, and movement before
   declaring focus stable.

## Release boundary

The source fix, focused runtime contracts, clean diagnostic trace, and isolated
staged-app verification are complete on PR #82. Hosted current-head checks,
merged-main verification, exact merged-artifact pointer verification,
installation, issue resolution, and closure remain pending.

## Glossary

- **Editor chrome:** controls around the drawing surface, such as toolbars, menus, and footer controls; it does not refer to the Google Chrome browser.
- **Reparenting:** moving a native child view from one AppKit superview to another.
- **Backing scale:** the conversion between logical points and display pixels. The failure briefly applied an exact 2× viewport.
- **Represented view:** the AppKit view whose lifecycle is owned by SwiftUI through `NSViewRepresentable`.
