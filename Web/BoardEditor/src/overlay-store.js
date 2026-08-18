export const createSemanticOverlayStore = (initialSnapshot) => {
  let snapshot = initialSnapshot;
  const listeners = new Set();

  return {
    getSnapshot: () => snapshot,
    publish(nextSnapshot) {
      if (nextSnapshot.fingerprint === snapshot.fingerprint) return false;
      snapshot = nextSnapshot;
      for (const listener of listeners) listener();
      return true;
    },
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };
};
