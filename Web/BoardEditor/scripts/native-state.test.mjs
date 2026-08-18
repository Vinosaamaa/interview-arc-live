import assert from "node:assert/strict";
import test from "node:test";

import {
  nativeAppStatePatchRequired,
  nativeControlsEqual,
} from "../src/native-state.js";

const controls = {
  revisionStatus: "Unsaved board",
  notice: null,
  noticeIsError: false,
  isInspecting: false,
  canSave: true,
  hasRevisions: false,
  canAttach: false,
  canExport: false,
  isExporting: false,
};

test("controls-only changes never require an Excalidraw scene update", () => {
  const current = {
    selectedElementIds: { "box-1": true },
    zoom: { value: 1 },
    currentItemStrokeColor: "#1f2937",
  };
  assert.equal(nativeAppStatePatchRequired(current, {
    selectedElementIds: { "box-1": true },
    zoom: { value: 1 },
    currentItemStrokeColor: "#1f2937",
  }), false);
  assert.equal(nativeControlsEqual(controls, { ...controls }), true);
  assert.equal(nativeControlsEqual(controls, {
    ...controls,
    revisionStatus: "Unsaved changes · revision 1",
  }), false);
});

test("selection, zoom, and drawing-style changes remain authoritative", () => {
  const current = {
    selectedElementIds: { "box-1": true },
    zoom: { value: 1 },
    currentItemStrokeColor: "#1f2937",
  };
  assert.equal(nativeAppStatePatchRequired(current, {
    selectedElementIds: { "box-2": true },
  }), true);
  assert.equal(nativeAppStatePatchRequired(current, {
    zoom: { value: 1.25 },
  }), true);
  assert.equal(nativeAppStatePatchRequired(current, {
    currentItemStrokeColor: "#4b3abf",
  }), true);
});

test("selection equality ignores false entries without allocating key lists", () => {
  const current = {
    selectedElementIds: {
      "box-1": true,
      "box-stale": false,
    },
  };
  assert.equal(nativeAppStatePatchRequired(current, {
    selectedElementIds: {
      "box-ignored": false,
      "box-1": true,
    },
  }), false);
  assert.equal(nativeAppStatePatchRequired(current, {
    selectedElementIds: {
      "box-1": true,
      "box-2": true,
    },
  }), true);
});
