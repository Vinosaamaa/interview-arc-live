export const createScenePublicationController = (
  publish,
  prepare = (scene) => scene,
) => {
  let isPointerInteractionActive = false;
  let pendingScene = null;
  let adoptedFingerprint = null;

  const fingerprint = (scene) => JSON.stringify(scene);

  const publishPendingScene = () => {
    if (pendingScene === null) return false;
    const scene = prepare(pendingScene);
    pendingScene = null;
    const nextFingerprint = fingerprint(scene);
    if (nextFingerprint === adoptedFingerprint) return false;
    adoptedFingerprint = nextFingerprint;
    publish(scene);
    return true;
  };

  return {
    acceptScene(scene) {
      pendingScene = scene;
      if (!isPointerInteractionActive) publishPendingScene();
    },

    beginPointerInteraction() {
      isPointerInteractionActive = true;
    },

    endPointerInteraction() {
      if (!isPointerInteractionActive) return false;
      isPointerInteractionActive = false;
      return publishPendingScene();
    },

    cancelPointerInteraction() {
      if (!isPointerInteractionActive) return false;
      isPointerInteractionActive = false;
      return publishPendingScene();
    },

    flush() {
      return publishPendingScene();
    },

    adoptScene(scene) {
      isPointerInteractionActive = false;
      pendingScene = null;
      adoptedFingerprint = fingerprint(scene);
    },

    reset() {
      isPointerInteractionActive = false;
      pendingScene = null;
      adoptedFingerprint = null;
    },

    snapshot() {
      return {
        isPointerInteractionActive,
        hasPendingScene: pendingScene !== null,
        hasAdoptedScene: adoptedFingerprint !== null,
      };
    },
  };
};
