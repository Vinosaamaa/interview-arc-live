# Postmortem: Excalidraw Chrome Flashed After Board Changes

**Date:** 2026-08-12

**Status:** Resolved in the isolated combined app; merged-release verification
pending

**Severity:** Persistent interaction defect in the primary System Design work
surface

**Issue:** [#17](https://github.com/Vinosaamaa/interview-arc-live/issues/17)

**Fix PR:** [#44](https://github.com/Vinosaamaa/interview-arc-live/pull/44)

## Summary

After a user moved or edited a Board element, the Excalidraw toolbar and footer
could flash or appear to slide from the right edge back to their normal
positions. The canvas objects no longer snapped back after earlier bridge
fixes, but the editor chrome still moved.

An environment-gated, cross-layer diagnostic trace showed that persistence was
only the trigger. When the Board published `Unsaved board`, `Saving board…`,
and then `Unsaved board`, SwiftUI reconstructed its `NSViewRepresentable`.
The implementation reused the same `WKWebView` as the represented AppKit view.
During reparenting, the WebView briefly received a viewport exactly twice its
stable size. Excalidraw correctly recentered its fixed chrome for that false
viewport, then recentered it again when the real size returned.

The fix makes SwiftUI own a lightweight AppKit host view. The retained WebView
is now an AppKit-owned child of that host. The child keeps the last stable
viewport during the one reparent boundary and accepts ordinary resizing after
the boundary settles.

## User impact

- Moving, resizing, or editing an element could visibly flash the toolbar and
  bottom controls after pointer release.
- The top toolbar could look as though it rapidly slid from the right edge into
  place.
- Earlier variants also snapped objects back or changed the left rail width;
  those were separate bridge and layout defects fixed before this incident was
  isolated.
- This incident did not modify immutable Board revisions or erase the current
  draft.

## Detection

The decisive evidence came from one NDJSON trace joining:

- raw and Excalidraw pointer phases;
- native Board-control transitions;
- SwiftUI representable make, reuse, and dismantle events;
- AppKit host, superview, window, and frame changes; and
- per-animation-frame DOM geometry for the Excalidraw toolbar, menus, footer,
  product controls, root, and viewport.

The trace can be summarized by `scripts/report-board-chrome-diagnostics.py`.
It returns HOLD when the relevant chrome or viewport moves by more than 0.5
points during a recorded interaction.

## Measured before and after

| Measurement | Before | After |
| --- | ---: | ---: |
| Top-toolbar x | 336.50–952.48 (615.98 delta) | 336.50–336.50 (0.00 delta) |
| Top-toolbar width | 558.00–558.00 | 558.00–558.00 |
| Bottom-controls y | 1001.00–2058.00 (1057.00 delta) | 1001.00–1001.00 (0.00 delta) |
| Viewport width | 1231.00–2463.00 (1232.00 delta) | 1231.00–1231.00 (0.00 delta) |
| Viewport height | 1057.00–2114.00 (1057.00 delta) | 1057.00–1057.00 (0.00 delta) |

The final diagnostic capture held all five measurements stable across repeated
`Unsaved board` / `Saving board…` transitions and repeated SwiftUI wrapper
reconstruction. No editor-failure callback occurred.

## Timeline

All dates are 2026-08-12. Exact clock times are included only where preserved
in the diagnostic artifacts or command ledger.

| Time | Event |
| --- | --- |
| Earlier investigation | Native scene publication and reconciliation paths were corrected. Object snap-back stopped, but the toolbar/footer flash remained. |
| Earlier investigation | The native outer rail was made stable. The left side stopped changing size, but the embedded editor chrome still flashed. |
| 13:23 PDT | The first complete cross-layer trace captured the false 1231×1057 to 2463×2114 viewport transition and 615.98-point toolbar movement. |
| 13:23–13:28 PDT | The WebView was moved behind an AppKit-owned host boundary. The represented host, rather than the retained WebView, became SwiftUI-owned. |
| 13:28 PDT | The same diagnostic mutation and saving transition produced zero geometry delta for toolbar, footer, and viewport. |
| 13:32–13:55 PDT | The final source was rebuilt without the diagnostics-only mutation, strict-compiled, runtime-checked, and staged in an isolated signed app. The staged app showed the bundled Excalidraw canvas and controls without fallback. |
| 21:54 PDT | The obsolete diagnostics build was found still open and continuing its temporary mutation route. It was stopped by exact process identity. Only the clean no-mutation staged build was reopened. |
| After 21:54 PDT | The owner verified the clean staged canvas no longer flashed and that element selection worked normally. |

## Root cause

The retained `WKWebView` crossed an ownership boundary it did not satisfy.
SwiftUI expected to own the frame and lifecycle of the view returned by
`NSViewRepresentable.makeNSView`. The room-owned bridge also retained and
reused that exact represented WebView across SwiftUI reconstruction.

On a saving-status update, SwiftUI dismantled and remade the wrapper. While the
retained WebView moved between wrapper contexts, AppKit briefly applied a
backing-scale-sized frame: both dimensions were exactly doubled. Excalidraw's
toolbar and footer use viewport-relative placement, so their DOM geometry
changed even though the logical Board and its objects had not changed.

The root cause was therefore not Excalidraw saving, CSS animation, object
geometry, or a page reload. It was direct reuse of a SwiftUI-represented
WebView across AppKit reparenting.

## Why earlier approaches did not fix it

1. **Suppressing ordinary full-scene reloads** removed white reload flashes and
   object snap-back. It did not prevent the retained WebView's native frame
   from changing during wrapper reconstruction.
2. **Advancing the native scene baseline before model mutation** closed a
   synchronous scene-echo race. It did not change AppKit view ownership.
3. **Stabilizing native rails and the left pane** stopped neighboring SwiftUI
   layout from changing. The remaining movement was entirely inside the
   WebView viewport.
4. **Retaining the WebView coordinator** avoided recreating the web session,
   but retaining the represented WebView itself created the reparenting
   failure mode.
5. **Rejecting only transient zero-sized frames** prevented a full collapse,
   but the failing frame was nonzero and exactly twice the stable viewport.
   Directly overriding the represented WebView's frame also fought SwiftUI's
   ownership contract, so it was not an acceptable final design.
6. **CSS and toolbar-position guesses** were not evidence-based. The DOM was
   responding correctly to a false native viewport; changing CSS would only
   hide one symptom.
7. **The first diagnostics build failed** because a debug-only JavaScript
   layout variable was undeclared. The production path was unaffected. The
   variable was declared and the diagnostic route was rerun before its output
   was accepted.

## Resolution

- `ExcalidrawBoardHostView` is the only view SwiftUI represents and sizes.
- The room-retained WebView is an AppKit-owned child that can move between host
  instances only after the destination host has a window.
- The host preserves the last stable viewport during the single reparent
  settle boundary and rejects an exact 2× backing-scale artifact there.
- Genuine later resizing, including a real 2× resize, remains allowed.
- Readiness no longer changes the Board's SwiftUI structure. Only an actual
  editor failure switches to the native fallback.
- The environment-gated recorder remains available for future diagnosis, but
  no automatic diagnostic move ships in the web bundle.

## What went well

- The final investigation stopped treating persistence status as the root
  cause and traced native plus DOM geometry in the same time series.
- An isolated profile protected the user's normal Board state during repeated
  deterministic mutations.
- The before trace was retained and the report tool correctly rejects it,
  while the fixed trace passes with zero geometry delta.
- The final staged app combined the changed Swift binary and bundled web
  resources; it was not a web-only injection into an old native binary.

## What did not go well

- Several fixes were promoted before the exact visual failure had a measurable
  invariant.
- Source, codec, and resource tests passed while the AppKit/WebKit layout
  boundary remained untested.
- Hosted CI was repeatedly used before local interaction proof, creating long
  waits without improving diagnosis.
- Computer Use could inspect the exact staged app but its drag operation later
  failed with `noWindowsAvailable`. That automation failure must not be
  presented as either a product pass or product failure.
- The obsolete diagnostics app was left open too long. Its temporary mutation
  route interfered with a later selection check and initially made the clean
  selection behavior ambiguous. Test applications must be stopped immediately
  when their evidence has been captured.

## Corrective and preventive actions

| Priority | Action | Status |
| --- | --- | --- |
| P0 | Represent an AppKit host, not the retained WebView, across SwiftUI reconstruction | Complete locally |
| P0 | Gate toolbar/footer/viewport geometry from an NDJSON interaction trace | Complete locally |
| P0 | Add focused viewport-policy coverage for empty and 2× reparent artifacts while preserving genuine resize | Complete locally |
| P1 | Keep the diagnostics route environment-gated and free of automatic production mutations | Complete locally |
| P1 | Stop obsolete diagnostic processes before opening the clean acceptance build | Complete locally |
| P1 | Require one combined native+web isolated staged app before hosted CI for embedded-canvas changes | Documented in coordinator fastlane |
| P1 | Require pointer, scene acceptance, persistence status, host lifecycle, and DOM geometry in one trace for future canvas flashes | Documented in coordinator fastlane |
| P1 | Run an exact merged-artifact pointer smoke after merge authorization and hosted CI | Pending release authorization |

## Durable lessons

1. A viewport-relative web UI can flash without a React remount or page reload.
   Measure the native viewport and DOM chrome in the same frames.
2. A retained `WKWebView` may outlive SwiftUI wrappers, but it must be an AppKit
   child behind a stable represented host. Do not reuse it directly as the
   represented view.
3. A status update is a trigger, not necessarily a cause. Follow the complete
   path from accepted scene to persistence publication to SwiftUI/AppKit
   lifecycle before changing CSS or debounce behavior.
4. Accessibility actions prove semantic behavior, not raw pointer behavior.
   Use a physical pointer trace or a deterministic, isolated diagnostic
   mutation for interaction timing.
5. Build the bundled web editor in seconds, inject it only into a disposable
   app containing the exact native bridge, operate it locally, and run cold CI
   once after the interaction invariant passes.

## Release limitation

The source, strict compiler gates, focused runtime contract, before/after trace,
and isolated staged-app startup are complete. PR and merged-main CI, exact
merged-artifact pointer verification, installation, and issue closure remain
pending and require their normal authorization and release gates.

## Related incident

- [Board Bootstrap Overwrote an Unsaved Draft](2026-08-12-board-bootstrap-overwrite.md)

## Glossary

- **Chrome:** the editor's controls around the drawing surface, such as its
  toolbar, menus, and footer; not the Google Chrome browser.
- **Reparenting:** moving a native child view from one AppKit superview to
  another.
- **Backing scale:** the conversion between logical points and display pixels.
  The failing transient frame was exactly 2× the stable logical viewport.
- **Represented view:** the AppKit view whose creation and updates are owned by
  SwiftUI through `NSViewRepresentable`.
