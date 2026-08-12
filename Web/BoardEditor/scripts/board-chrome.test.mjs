import assert from "node:assert/strict";
import test from "node:test";
import {
  boardChromeActionConfigurations,
  resolveBoardChromePlacement,
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

test("Board chrome flows below the toolbar when the row is occupied", () => {
  const placement = resolveBoardChromePlacement({
    container: { left: 0, right: 780 },
    toolbar: { top: 16, right: 606, bottom: 64 },
    currentControlsWidth: 520,
    fullControlsWidth: 520,
    viewportWidth: 780,
  });
  assert.equal(placement.compact, false);
  assert.equal(placement.sharesToolbarRow, false);
  assert.equal(placement.top, 72);
  assert.equal(placement.right, 8);
});

test("Board chrome compacts only when its full controls cannot fit", () => {
  const placement = resolveBoardChromePlacement({
    container: { left: 0, right: 420 },
    toolbar: { top: 16, right: 380, bottom: 64 },
    currentControlsWidth: 186,
    fullControlsWidth: 520,
    viewportWidth: 420,
  });
  assert.equal(placement.compact, true);
  assert.equal(placement.right, 8);
  assert.equal(placement.top, 72);
});
