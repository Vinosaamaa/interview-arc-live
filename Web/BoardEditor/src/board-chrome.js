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
const EXCALIDRAW_TOOLBAR_SELECTOR = ".App-toolbar-container";

export const createBoardToolbarGeometryAdapter = ({ root, onChange }) => {
  let toolbar;

  const resizeObserver = new ResizeObserver(() => {
    refreshToolbar();
  });
  const attributeObserver = new MutationObserver(() => {
    refreshToolbar();
  });
  const parentObserver = new MutationObserver(() => {
    refreshToolbar();
  });
  const mountObserver = new MutationObserver(() => {
    refreshToolbar();
  });

  const observeMount = () => {
    mountObserver.disconnect();
    mountObserver.observe(root, { childList: true, subtree: true });
  };

  const attachToolbar = (nextToolbar) => {
    resizeObserver.disconnect();
    attributeObserver.disconnect();
    parentObserver.disconnect();
    toolbar = nextToolbar;

    if (!toolbar) {
      observeMount();
      onChange();
      return;
    }

    mountObserver.disconnect();
    resizeObserver.observe(toolbar);
    attributeObserver.observe(toolbar, {
      attributes: true,
      attributeFilter: ["aria-hidden", "class", "hidden", "style"],
    });
    if (toolbar.parentElement) {
      parentObserver.observe(toolbar.parentElement, {
        attributes: true,
        attributeFilter: ["class", "hidden", "style"],
        childList: true,
      });
    }
    onChange();
  };

  function refreshToolbar() {
    const nextToolbar = root.querySelector(EXCALIDRAW_TOOLBAR_SELECTOR);
    if (nextToolbar !== toolbar) {
      attachToolbar(nextToolbar);
      return;
    }
    onChange();
  }

  refreshToolbar();

  return {
    bounds(relativeTo) {
      if (!toolbar?.isConnected || toolbar.getClientRects().length === 0) return null;
      const rootRect = relativeTo.getBoundingClientRect();
      const toolbarRect = toolbar.getBoundingClientRect();
      if (toolbarRect.width <= 0 || toolbarRect.height <= 0) return null;
      return {
        left: toolbarRect.left - rootRect.left,
        right: toolbarRect.right - rootRect.left,
        top: toolbarRect.top - rootRect.top,
        bottom: toolbarRect.bottom - rootRect.top,
      };
    },
    disconnect() {
      resizeObserver.disconnect();
      attributeObserver.disconnect();
      parentObserver.disconnect();
      mountObserver.disconnect();
      toolbar = null;
    },
  };
};

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
