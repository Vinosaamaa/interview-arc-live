import assert from "node:assert/strict";
import test from "node:test";
import {
  hasCanonicalBoardAngle,
  semanticOverlayElements,
  semanticOverlayFingerprint,
  semanticOverlaySnapshot,
} from "../src/semantic-overlay.js";

const box = {
  id: "box-1",
  type: "rectangle",
  x: 120,
  y: 80,
  width: 160,
  height: 112,
  strokeColor: "#4b3abf",
  customData: {
    iaElementType: "box",
    iaKind: "service",
    iaLabel: "API service",
  },
};

const viewport = {
  zoom: { value: 1 },
  scrollX: 0,
  scrollY: 0,
  offsetLeft: 0,
  offsetTop: 0,
};

test("irrelevant Excalidraw state does not invalidate the semantic overlay", () => {
  const baseline = semanticOverlayFingerprint([box], viewport);
  const afterEphemeralState = semanticOverlayFingerprint([box], {
    ...viewport,
    activeTool: { type: "selection" },
    selectedElementIds: { "box-1": true },
  });
  assert.equal(afterEphemeralState, baseline);
});

test("semantic geometry, labels, and viewport changes invalidate the overlay", () => {
  const baseline = semanticOverlayFingerprint([box], viewport);
  assert.notEqual(
    semanticOverlayFingerprint([{ ...box, x: 130 }], viewport),
    baseline,
  );
  assert.notEqual(
    semanticOverlayFingerprint([{ ...box, angle: Math.PI / 4 }], viewport),
    baseline,
  );
  assert.notEqual(
    semanticOverlayFingerprint([{
      ...box,
      customData: { ...box.customData, iaLabel: "Gateway" },
    }], viewport),
    baseline,
  );
  assert.notEqual(
    semanticOverlayFingerprint([box], { ...viewport, scrollX: -30 }),
    baseline,
  );
});

test("nonsemantic Excalidraw elements do not trigger overlay work", () => {
  const baseline = semanticOverlayFingerprint([], viewport);
  assert.equal(
    semanticOverlayFingerprint([{
      id: "stroke-1",
      type: "freedraw",
      x: 10,
      y: 10,
      points: [[0, 0], [20, 20]],
    }], viewport),
    baseline,
  );
});

test("semantic overlay snapshot reuses one filtered element list", () => {
  const stroke = {
    id: "stroke-1",
    type: "freedraw",
    points: [[0, 0], [20, 20]],
  };
  assert.deepEqual(semanticOverlayElements([box, stroke]), [box]);
  const snapshot = semanticOverlaySnapshot([box, stroke], viewport);
  assert.deepEqual(snapshot.elements, [box]);
  assert.equal(
    snapshot.fingerprint,
    semanticOverlayFingerprint([box, stroke], viewport),
  );
});

test("the canonical Board rejects rotation instead of rendering stale semantics", () => {
  assert.equal(hasCanonicalBoardAngle(box), true);
  assert.equal(hasCanonicalBoardAngle({ ...box, angle: Math.PI / 4 }), false);
});
