export const BOARD_CHROME_GAP = 8;
export const BOARD_CHROME_FALLBACK_PLACEMENT = Object.freeze({
  right: BOARD_CHROME_GAP,
  top: 72,
});

export const boardChromeActionConfigurations = (controls) => {
  const inspecting = Boolean(controls.isInspecting);
  return [
    {
      command: inspecting ? "returnToDraft" : "saveRevision",
      enabled: inspecting || Boolean(controls.canSave),
      icon: inspecting ? "draft" : "save",
      label: inspecting ? "Return to draft" : "Save revision",
      primary: true,
    },
    {
      command: "showRevisions",
      enabled: Boolean(controls.hasRevisions),
      icon: "revisions",
      label: "Revisions",
      title: "Browse revisions",
    },
    {
      command: "attachRevision",
      enabled: Boolean(controls.canAttach),
      icon: "attach",
      label: "Attach",
      title: "Attach revision",
    },
    {
      command: "exportRevision",
      enabled: Boolean(controls.canExport) && !controls.isExporting,
      icon: controls.isExporting ? "working" : "export",
      label: controls.isExporting ? "Exporting" : "Export",
      primary: true,
      title: "Export Draw.io, SVG, and PNG",
    },
  ];
};

export const resolveBoardChromePlacement = ({
  container,
  toolbar,
  currentControlsWidth,
  fullControlsWidth,
  viewportWidth,
  gap = BOARD_CHROME_GAP,
}) => {
  const availableWidth = Math.max(
    0,
    Number(container.right) - Number(container.left) - gap * 2,
  );
  const compact = Number(fullControlsWidth) > availableWidth;
  const controlsWidth = compact
    ? Number(currentControlsWidth)
    : Number(fullControlsWidth);
  const proposedLeft = Number(container.right) - gap - controlsWidth;
  const sharesToolbarRow = proposedLeft >= Number(toolbar.right) + gap;
  return {
    compact,
    right: Math.max(gap, Number(viewportWidth) - Number(container.right) + gap),
    sharesToolbarRow,
    top: sharesToolbarRow
      ? Number(toolbar.top)
      : Number(toolbar.bottom) + gap,
  };
};
