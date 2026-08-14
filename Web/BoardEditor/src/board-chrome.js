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

const DEFAULT_INSET = 12;
const DEFAULT_GAP = 10;

export const boardChromeLayout = ({
  viewportWidth,
  toolbar,
  controlsWidth,
  inset = DEFAULT_INSET,
  gap = DEFAULT_GAP,
}) => {
  const safeWidth = Math.max(0, Number(viewportWidth) || 0);
  const safeControlsWidth = Math.max(0, Number(controlsWidth) || 0);
  const right = Math.max(0, inset);
  const controlsLeft = safeWidth - right - safeControlsWidth;
  const toolbarRight = Number(toolbar?.right);
  const toolbarTop = Number(toolbar?.top);
  const toolbarBottom = Number(toolbar?.bottom);
  const hasToolbarBounds = Number.isFinite(toolbarRight)
    && Number.isFinite(toolbarTop)
    && Number.isFinite(toolbarBottom);
  const fitsInline = hasToolbarBounds
    && toolbarRight + gap <= controlsLeft;

  return {
    mode: fitsInline ? "inline" : "stacked",
    right,
    top: fitsInline
      ? Math.max(inset, toolbarTop)
      : Math.max(inset, hasToolbarBounds ? toolbarBottom + gap : 72),
  };
};
