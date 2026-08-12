export const createScenePublicationController = (
  publish,
  prepare = (scene) => scene,
  identify = (scene) => scene,
) => {
  let isPointerInteractionActive = false;
  let pendingScene = null;
  let adoptedRevision = null;

  const publishPendingScene = () => {
    if (pendingScene === null) return false;
    // Excalidraw emits its default empty scene while React mounts. Native is
    // the durable owner, so nothing may cross the bridge until the first
    // native document has been applied and adopted as our baseline.
    if (adoptedRevision === null) return false;
    const revision = identify(pendingScene);
    if (revision === adoptedRevision) {
      pendingScene = null;
      return false;
    }
    const scene = prepare(pendingScene);
    pendingScene = null;
    adoptedRevision = revision;
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
      adoptedRevision = identify(scene);
    },

    reset() {
      isPointerInteractionActive = false;
      pendingScene = null;
      adoptedRevision = null;
    },

    snapshot() {
      return {
        isPointerInteractionActive,
        hasPendingScene: pendingScene !== null,
        hasAdoptedScene: adoptedRevision !== null,
      };
    },
  };
};
