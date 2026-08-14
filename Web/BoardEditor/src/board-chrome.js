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
