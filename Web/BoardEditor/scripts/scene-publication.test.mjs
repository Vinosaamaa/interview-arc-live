import assert from "node:assert/strict";
import test from "node:test";

import { createScenePublicationController } from "../src/scene-publication.js";

test("pointer-up publishes the last scene exactly once", () => {
  const published = [];
  const controller = createScenePublicationController((scene) => {
    published.push(scene);
  });
  controller.adoptScene({ elementIDs: [] });

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
  controller.adoptScene({ label: "" });

  controller.acceptScene({ label: "Delivery" });
  controller.acceptScene({ label: "Delivery queue" });

  assert.deepEqual(published, [
    { label: "Delivery" },
    { label: "Delivery queue" },
  ]);
});

test("a native scene baseline never republishes as a user edit", () => {
  const published = [];
  let preparationCount = 0;
  const controller = createScenePublicationController((scene) => {
    published.push(scene);
  }, (scene) => {
    preparationCount += 1;
    return scene;
  }, (scene) => scene.revision);
  const nativeScene = {
    revision: 7,
    elements: [{ id: "connector-1", points: [[0, 0], [0.13, 0.3]] }],
    zoom: 1,
  };

  controller.adoptScene(nativeScene);
  controller.acceptScene(structuredClone(nativeScene));
  controller.acceptScene(structuredClone(nativeScene));

  assert.deepEqual(published, []);
  assert.equal(preparationCount, 0);
  assert.deepEqual(controller.snapshot(), {
    isPointerInteractionActive: false,
    hasPendingScene: false,
    hasAdoptedScene: true,
  });
});

test("a real change after a native baseline publishes once", () => {
  const published = [];
  const controller = createScenePublicationController((scene) => {
    published.push(scene);
  }, (scene) => scene, (scene) => scene.revision);

  controller.adoptScene({ label: "Delivery", revision: 1 });
  controller.acceptScene({ label: "Delivery queue", revision: 2 });
  controller.acceptScene({ label: "Delivery queue", revision: 2 });

  assert.deepEqual(published, [{ label: "Delivery queue", revision: 2 }]);
});

test("pointer cancellation publishes the last scene and unlocks future updates", () => {
  const published = [];
  const controller = createScenePublicationController((scene) => {
    published.push(scene);
  });
  controller.adoptScene({ elementIDs: [] });

  controller.beginPointerInteraction();
  controller.acceptScene({ elementIDs: ["generic-1"] });
  assert.equal(controller.cancelPointerInteraction(), true);
  assert.deepEqual(published, [{ elementIDs: ["generic-1"] }]);

  controller.acceptScene({ elementIDs: ["generic-1", "service-1"] });
  assert.deepEqual(published, [
    { elementIDs: ["generic-1"] },
    { elementIDs: ["generic-1", "service-1"] },
  ]);
  assert.equal(controller.cancelPointerInteraction(), false);
});

test("programmatic loads clear stale pending pointer state", () => {
  const published = [];
  const controller = createScenePublicationController((scene) => {
    published.push(scene);
  });
  controller.adoptScene({ elementIDs: [] });

  controller.beginPointerInteraction();
  controller.acceptScene({ elementIDs: ["orphan"] });
  controller.reset();
  controller.endPointerInteraction();

  assert.deepEqual(published, []);
  assert.deepEqual(controller.snapshot(), {
    isPointerInteractionActive: false,
    hasPendingScene: false,
    hasAdoptedScene: false,
  });
});

test("bootstrap empty scene cannot overwrite the native document", () => {
  const published = [];
  const controller = createScenePublicationController((scene) => {
    published.push(scene);
  }, (scene) => scene, (scene) => scene.revision);

  controller.acceptScene({ revision: 0, elements: [] });
  controller.flush();
  assert.deepEqual(published, []);
  assert.deepEqual(controller.snapshot(), {
    isPointerInteractionActive: false,
    hasPendingScene: true,
    hasAdoptedScene: false,
  });

  controller.adoptScene({ revision: 12, elements: [{ id: "service-1" }] });
  assert.deepEqual(published, []);
  assert.deepEqual(controller.snapshot(), {
    isPointerInteractionActive: false,
    hasPendingScene: false,
    hasAdoptedScene: true,
  });

  controller.acceptScene({ revision: 13, elements: [{ id: "service-1" }] });
  assert.deepEqual(published, [
    { revision: 13, elements: [{ id: "service-1" }] },
  ]);
});
