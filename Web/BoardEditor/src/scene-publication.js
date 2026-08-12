export const createScenePublicationController = (publish) => {
  let isPointerInteractionActive = false;
  let pendingScene = null;

  const publishPendingScene = () => {
    if (pendingScene === null) return false;
    const scene = pendingScene;
    pendingScene = null;
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

    reset() {
      isPointerInteractionActive = false;
      pendingScene = null;
    },

    snapshot() {
      return {
        isPointerInteractionActive,
        hasPendingScene: pendingScene !== null,
      };
    },
  };
};
