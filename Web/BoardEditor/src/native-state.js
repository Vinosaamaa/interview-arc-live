const selectedIDsEqual = (current, next) => {
  const currentIDs = Object.keys(current ?? {}).filter((id) => current[id]);
  const nextIDs = Object.keys(next ?? {}).filter((id) => next[id]);
  return currentIDs.length === nextIDs.length
    && currentIDs.every((id) => Boolean(next?.[id]));
};

export const nativeAppStatePatchRequired = (current, patch) =>
  Object.entries(patch).some(([key, next]) => {
    if (key === "selectedElementIds") {
      return !selectedIDsEqual(current?.selectedElementIds, next);
    }
    if (key === "zoom") {
      return Number(current?.zoom?.value ?? 1) !== Number(next?.value ?? 1);
    }
    return current?.[key] !== next;
  });

export const nativeControlsEqual = (current, next) =>
  current.revisionStatus === next.revisionStatus
  && current.notice === next.notice
  && current.noticeIsError === next.noticeIsError
  && current.isInspecting === next.isInspecting
  && current.canSave === next.canSave
  && current.hasRevisions === next.hasRevisions
  && current.canAttach === next.canAttach
  && current.canExport === next.canExport
  && current.isExporting === next.isExporting;
