import assert from "node:assert/strict";
import test from "node:test";
import {
  boardChromeActionConfigurations,
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
