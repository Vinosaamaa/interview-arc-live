export const reconcileNativeElementVersions = (
  canonicalElements,
  currentElements,
  nonceForVersion,
) => {
  const currentByID = new Map(
    currentElements.map((element) => [element.id, element]),
  );
  return canonicalElements.map((element) => {
    const current = currentByID.get(element.id);
    if (!current) return element;
    const version = Math.max(
      Number(element.version ?? 1),
      Number(current.version ?? 1) + 1,
    );
    return {
      ...element,
      version,
      versionNonce: nonceForVersion(element.id, version),
      updated: Math.max(
        Number(element.updated ?? 1),
        Number(current.updated ?? 1) + 1,
      ),
    };
  });
};
