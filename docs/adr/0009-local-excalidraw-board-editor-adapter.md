# ADR 0009: Embed Excalidraw behind the native Board Document Adapter

- Status: Accepted
- Date: 2026-08-10
- Amended: 2026-08-12
- Issue: #17

## Context

The native Board already owns bounded system-design semantics, immutable
Revisions, Turn evidence, recovery, and deterministic Draw.io/SVG/PNG exports.
Its custom drawing implementation does not provide the mature selection,
alignment, keyboard, freehand, and manipulation behavior expected from a
general canvas. Replacing the Board model with a third-party scene format
would make persisted interview evidence and exports depend on that library's
private schema and upgrade behavior.

The evaluated candidates were Draw.io, Excalidraw, tldraw, React Flow, Fabric,
and PencilKit. Draw.io remains the editable export format, but its documented
embed protocol targets a hosted editor and its local application distribution
is much larger than the required canvas slice. tldraw's production license is
not compatible with this product. React Flow and Fabric are lower-level canvas
primitives, and PencilKit covers ink rather than architecture editing.

## Decision

Interview Arc Live bundles `@excalidraw/excalidraw` 0.17.6 and its exact React
dependencies as local static resources inside the signed application. A
nonpersistent `WKWebView` loads those bytes through a private URL scheme. A
content security policy, WebKit content rule, navigation delegate, and window
delegate reject HTTP, HTTPS, WebSocket, file, data, embed, link, and new-window
navigation. Runtime use does not contact an Excalidraw or Interview Arc host.

The native `BoardDocument` remains canonical. A narrow codec projects only
bounded rectangle, diamond, ellipse, connector, line/freehand, and text
elements into boxes, connectors, labels, and strokes and reconstructs
only those supported elements. Existing native identities can be retained;
pasted or fabricated identities receive deterministic native IDs. Unsupported,
oversized, invalid, or out-of-bounds input is rejected before persistence.
Every accepted change enters the existing native undo/redo and draft
persistence path. Native Revisions, Turn attachments, Draw.io/SVG/PNG exports,
and recovery never store or interpret Excalidraw scene JSON.

The native canvas remains a fail-closed fallback when local resources, the
offline policy, JavaScript, or the bridge cannot load. Because WebKit's canvas
accessibility tree does not express the full Board contract, an inert native
projection retains the existing VoiceOver semantics while the enhanced canvas
owns pointer interaction.

Version 0.17.6 is deliberately pinned because its seven-package production
tree is advisory-clean. The initially evaluated 0.18.1 release pulled a
vulnerable Mermaid dependency tree and is not shipped. An upgrade requires a
clean dependency audit, deterministic codec tests, an offline WebKit bridge
test, native persistence/revision/export tests, and headed keyboard/VoiceOver
verification.

## Consequences

- Canvas manipulation improves without changing durable Board evidence or
  export contracts.
- The signed app grows by the local editor JavaScript, CSS, and font resources.
- Excalidraw's own local toolbar is the primary enhanced-canvas Interface.
  Rectangle, diamond, ellipse, arrow, line/freehand, text, eraser, selection,
  and hand/pan tools are supported by the canonical model and deterministic
  exports. Files, images, libraries, embeds, sharing, and cloud features remain
  unavailable; adding another element requires a native domain decision and
  deterministic codec/export coverage first.
- A broken or rejected editor update cannot replace the last valid native
  Board Document.
- Third-party licenses and bundled-font notices ship with the editor resources
  and remain part of package review.
