import assert from "node:assert/strict";
import test from "node:test";
import {
  boardChromeActionConfigurations,
  boardChromeLayout,
} from "../src/board-chrome.js";

test("Board product actions derive from one configuration", () => {
  const actions = boardChromeActionConfigurations({
    canAttach: true,
    canExport: true,
    canSave: true,
    hasRevisions: true,
    isExporting: false,
    isInspecting: false,
  });
  assert.deepEqual(
    actions.map(({ command, enabled }) => [command, enabled]),
    [
      ["saveRevision", true],
      ["showRevisions", true],
      ["attachRevision", true],
      ["exportRevision", true],
    ],
  );
});

test("Board actions keep complete accessible labels in icon-only chrome", () => {
  const actions = boardChromeActionConfigurations({
    canAttach: false,
    canExport: true,
    canSave: false,
    hasRevisions: true,
    isExporting: true,
    isInspecting: true,
  });
  assert.deepEqual(
    actions.map(({ command, label, title }) => [command, label, title]),
    [
      ["returnToDraft", "Return to draft", undefined],
      ["showRevisions", "Revisions", "Browse revisions"],
      ["attachRevision", "Attach", "Attach revision"],
      ["exportRevision", "Exporting", "Export Draw.io, SVG, and PNG"],
    ],
  );
});

test("Board chrome stays beside Excalidraw only when both islands fit", () => {
  assert.deepEqual(
    boardChromeLayout({
      viewportWidth: 1280,
      toolbar: { left: 300, right: 850, top: 12, bottom: 60 },
      controlsWidth: 184,
    }),
    { mode: "inline", right: 12, top: 12 },
  );
});

test("Board chrome moves below Excalidraw at the intermediate collision width", () => {
  assert.deepEqual(
    boardChromeLayout({
      viewportWidth: 992,
      toolbar: { left: 110, right: 810, top: 12, bottom: 60 },
      controlsWidth: 184,
    }),
    { mode: "stacked", right: 12, top: 70 },
  );
});

test("Board chrome defaults to the safe stacked position before toolbar mount", () => {
  assert.deepEqual(
    boardChromeLayout({
      viewportWidth: 800,
      toolbar: null,
      controlsWidth: 184,
    }),
    { mode: "stacked", right: 12, top: 72 },
  );
});
