import assert from "node:assert/strict";
import test from "node:test";

import { createScenePublicationController } from "../src/scene-publication.js";

test("pointer-up publishes the last scene exactly once", () => {
  const published = [];
  const controller = createScenePublicationController((scene) => {
    published.push(scene);
  });

  controller.beginPointerInteraction();
  controller.acceptScene({ elementIDs: ["generic-1"] });
  controller.acceptScene({ elementIDs: ["generic-1", "service-1"] });
  assert.deepEqual(published, []);

  controller.endPointerInteraction();
  assert.deepEqual(published, [{
    elementIDs: ["generic-1", "service-1"],
  }]);

  controller.endPointerInteraction();
  assert.equal(published.length, 1);
});

test("keyboard and text changes publish immediately outside pointer work", () => {
  const published = [];
  const controller = createScenePublicationController((scene) => {
    published.push(scene);
  });

  controller.acceptScene({ label: "Delivery" });
  controller.acceptScene({ label: "Delivery queue" });

  assert.deepEqual(published, [
    { label: "Delivery" },
    { label: "Delivery queue" },
  ]);
});

test("programmatic loads clear stale pending pointer state", () => {
  const published = [];
  const controller = createScenePublicationController((scene) => {
    published.push(scene);
  });

  controller.beginPointerInteraction();
  controller.acceptScene({ elementIDs: ["orphan"] });
  controller.reset();
  controller.endPointerInteraction();

  assert.deepEqual(published, []);
  assert.deepEqual(controller.snapshot(), {
    isPointerInteractionActive: false,
    hasPendingScene: false,
  });
});
