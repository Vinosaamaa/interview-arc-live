import assert from "node:assert/strict";
import test from "node:test";

import { createSemanticOverlayStore } from "../src/overlay-store.js";

test("semantic overlay updates do not require a BoardEditor parent render", () => {
  const initial = { elements: [], appState: null, fingerprint: "empty" };
  const store = createSemanticOverlayStore(initial);
  let notifications = 0;
  const unsubscribe = store.subscribe(() => {
    notifications += 1;
  });

  assert.equal(store.publish({ ...initial }), false);
  assert.equal(notifications, 0);

  const moved = {
    elements: [{ id: "box-1", x: 140 }],
    appState: { zoom: { value: 1 } },
    fingerprint: "box-1@140",
  };
  assert.equal(store.publish(moved), true);
  assert.equal(store.getSnapshot(), moved);
  assert.equal(notifications, 1);

  unsubscribe();
});
