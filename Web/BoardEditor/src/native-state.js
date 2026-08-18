const selectedIDsEqual = (current, next) => {
  let currentCount = 0;
  let nextCount = 0;
  for (const id in current ?? {}) {
    if (!current[id]) continue;
    currentCount += 1;
    if (!next?.[id]) return false;
  }
  for (const id in next ?? {}) {
    if (next[id]) nextCount += 1;
  }
  return currentCount === nextCount;
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
