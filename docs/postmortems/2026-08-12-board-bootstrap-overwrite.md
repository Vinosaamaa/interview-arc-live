# Postmortem: Board Bootstrap Overwrote an Unsaved Draft

**Date:** 2026-08-12  
**Status:** In review; merged-release verification pending  
**Severity:** Data loss in a local unsaved Board draft  
**Issue:** [#17](https://github.com/Vinosaamaa/interview-arc-live/issues/17)  
**Fix PR:** [#43](https://github.com/Vinosaamaa/interview-arc-live/pull/43)

## Summary

The bundled Excalidraw editor could send its default empty bootstrap scene to
the native Board model before the native document had been loaded into the web
editor. During reproduction, that path replaced a 15-element unsaved local
draft with an empty draft. Two immutable saved revisions remained intact.

The same bridge also scheduled disruptive full loads after ordinary accepted
edits and reapplied stale zoom/tool state during canonical reconciliation. That
produced the reported white flashes, disappearing canvas, and zoom reset.

## User impact

- Ordinary move/edit operations could flash or temporarily blank the canvas.
- Zoom could return to the previous native value after reconciliation.
- The bootstrap race could replace an unsaved draft before the native Board
  became the web editor's baseline.
- Immutable saved revisions were not mutated by this incident.

## Detection

The incident became concrete only after operating the staged application. An
accessibility-triggered node move first left the visible web canvas blank while
the native projection still reported 15 elements. A subsequent app-state read
reported zero native elements, and the private manifest confirmed an empty
draft with two intact three-element revisions.

Earlier source checks and a web-resource-only staged smoke did not prove the
native-web lifecycle because that staged copy still contained the previous
native Swift binary.

## Timeline

All times are Pacific on 2026-08-12. Exact timestamps are included only where
captured by tools or persisted evidence.

| Time | Event |
| --- | --- |
| Before 07:17 | A web-resource-only staged copy was used as visual evidence even though its native bridge binary was older than the source under review. |
| 07:17:30 | The session manifest was durably written with an empty draft after the bootstrap overwrite. |
| 07:18–07:20 | Native Undo was attempted twice and did not restore the unsaved draft. The application was closed and the manifest was backed up read-only. |
| 07:20–07:28 | Publication was closed until native-baseline adoption; a native-side baseline guard and focused bootstrap regression were added. |
| 07:24–07:30 | A real local WKWebView probe exposed and then verified the separate zoom-reconciliation defect and toolbar bounds. |
| 07:32–07:36 | Replacement commits were pushed to PR #43; automated review findings were addressed and all threads resolved. |

## Architecture and failure path

```text
Excalidraw React mount
        |
        | onChange(default empty scene)
        v
scene publication (incorrectly open)
        |
        v
Swift WKScriptMessageHandler
        |
        v
Session-owned Board draft = empty

Native load/reconcile could then race back through the same path, causing
full-load flashes and viewport/tool resets.
```

The native `InterviewRoomSession` owns the durable Board. Excalidraw is a local
editor adapter and must not become authoritative until the native document has
been loaded and adopted as its baseline.

## Root cause

The bridge had no explicit bootstrap state. The publication controller treated
Excalidraw's first `onChange` callback as a user-authored scene even though the
native source of truth had not yet crossed the bridge.

Three adjacent defects amplified the behavior:

1. The native loaded-document baseline advanced after the observed model
   callback, allowing synchronous SwiftUI re-entry to queue a full reload.
2. Native reconciliation could overlap pointer/text input without preserving
   the newer user scene.
3. Reconciliation applied stale zoom/tool metadata instead of limiting itself
   to canonical geometry and then applying the newest authoritative state.

## Contributing factors

- The first staging method replaced only the web resource inside an older app
  binary. It could prove asset rendering, but not the changed native bridge.
- The staged app shared the normal Application Support store instead of an
  isolated smoke profile.
- Automated coverage exercised a post-ready nonempty load, but did not assert
  that the pre-baseline empty scene was rejected.
- Visual readiness was treated as stronger evidence than a real move/edit/zoom
  interaction through the combined native and web build.

## Resolution

PR #43 now:

- keeps web publication closed until the first native scene is adopted;
- rejects native scene messages until the coordinator has sent a baseline;
- advances the native baseline before observed model mutation;
- cancels stale full loads when canonical reconcile is sufficient;
- defers native updates during pointer work and preserves edits received during
  a native update;
- uses Excalidraw's scalar scene version for duplicate suppression;
- reconciles canonical geometry without changing the live viewport/tool, then
  sends the newest authoritative native state;
- verifies toolbar/footer/action bounds in a real WKWebView probe.

## Regression prevention

- A focused test proves a bootstrap empty scene cannot publish before native
  adoption.
- The runtime probe requires a nonempty scene, zero unsolicited scene events,
  preserved 125% zoom, and visible non-overlapping controls.
- Native and web layers both enforce the baseline boundary.
- Future staged UI tests must use the combined native+web build and an isolated
  Application Support profile. Web-only injection must be labeled asset-only
  evidence and cannot certify native lifecycle behavior.
- Exact merged-main pointer move, text edit, zoom, quit/relaunch, and persistence
  checks remain required before installation and issue resolution.

## Recovery and limitations

The two immutable saved revisions remain available. The exact 15-element
unsaved draft had no independent durable copy and could not be reconstructed
truthfully from the saved revisions, exports, or command receipts. The current
manifest was preserved in a private temporary backup for diagnosis; it is not
source or release evidence.

## Follow-up

- Complete hosted CI for the exact PR #43 head.
- After explicit merge authorization, smoke the exact merged-main artifact
  from an isolated profile before installation.
- Verify move, text edit, zoom in/out/reset, quit/relaunch, saved revision
  integrity, and no unsolicited empty-scene write.
- Record merged artifact identity and installed verification on issue #17, then
  finalize this postmortem and close the issue only when all acceptance criteria
  are satisfied.

## Glossary

- **Baseline:** the native Board document the web editor has applied and adopted
  as its known source-of-truth state.
- **Canonical reconciliation:** replacing normalized IDs, bounds, or connector
  routes without treating that replacement as a new user edit.
- **Bootstrap scene:** Excalidraw's initial default scene emitted while its React
  component mounts, before Interview Arc loads the durable Board.
