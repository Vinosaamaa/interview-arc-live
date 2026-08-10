# ADR 0007: Retain one room across full and compact Presentations

- Status: Accepted
- Date: 2026-08-09
- Issue: #16

## Context

The system-design room can remain active while the candidate works in another
application. Recreating its SwiftUI root, opening a second model, or using a
second scene would lose ephemeral window state and could duplicate recording,
provider, recovery, or speech side effects.

## Decision

The application process creates one `SystemDesignRoomModel` and asks it to
open once. A deep `InterviewRoomPresentationCoordinator` owns exactly one
full `NSWindow`, one nonactivating compact `NSPanel`, and both SwiftUI hosting
trees for the process lifetime. Full and compact roots receive the same model
identity and only forward its existing actions.

Collapse orders the retained full window out before showing the panel without
activation. Expand orders the panel out, restores the retained full frame and
valid first responder, and deliberately activates the existing full window.
Dock reopen and application commands route to that same window. The panel
does not join every Space or full-screen auxiliary spaces, and its process-
local position is clamped after display changes. Its fixed width and bounded
height reconcile to SwiftUI's current fitting size; content becomes vertically
scrollable at the maximum so accessibility text and stacked controls remain
reachable without overlap.

An unfinished full-window close is guarded by Continue compact, End interview,
and Cancel. End calls the existing durable finish path once and closes only
after success. Close resolution is single-flight while that call awaits, and
process termination wins if it occurs before the call returns. Phases Core
does not currently permit to finish remain visible with the existing safe
error. Command-Q remains process termination and does not fabricate completion.

## Consequences

Window frame, split position, transcript scroll position, and live SwiftUI
state survive compact presentation because the full tree is hidden rather
than rebuilt. The coordinator centralizes identity, ordering, focus, close,
reopen, screen-clamping, and termination rules without adding a Core command,
provider Adapter, persistence field, or test-only window Seam. Headed release
verification remains necessary for external-app focus, VoiceOver, Spaces, and
exact installed-artifact behavior.
