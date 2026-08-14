import assert from "node:assert/strict";
import test from "node:test";
import {
  boardChromeActionConfigurations,
  boardChromeLayout,
  createBoardToolbarGeometryAdapter,
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

test("Board toolbar adapter narrows observation after the toolbar mounts", () => {
  const previousResizeObserver = globalThis.ResizeObserver;
  const previousMutationObserver = globalThis.MutationObserver;
  const resizeObservers = [];
  const mutationObservers = [];

  class FakeObserver {
    constructor(callback, collection) {
      this.callback = callback;
      this.observed = [];
      this.disconnectCount = 0;
      collection.push(this);
    }

    disconnect() {
      this.disconnectCount += 1;
      this.observed = [];
    }

    observe(target, options) {
      this.observed.push({ target, options });
    }
  }

  globalThis.ResizeObserver = class extends FakeObserver {
    constructor(callback) {
      super(callback, resizeObservers);
    }
  };
  globalThis.MutationObserver = class extends FakeObserver {
    constructor(callback) {
      super(callback, mutationObservers);
    }
  };

  try {
    const parent = {};
    const toolbar = {
      isConnected: true,
      parentElement: parent,
      getClientRects: () => [{}],
      getBoundingClientRect: () => ({
        bottom: 70,
        height: 50,
        left: 120,
        right: 820,
        top: 20,
        width: 700,
      }),
    };
    let mountedToolbar = null;
    const root = {
      querySelector: () => mountedToolbar,
    };
    let changeCount = 0;
    const adapter = createBoardToolbarGeometryAdapter({
      root,
      onChange: () => { changeCount += 1; },
    });

    const mountObserver = mutationObservers[2];
    assert.deepEqual(
      mountObserver.observed,
      [{ target: root, options: { childList: true, subtree: true } }],
    );

    mountedToolbar = toolbar;
    mountObserver.callback();
    assert.equal(resizeObservers[0].observed[0].target, toolbar);
    assert.deepEqual(mutationObservers[0].observed[0], {
      target: toolbar,
      options: {
        attributes: true,
        attributeFilter: ["aria-hidden", "class", "hidden", "style"],
      },
    });
    assert.equal(mutationObservers[1].observed[0].target, parent);
    assert.deepEqual(adapter.bounds({
      getBoundingClientRect: () => ({ left: 20, top: 10 }),
    }), {
      bottom: 60,
      left: 100,
      right: 800,
      top: 10,
    });
    assert.ok(changeCount >= 2);

    adapter.disconnect();
    assert.equal(resizeObservers[0].observed.length, 0);
  } finally {
    globalThis.ResizeObserver = previousResizeObserver;
    globalThis.MutationObserver = previousMutationObserver;
  }
});
