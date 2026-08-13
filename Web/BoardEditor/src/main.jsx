import React, {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";
import { createRoot } from "react-dom/client";
import {
  Excalidraw,
  convertToExcalidrawElements,
  getNonDeletedElements,
  getSceneVersion,
} from "@excalidraw/excalidraw";
import {
  hasCanonicalBoardAngle,
  semanticOverlaySnapshot,
} from "./semantic-overlay.js";
import { createScenePublicationController } from "./scene-publication.js";
import {
  boxKindForExcalType,
  excalTypeForNativeTool,
  nativeToolForExcalType,
} from "./tool-mapping.js";
import {
  boardChromeActionConfigurations,
  boardChromeLayout,
  createBoardToolbarGeometryAdapter,
} from "./board-chrome.js";
import { reconcileNativeElementVersions } from "./native-reconcile.js";
import {
  nativeAppStatePatchRequired,
  nativeControlsEqual,
} from "./native-state.js";
import { createSemanticOverlayStore } from "./overlay-store.js";
import "./style.css";

const bridge = window.webkit?.messageHandlers?.boardBridge;

const post = (payload) => {
  bridge?.postMessage(payload);
};

const diagnosticsEnabled = new URLSearchParams(window.location.search)
  .get("diagnostics") === "1";
let diagnosticAnimationFrame = null;
let diagnosticFrame = 0;
let diagnosticFramesRemaining = 0;
let previousLayoutDiagnostic = null;

const describeDiagnosticElement = (element) => {
  if (!element) return null;
  const rect = element.getBoundingClientRect();
  const style = window.getComputedStyle(element);
  return {
    x: rect.x,
    y: rect.y,
    width: rect.width,
    height: rect.height,
    display: style.display,
    visibility: style.visibility,
    opacity: style.opacity,
  };
};

const reportInteractionDiagnostic = (
  api,
  phase,
  nativeControls,
  renderCount,
) => {
  if (!diagnosticsEnabled) return;
  const appState = api?.getAppState?.() ?? {};
  post({
    event: "diagnostic",
    diagnosticKind: "interaction-frame",
    phase,
    frame: diagnosticFrame,
    renderCount,
    topMenu: describeDiagnosticElement(
      document.querySelector(".App-menu_top"),
    ),
    topToolbar: describeDiagnosticElement(
      document.querySelector(".App-toolbar"),
    ),
    bottomMenu: describeDiagnosticElement(
      document.querySelector(".App-menu_bottom"),
    ),
    bottomLeft: describeDiagnosticElement(
      document.querySelector(".layer-ui__wrapper__footer-left"),
    ),
    productControls: describeDiagnosticElement(
      document.querySelector(".interview-arc-board-controls"),
    ),
    shell: describeDiagnosticElement(document.querySelector(".board-shell")),
    root: describeDiagnosticElement(document.querySelector("#root")),
    viewport: {
      width: window.innerWidth,
      height: window.innerHeight,
      visualWidth: window.visualViewport?.width ?? null,
      visualHeight: window.visualViewport?.height ?? null,
    },
    controls: {
      revisionStatus: nativeControls?.revisionStatus ?? null,
      canSave: Boolean(nativeControls?.canSave),
      isExporting: Boolean(nativeControls?.isExporting),
      notice: nativeControls?.notice ?? null,
    },
    appState: {
      tool: appState.activeTool?.type ?? null,
      zoom: Number(appState.zoom?.value ?? 1),
      selectedCount: Object.values(appState.selectedElementIds ?? {})
        .filter(Boolean).length,
      isDragging: Boolean(appState.draggingElement),
      isResizing: Boolean(appState.resizingElement),
      isEditing: Boolean(appState.editingElement),
    },
  });
};

const startInteractionDiagnostic = (getSnapshot) => {
  if (!diagnosticsEnabled || diagnosticAnimationFrame !== null) return;
  diagnosticFramesRemaining = Number.POSITIVE_INFINITY;
  const sample = () => {
    diagnosticFrame += 1;
    const snapshot = getSnapshot();
    reportInteractionDiagnostic(
      snapshot.api,
      snapshot.phase,
      snapshot.nativeControls,
      snapshot.renderCount,
    );
    if (diagnosticFramesRemaining !== Number.POSITIVE_INFINITY) {
      diagnosticFramesRemaining -= 1;
    }
    if (diagnosticFramesRemaining > 0) {
      diagnosticAnimationFrame = window.requestAnimationFrame(sample);
    } else {
      diagnosticAnimationFrame = null;
    }
  };
  diagnosticAnimationFrame = window.requestAnimationFrame(sample);
};

const finishInteractionDiagnostic = () => {
  if (!diagnosticsEnabled) return;
  diagnosticFramesRemaining = 12;
};

const reportControlDiagnostic = (previous, next, renderCount) => {
  if (!diagnosticsEnabled) return;
  post({
    event: "diagnostic",
    diagnosticKind: "control-transition",
    renderCount,
    previous,
    next,
  });
};

const reportLayoutDiagnostic = (api, phase, force = false) => {
  if (!diagnosticsEnabled) return;
  window.requestAnimationFrame(() => {
    const appState = api?.getAppState?.() ?? {};
    const leftPanel = document.querySelector(".App-menu_left");
    const topPanel = document.querySelector(".App-menu_top");
    const shell = document.querySelector(".board-shell");
    const root = document.querySelector("#root");
    const describe = (element) => {
      if (!element) return "missing";
      const rect = element.getBoundingClientRect();
      const style = window.getComputedStyle(element);
      return [
        Math.round(rect.x),
        Math.round(rect.y),
        Math.round(rect.width),
        Math.round(rect.height),
        style.display,
        style.visibility,
        style.opacity,
      ].join(",");
    };
    const selectedCount = Object.values(appState.selectedElementIds ?? {})
      .filter(Boolean).length;
    const fingerprint = [
      describe(leftPanel),
      describe(topPanel),
      describe(shell),
      describe(root),
      describe(document.body),
      describe(document.documentElement),
      `${window.innerWidth},${window.innerHeight}`,
      `${Math.round(window.visualViewport?.width ?? -1)},${Math.round(window.visualViewport?.height ?? -1)}`,
      String(Boolean(shell?.isConnected)),
      appState.activeTool?.type ?? "unknown",
      selectedCount,
      Boolean(appState.draggingElement),
      Boolean(appState.resizingElement),
      Boolean(appState.editingElement),
    ].join("|");
    if (!force && fingerprint === previousLayoutDiagnostic) return;
    previousLayoutDiagnostic = fingerprint;
    post({
      event: "diagnostic",
      phase: `layout ${phase} ${fingerprint}`,
    });
  });
};

// Excalidraw has a smaller native shape vocabulary than BoardNodeVisual. Keep
// these projections architecture-safe (a service must never look like a
// decision diamond) and retain the canonical visual key for reload/export.
const semanticBoxPresentation = (kind) => ({
  generic: { type: "rectangle", roundness: { type: 3 }, visualKey: "roundedRectangle.componentGrid" },
  decision: { type: "diamond", roundness: null, visualKey: "diamond.none" },
  ellipse: { type: "ellipse", roundness: null, visualKey: "ellipse.none" },
  client: { type: "rectangle", roundness: { type: 3 }, visualKey: "browser.globe" },
  service: { type: "rectangle", roundness: { type: 3 }, visualKey: "hexagon.fanout" },
  database: { type: "ellipse", roundness: null, visualKey: "cylinder.records" },
  queue: { type: "rectangle", roundness: { type: 3 }, visualKey: "queue.messageQueue" },
  storage: { type: "rectangle", roundness: { type: 3 }, visualKey: "folder.archive" },
}[kind] ?? { type: "rectangle", roundness: { type: 3 }, visualKey: "roundedRectangle.componentGrid" });

const itemStyleForTool = (tool) => ({
  currentItemFontFamily: 2,
  currentItemRoughness: 0,
  currentItemStrokeColor: tool === "pen"
    ? "#ed4e2f"
    : tool === "box"
      ? "#4b3abf"
      : "#1f2937",
  currentItemBackgroundColor: tool === "box" ? "#ffffff" : "transparent",
  currentItemFillStyle: "solid",
});

const stableSeed = (value) => {
  let hash = 2_166_136_261;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 16_777_619);
  }
  return Math.max(1, hash >>> 1);
};

const normalizedHex = (value, fallback) => {
  if (typeof value !== "string") return fallback;
  const candidate = value.toLowerCase();
  return /^#[0-9a-f]{6}$/.test(candidate) ? candidate : fallback;
};

const elementLabel = (element, textByContainer) =>
  textByContainer.get(element.id)?.text
    ?? String(element.customData?.iaLabel ?? "");

const pointAt = (element, index) => {
  const points = element.points ?? [];
  const resolvedIndex = index < 0 ? points.length + index : index;
  const point = points[resolvedIndex] ?? [0, 0];
  return {
    x: Number(element.x ?? 0) + Number(point[0] ?? 0),
    y: Number(element.y ?? 0) + Number(point[1] ?? 0),
  };
};

const SemanticPictogram = ({ kind }) => {
  const common = {
    fill: "none",
    stroke: "currentColor",
    strokeWidth: 1.7,
    strokeLinecap: "round",
    strokeLinejoin: "round",
  };
  const marks = {
    generic: <><rect x="5" y="4" width="7" height="7" rx="1" /><rect x="16" y="4" width="7" height="7" rx="1" /><rect x="5" y="15" width="7" height="7" rx="1" /><rect x="16" y="15" width="7" height="7" rx="1" /></>,
    client: <><circle cx="14" cy="13" r="9" /><path d="M5 13h18M14 4c3 3 3 15 0 18M14 4c-3 3-3 15 0 18" /></>,
    service: <><circle cx="14" cy="6" r="2.5" /><circle cx="6" cy="19" r="2.5" /><circle cx="22" cy="19" r="2.5" /><path d="M14 8.5v4.5M14 13L7.5 17M14 13l6.5 4" /></>,
    database: <><ellipse cx="14" cy="6" rx="9" ry="3" /><path d="M5 6v7c0 1.7 4 3 9 3s9-1.3 9-3V6M5 13v7c0 1.7 4 3 9 3s9-1.3 9-3v-7" /></>,
    queue: <><path d="M5 6h18M5 13h18M5 20h18" /><circle cx="8" cy="6" r="1.6" fill="currentColor" /><circle cx="14" cy="13" r="1.6" fill="currentColor" /><circle cx="20" cy="20" r="1.6" fill="currentColor" /></>,
    storage: <><path d="M5 8h7l2-3h9v17H5z" /><path d="M9 13h10M9 17h7" /></>,
  }[kind] ?? null;
  if (!marks) return null;
  return <svg viewBox="0 0 28 26" {...common}>{marks}</svg>;
};

const SemanticNodeOverlay = ({ elements, appState }) => {
  const zoom = Number(appState?.zoom?.value ?? 1);
  const scrollX = Number(appState?.scrollX ?? 0);
  const scrollY = Number(appState?.scrollY ?? 0);
  const offsetLeft = Number(appState?.offsetLeft ?? 0);
  const offsetTop = Number(appState?.offsetTop ?? 0);
  const boxes = [];
  const connectors = [];
  for (const element of elements) {
    if (
      element.customData?.iaElementType === "box"
      && hasCanonicalBoardAngle(element)
    ) {
      boxes.push(element);
    } else if (
      element.type === "arrow"
      && element.customData?.iaLabel
      && hasCanonicalBoardAngle(element)
    ) {
      connectors.push(element);
    }
  }
  const screenPoint = (x, y) => ({
    left: (Number(x ?? 0) + scrollX) * zoom + offsetLeft,
    top: (Number(y ?? 0) + scrollY) * zoom + offsetTop,
  });

  return (
    <div className="semantic-node-overlay" aria-hidden="true">
      {boxes.map((element) => {
        const width = Number(element.width ?? 0) * zoom;
        const height = Number(element.height ?? 0) * zoom;
        const size = Math.max(18, Math.min(34, width * 0.28, height * 0.3));
        const origin = screenPoint(element.x, element.y);
        const left = origin.left + (width - size) / 2;
        const top = origin.top + Math.max(8, height * 0.14);
        const kind = element.customData?.iaKind;
        const hasPictogram = !["decision", "ellipse"].includes(kind);
        return (
          <React.Fragment key={element.id}>
            {hasPictogram && (
              <div
                className="semantic-node-pictogram"
                style={{
                  color: normalizedHex(element.strokeColor, "#4b3abf"),
                  height: size,
                  left,
                  top,
                  width: size,
                }}
              >
                <SemanticPictogram kind={kind} />
              </div>
            )}
            <div
              className="semantic-node-label"
              style={{
                color: normalizedHex(element.strokeColor, "#1f2937"),
                fontSize: Math.max(11, Math.min(15, 14 * zoom)),
                height: hasPictogram ? Math.max(20, height * 0.34) : height,
                left: origin.left + Math.max(6, 8 * zoom),
                top: hasPictogram ? origin.top + height * 0.59 : origin.top,
                width: Math.max(0, width - Math.max(12, 16 * zoom)),
              }}
            >
              {String(element.customData?.iaLabel ?? "")}
            </div>
          </React.Fragment>
        );
      })}
      {connectors.map((element) => {
        const start = pointAt(element, 0);
        const end = pointAt(element, -1);
        const center = screenPoint(
          (start.x + end.x) / 2,
          (start.y + end.y) / 2,
        );
        return (
          <div
            className="semantic-connector-label"
            key={`${element.id}--label`}
            style={{
              color: normalizedHex(element.strokeColor, "#1f2937"),
              left: center.left,
              top: center.top,
            }}
          >
            {String(element.customData?.iaLabel ?? "")}
          </div>
        );
      })}
    </div>
  );
};

const SemanticOverlayHost = React.memo(({ store }) => {
  const scene = useSyncExternalStore(
    store.subscribe,
    store.getSnapshot,
    store.getSnapshot,
  );
  return (
    <SemanticNodeOverlay
      elements={scene.elements}
      appState={scene.appState}
    />
  );
});

const normalizeScene = (elements, appState, files, currentBoxKind) => {
  const live = getNonDeletedElements(elements);
  const textByContainer = new Map();
  const supported = [];
  const pendingContainerLabels = [];
  let unsupportedElementCount = Object.keys(files ?? {}).length;

  for (const element of live) {
    if (!hasCanonicalBoardAngle(element)) {
      unsupportedElementCount += 1;
      continue;
    }
    if (element.type === "text") {
      const containerID = element.containerId
        ?? element.customData?.iaContainerID;
      if (containerID) {
        textByContainer.set(containerID, element);
        continue;
      }
    }
    if (element.containerId || element.customData?.iaContainerID) continue;
    const customData = element.customData ?? {};
    const boardID = typeof customData.iaElementID === "string"
      ? customData.iaElementID
      : null;

    if (customData.iaElementType === "label") {
      supported.push({
        type: "label",
        webID: element.id,
        boardID,
        x: Number(element.x),
        y: Number(element.y),
        text: String(element.text ?? customData.iaText ?? ""),
        color: normalizedHex(customData.iaColor, "#1f2937"),
      });
      continue;
    }

    if (["rectangle", "diamond", "ellipse"].includes(element.type)) {
      const supportedIndex = supported.length;
      supported.push({
        type: "box",
        webID: element.id,
        boardID,
        x: Number(element.x),
        y: Number(element.y),
        width: Number(element.width),
        height: Number(element.height),
        label: String(customData.iaLabel ?? ""),
        nodeKind: typeof customData.iaKind === "string"
          ? customData.iaKind
          : boxKindForExcalType(element.type, currentBoxKind),
        fill: normalizedHex(element.backgroundColor, "#ffffff"),
        stroke: normalizedHex(element.strokeColor, "#4b3abf"),
      });
      pendingContainerLabels.push({ element, supportedIndex });
      continue;
    }

    if (element.type === "arrow") {
      const start = pointAt(element, 0);
      const end = pointAt(element, -1);
      const supportedIndex = supported.length;
      supported.push({
        type: "connector",
        webID: element.id,
        boardID,
        startX: start.x,
        startY: start.y,
        endX: end.x,
        endY: end.y,
        points: (element.points ?? []).map((point) => ({
          x: Number(element.x ?? 0) + Number(point[0] ?? 0),
          y: Number(element.y ?? 0) + Number(point[1] ?? 0),
        })),
        sourceWebID: element.startBinding?.elementId ?? null,
        targetWebID: element.endBinding?.elementId ?? null,
        startAnchorPolicy: customData.iaStartAnchorPolicy ?? "automatic",
        endAnchorPolicy: customData.iaEndAnchorPolicy ?? "automatic",
        label: String(customData.iaLabel ?? ""),
        stroke: normalizedHex(element.strokeColor, "#1f2937"),
      });
      pendingContainerLabels.push({ element, supportedIndex });
      continue;
    }

    if (element.type === "text") {
      supported.push({
        type: "label",
        webID: element.id,
        boardID,
        x: Number(element.x),
        y: Number(element.y),
        text: String(element.text ?? ""),
        color: normalizedHex(element.strokeColor, "#1f2937"),
      });
      continue;
    }

    if (
      element.type === "freedraw"
      || element.type === "line"
    ) {
      supported.push({
        type: "stroke",
        webID: element.id,
        boardID,
        points: (element.points ?? []).map((point) => ({
          x: Number(element.x ?? 0) + Number(point[0] ?? 0),
          y: Number(element.y ?? 0) + Number(point[1] ?? 0),
        })),
        width: Number(element.strokeWidth ?? 2),
        color: normalizedHex(element.strokeColor, "#ed4e2f"),
      });
      continue;
    }

    unsupportedElementCount += 1;
  }

  for (const { element, supportedIndex } of pendingContainerLabels) {
    supported[supportedIndex].label = elementLabel(element, textByContainer);
  }

  return {
    event: "scene",
    elements: supported,
    zoom: Number.isFinite(Number(appState?.zoom?.value))
      ? Number(appState.zoom.value)
      : null,
    selectedWebIDs: Object.keys(appState?.selectedElementIds ?? {}).filter(
      (id) => appState.selectedElementIds[id],
    ),
    tool: nativeToolForExcalType(appState?.activeTool?.type),
    boxKind: boxKindForExcalType(
      appState?.activeTool?.type,
      currentBoxKind,
    ),
    unsupportedElementCount,
  };
};

// Excalidraw increments an element's version for every semantic mutation.
// Combine that monotonic scene version with the small set of persisted app
// state instead of serializing every coordinate and connector point merely to
// suppress duplicate callbacks.
const sceneRevision = (elements, appState, files, currentBoxKind) => {
  const selectedIDs = Object.keys(appState?.selectedElementIds ?? {})
    .filter((id) => appState.selectedElementIds[id])
    .sort()
    .join(",");
  return [
    getSceneVersion(elements),
    elements.length,
    Number(appState?.zoom?.value ?? 1),
    appState?.activeTool?.type ?? "selection",
    selectedIDs,
    currentBoxKind,
    Object.keys(files ?? {}).length,
  ].join("|");
};

const strokeSkeleton = (element) => {
  const points = element.points ?? [];
  const origin = points[0] ?? { x: 0, y: 0 };
  const relativePoints = points.map((point) => [
    Number(point.x) - Number(origin.x),
    Number(point.y) - Number(origin.y),
  ]);
  const xs = relativePoints.map((point) => point[0]);
  const ys = relativePoints.map((point) => point[1]);
  const width = Math.max(1, Math.max(...xs, 0) - Math.min(...xs, 0));
  const height = Math.max(1, Math.max(...ys, 0) - Math.min(...ys, 0));

  return {
    type: "freedraw",
    id: element.boardID,
    x: Number(origin.x),
    y: Number(origin.y),
    width,
    height,
    points: relativePoints,
    pressures: [],
    simulatePressure: true,
    lastCommittedPoint: null,
    strokeColor: element.color,
    backgroundColor: "transparent",
    fillStyle: "solid",
    strokeWidth: element.width,
    strokeStyle: "solid",
    roughness: 1,
    opacity: 100,
    angle: 0,
    seed: stableSeed(element.boardID),
    version: 1,
    versionNonce: stableSeed(`${element.boardID}:version`),
    isDeleted: false,
    groupIds: [],
    frameId: null,
    roundness: null,
    boundElements: null,
    updated: 1,
    link: null,
    locked: false,
    customData: {
      iaElementID: element.boardID,
      iaElementType: "stroke",
    },
  };
};

const excalidrawSkeleton = (element) => {
    if (element.type === "box") {
      const presentation = semanticBoxPresentation(element.nodeKind);
      return {
        type: presentation.type,
        id: element.boardID,
        x: element.x,
        y: element.y,
        width: element.width,
        height: element.height,
        backgroundColor: element.fill,
        strokeColor: element.stroke,
        fillStyle: "solid",
        strokeWidth: 2,
        strokeStyle: "solid",
        roughness: 0,
        roundness: presentation.roundness,
        customData: {
          iaElementID: element.boardID,
          iaElementType: "box",
          iaKind: element.nodeKind,
          iaLabel: element.label,
          iaVisualKey: presentation.visualKey,
        },
      };
    }

    if (element.type === "connector") {
      return {
        type: "arrow",
        id: element.boardID,
        x: element.startX,
        y: element.startY,
        width: element.endX - element.startX,
        height: element.endY - element.startY,
        points: (element.points?.length ? element.points : [
          { x: element.startX, y: element.startY },
          { x: element.endX, y: element.endY },
        ]).map((point) => [
          Number(point.x) - Number(element.startX),
          Number(point.y) - Number(element.startY),
        ]),
        strokeColor: element.stroke,
        strokeWidth: 2,
        roughness: 0,
        start: element.sourceID ? { id: element.sourceID } : undefined,
        end: element.targetID ? { id: element.targetID } : undefined,
        customData: {
          iaElementID: element.boardID,
          iaElementType: "connector",
          iaLabel: element.label,
          iaStartAnchorPolicy: element.startAnchorPolicy,
          iaEndAnchorPolicy: element.endAnchorPolicy,
        },
      };
    }

    if (element.type === "label") {
      return {
        type: "text",
        id: element.boardID,
        x: element.x,
        y: element.y,
        width: 240,
        height: 32,
        text: element.text,
        originalText: element.text,
        fontSize: 15,
        fontFamily: 2,
        textAlign: "left",
        verticalAlign: "top",
        lineHeight: 1.25,
        containerId: null,
        strokeColor: element.color,
        backgroundColor: "transparent",
        fillStyle: "solid",
        strokeWidth: 1,
        roughness: 0,
        opacity: 100,
        customData: {
          iaElementID: element.boardID,
          iaElementType: "label",
          iaText: element.text,
          iaColor: element.color,
        },
      };
    }

    return strokeSkeleton(element);
};

const toExcalidrawElements = (scene) => {
  const skeletons = scene.elements.map(excalidrawSkeleton);
  return convertToExcalidrawElements(skeletons, { regenerateIds: false });
};

const defaultNativeControls = {
  revisionStatus: "Board",
  notice: null,
  noticeIsError: false,
  isInspecting: false,
  canSave: false,
  hasRevisions: false,
  canAttach: false,
  canExport: false,
  isExporting: false,
};

const installNativeWindowBridge = ({
  api,
  currentBoxKindRef,
  loadingRef,
  nativeControlsRef,
  previousActiveToolRef,
  publication,
  renderCountRef,
  setNativeControls,
  setReadOnly,
  updateSemanticOverlay,
}) => {
  const synchronizeControls = (controls) => {
    const previous = nativeControlsRef.current;
    nativeControlsRef.current = controls ?? defaultNativeControls;
    reportControlDiagnostic(
      previous,
      nativeControlsRef.current,
      renderCountRef.current,
    );
    setNativeControls(nativeControlsRef.current);
    startInteractionDiagnostic(() => ({
      api,
      phase: "control-transition",
      nativeControls: nativeControlsRef.current,
      renderCount: renderCountRef.current,
    }));
    finishInteractionDiagnostic();
  };
  const readScene = () => ({
    elements: api.getSceneElements(),
    appState: api.getAppState(),
    files: api.getFiles(),
  });
  const snapshot = (scene = readScene()) => normalizeScene(
    scene.elements,
    scene.appState,
    scene.files,
    currentBoxKindRef.current,
  );
  let nativeUpdateGeneration = 0;
  let hasLoadedScene = false;
  let deferredNativeUpdate = null;
  let deferredChange = null;
  let receivedUserInputDuringNativeUpdate = false;
  let nativeSceneMutationCount = 0;

  const runOrDeferNativeUpdate = (update) => {
    if (publication.snapshot().isPointerInteractionActive) {
      deferredNativeUpdate = update;
      return false;
    }
    update();
    return true;
  };
  const beginNativeUpdate = () => {
    nativeUpdateGeneration += 1;
    if (!loadingRef.current) {
      deferredChange = null;
      receivedUserInputDuringNativeUpdate = false;
    }
    loadingRef.current = true;
    return nativeUpdateGeneration;
  };
  const finishNativeUpdate = (generation) => {
    window.requestAnimationFrame(() => {
      window.requestAnimationFrame(() => {
        if (generation !== nativeUpdateGeneration) return;
        const scene = readScene();
        updateSemanticOverlay(scene.elements, scene.appState);
        loadingRef.current = false;
        if (receivedUserInputDuringNativeUpdate) {
          publication.acceptScene(deferredChange ?? scene);
        } else {
          publication.adoptScene(scene);
        }
        deferredChange = null;
        receivedUserInputDuringNativeUpdate = false;
      });
    });
  };

  const nativeAppState = (
    scene,
    { appliesZoom = false, transparent = false } = {},
  ) => {
    currentBoxKindRef.current = scene.boxKind ?? currentBoxKindRef.current;
    const zoom = Number(scene.zoom);
    return {
      selectedElementIds: scene.selectedID
        ? { [scene.selectedID]: true }
        : {},
      ...(appliesZoom && Number.isFinite(zoom)
        ? { zoom: { value: zoom } }
        : {}),
      ...(transparent ? { viewBackgroundColor: "transparent" } : {}),
      ...itemStyleForTool(scene.tool),
    };
  };

  const synchronizePresentation = (scene) => {
    const nextReadOnly = Boolean(scene.readOnly);
    setReadOnly((current) => current === nextReadOnly ? current : nextReadOnly);
    const nextControls = scene.controls ?? defaultNativeControls;
    if (!nativeControlsEqual(nativeControlsRef.current, nextControls)) {
      synchronizeControls(nextControls);
    }
  };

  const updateExcalidrawScene = (sceneData) => {
    nativeSceneMutationCount += 1;
    api.updateScene({ ...sceneData, commitToHistory: false });
  };

  window.interviewArcLoad = (serializedScene) => {
    const scene = JSON.parse(serializedScene);
    const elements = toExcalidrawElements(scene);
    synchronizePresentation(scene);
    runOrDeferNativeUpdate(() => {
      const shouldRevealInitialContent = !hasLoadedScene;
      hasLoadedScene = true;
      const generation = beginNativeUpdate();
      if (shouldRevealInitialContent && !scene.readOnly) {
        const activeTool = excalTypeForNativeTool(scene.tool, scene.boxKind);
        previousActiveToolRef.current = activeTool;
        api.setActiveTool({ type: activeTool });
      }
      updateExcalidrawScene({
        elements,
        appState: nativeAppState(scene, {
          appliesTool: shouldRevealInitialContent,
          appliesZoom: shouldRevealInitialContent,
          transparent: true,
        }),
      });
      window.requestAnimationFrame(() => {
        if (elements.length > 0 && shouldRevealInitialContent) {
          api.scrollToContent(elements, {
            fitToContent: false,
            animate: false,
          });
        }
        finishNativeUpdate(generation);
      });
    });
    return elements.length;
  };

  window.interviewArcSetState = (serializedState) => {
    const state = JSON.parse(serializedState);
    synchronizePresentation(state);
    runOrDeferNativeUpdate(() => {
      const desiredTool = !state.readOnly
        ? excalTypeForNativeTool(state.tool, state.boxKind)
        : null;
      const appState = nativeAppState(state, {
        appliesZoom: true,
      });
      const currentAppState = api.getAppState();
      const needsTool = desiredTool !== null
        && currentAppState.activeTool.type !== desiredTool;
      const needsAppState = nativeAppStatePatchRequired(
        currentAppState,
        appState,
      );
      if (!needsTool && !needsAppState) return;
      const generation = beginNativeUpdate();
      if (needsTool) {
        previousActiveToolRef.current = desiredTool;
        api.setActiveTool({ type: desiredTool });
      }
      if (needsAppState) updateExcalidrawScene({ appState });
      finishNativeUpdate(generation);
    });
  };

  // Apply native canonicalization without treating an accepted user edit as
  // a new document load. In particular, preserve the current viewport and
  // active tool so ID/bounds/connector corrections never flash or jump.
  window.interviewArcReconcile = (serializedScene) => {
    const scene = JSON.parse(serializedScene);
    const elements = reconcileNativeElementVersions(
      toExcalidrawElements(scene),
      api.getSceneElements(),
      (id, version) => stableSeed(`${id}:reconcile:${version}`),
    );
    synchronizePresentation(scene);
    runOrDeferNativeUpdate(() => {
      const generation = beginNativeUpdate();
      updateExcalidrawScene({
        elements,
        // Canonicalization may replace IDs/bounds/routes, but it must never
        // reset the viewport or tool that the person is actively using.
        appState: nativeAppState(scene),
      });
      finishNativeUpdate(generation);
    });
    return elements.length;
  };

  window.interviewArcFlush = () => {
    const scene = readScene();
    publication.adoptScene(scene);
    return snapshot(scene);
  };
  window.interviewArcSnapshot = snapshot;
  window.interviewArcRuntimeState = () => ({
    activeTool: api.getAppState().activeTool.type,
    zoom: Number(api.getAppState().zoom?.value ?? 1),
    nativeControls: nativeControlsRef.current,
    nativeSceneMutationCount,
  });

  return {
    captureChange(scene) {
      if (!loadingRef.current) return false;
      deferredChange = scene;
      return true;
    },
    noteUserInput() {
      if (loadingRef.current) receivedUserInputDuringNativeUpdate = true;
    },
    completePointerInteraction(didPublish) {
      const update = deferredNativeUpdate;
      deferredNativeUpdate = null;
      // A published pointer scene will synchronously drive SwiftUI with the
      // newest document. Drop an older deferred native snapshot and let that
      // fresh model update return through the bridge instead.
      if (!didPublish) update?.();
    },
  };
};

const BoardActionIcon = ({ name }) => {
  const paths = {
    save: <><path d="M12 3v11" /><path d="m8 10 4 4 4-4" /><path d="M5 17v3h14v-3" /></>,
    draft: <><path d="M9 7H5v4" /><path d="M5 11a7 7 0 1 0 2-5" /><path d="m5 11 4-4" /></>,
    revisions: <><path d="M4 12a8 8 0 1 0 2.3-5.7" /><path d="M4 5v5h5" /><path d="M12 7v5l3 2" /></>,
    attach: <path d="M8.5 12.5 14.8 6.2a3 3 0 0 1 4.2 4.2l-8.5 8.5a5 5 0 0 1-7.1-7.1l8-8" />,
    export: <><path d="M12 21V9" /><path d="m8 13 4-4 4 4" /><path d="M5 4h14v4" /></>,
    working: <><circle cx="12" cy="12" r="8" /><path d="M12 7v5l3 2" /></>,
  };
  return (
    <svg
      aria-hidden="true"
      className="interview-arc-board-action__icon"
      viewBox="0 0 24 24"
    >
      {paths[name]}
    </svg>
  );
};

const BoardChromeControls = ({ controls, onAction }) => {
  const actions = boardChromeActionConfigurations(controls);
  const controlsRef = useRef(null);
  const [layout, setLayout] = useState({ mode: "stacked", right: 12, top: 72 });

  useLayoutEffect(() => {
    const controlsElement = controlsRef.current;
    const shell = controlsElement?.closest(".board-shell");
    if (!controlsElement || !shell) return undefined;

    let frame = 0;
    let toolbarAdapter;
    const updateLayout = () => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => {
        const shellRect = shell.getBoundingClientRect();
        const next = boardChromeLayout({
          viewportWidth: shellRect.width,
          toolbar: toolbarAdapter?.bounds(shell) ?? null,
          controlsWidth: controlsElement.getBoundingClientRect().width,
        });
        setLayout((current) => (
          current.mode === next.mode
            && current.right === next.right
            && current.top === next.top
            ? current
            : next
        ));
      });
    };

    const resizeObserver = new ResizeObserver(updateLayout);
    resizeObserver.observe(shell);
    resizeObserver.observe(controlsElement);
    toolbarAdapter = createBoardToolbarGeometryAdapter({
      root: shell,
      onChange: updateLayout,
    });
    updateLayout();

    return () => {
      cancelAnimationFrame(frame);
      resizeObserver.disconnect();
      toolbarAdapter.disconnect();
    };
  }, []);

  return (
    <div
      aria-label="Board revisions and export"
      className="interview-arc-board-controls"
      data-placement={layout.mode}
      ref={controlsRef}
      role="toolbar"
      style={{ right: layout.right, top: layout.top }}
    >
      {actions.map((action) => (
        <button
          aria-label={action.command === "exportRevision"
            ? (controls.isExporting ? "Exporting board" : "Export board")
            : action.title ?? action.label}
          className={`interview-arc-board-action${action.primary ? " interview-arc-board-action--primary" : ""}`}
          disabled={!action.enabled}
          key={action.command}
          onClick={() => onAction(action.command)}
          title={action.title ?? action.label}
          type="button"
        >
          <BoardActionIcon name={action.icon} />
        </button>
      ))}
    </div>
  );
};

function BoardEditor() {
  const renderCountRef = useRef(0);
  renderCountRef.current += 1;
  const [readOnly, setReadOnly] = useState(false);
  const [nativeControls, setNativeControls] = useState(defaultNativeControls);
  const apiRef = useRef(null);
  // Start closed: Excalidraw publishes an empty scene during bootstrap, before
  // Swift has supplied the durable Board document. The native load adopts the
  // first safe baseline and opens normal publication from that point onward.
  const loadingRef = useRef(true);
  const nativeBridgeRef = useRef(null);
  const nativeControlsRef = useRef(defaultNativeControls);
  const overlayStoreRef = useRef(null);
  if (overlayStoreRef.current === null) {
    overlayStoreRef.current = createSemanticOverlayStore({
      elements: [],
      appState: null,
      fingerprint: "",
    });
  }
  const pointerSubscriptionsRef = useRef([]);
  const currentBoxKindRef = useRef("generic");
  const previousActiveToolRef = useRef("selection");
  const publicationRef = useRef(null);
  if (publicationRef.current === null) {
    publicationRef.current = createScenePublicationController(
      post,
      ({ elements, appState, files }) => normalizeScene(
        elements,
        appState,
        files,
        currentBoxKindRef.current,
      ),
      ({ elements, appState, files }) => sceneRevision(
        elements,
        appState,
        files,
        currentBoxKindRef.current,
      ),
    );
  }

  const updateSemanticOverlay = useCallback((elements, appState) => {
    const snapshot = semanticOverlaySnapshot(elements, appState);
    overlayStoreRef.current.publish({ ...snapshot, appState });
  }, []);

  const handleChange = useCallback((elements, appState, files) => {
    const activeTool = appState?.activeTool?.type ?? "selection";
    if (activeTool !== previousActiveToolRef.current) {
      currentBoxKindRef.current = boxKindForExcalType(
        activeTool,
        currentBoxKindRef.current,
      );
      previousActiveToolRef.current = activeTool;
    }
    const scene = { elements, appState, files };
    reportLayoutDiagnostic(apiRef.current, "change");
    if (nativeBridgeRef.current?.captureChange(scene)) return;
    updateSemanticOverlay(elements, appState);
    publicationRef.current.acceptScene(scene);
  }, [updateSemanticOverlay]);

  const installAPI = useCallback((api) => {
    apiRef.current = api;
    if (
      typeof api.onPointerDown !== "function"
      || typeof api.onPointerUp !== "function"
    ) {
      post({
        event: "failure",
        message: "The local canvas pointer bridge is unavailable.",
      });
      return;
    }
    const nativeBridge = installNativeWindowBridge({
      api,
      currentBoxKindRef,
      loadingRef,
      nativeControlsRef,
      previousActiveToolRef,
      publication: publicationRef.current,
      renderCountRef,
      setNativeControls,
      setReadOnly,
      updateSemanticOverlay,
    });
    nativeBridgeRef.current = nativeBridge;

    for (const unsubscribe of pointerSubscriptionsRef.current) unsubscribe();
    pointerSubscriptionsRef.current = [
      api.onPointerDown(() => {
        reportLayoutDiagnostic(api, "pointer-down", true);
        startInteractionDiagnostic(() => ({
          api,
          phase: "drag",
          nativeControls: nativeControlsRef.current,
          renderCount: renderCountRef.current,
        }));
        nativeBridge.noteUserInput();
        publicationRef.current.beginPointerInteraction();
      }),
      api.onPointerUp(() => {
        reportLayoutDiagnostic(api, "pointer-up", true);
        window.requestAnimationFrame(() => {
          reportLayoutDiagnostic(api, "pointer-up+2raf", true);
        });
        nativeBridge.completePointerInteraction(
          publicationRef.current.endPointerInteraction(),
        );
        finishInteractionDiagnostic();
      }),
    ];

    document.documentElement.dataset.interviewArcBoardReady = "true";
    post({ event: "ready" });
  }, [updateSemanticOverlay]);

  const flushThenPost = useCallback((command) => {
    const scene = window.interviewArcFlush?.();
    if (scene) post({ ...scene, event: "flushedCommand", command });
  }, []);

  const handleNativeAction = useCallback((command) => {
    if (command === "saveRevision") {
      flushThenPost(command);
      return;
    }
    post({ event: "command", command });
  }, [flushThenPost]);

  useEffect(() => {
    const handleKeyDown = (event) => {
      nativeBridgeRef.current?.noteUserInput();
      const key = event.key.toLowerCase();
      const command = event.metaKey || event.ctrlKey;
      if (command && key === "z") {
        event.preventDefault();
        flushThenPost(event.shiftKey ? "redo" : "undo");
      } else if (event.metaKey && key === "s") {
        event.preventDefault();
        flushThenPost("saveRevision");
      } else if (event.metaKey && (key === "+" || key === "=")) {
        event.preventDefault();
        post({ event: "command", command: "zoomIn" });
      } else if (event.metaKey && key === "-") {
        event.preventDefault();
        post({ event: "command", command: "zoomOut" });
      } else if (event.metaKey && key === "0") {
        event.preventDefault();
        post({ event: "command", command: "zoomReset" });
      } else if (event.ctrlKey && ["v", "c", "b", "t", "l", "p", "e"].includes(key)) {
        event.preventDefault();
        const tool = {
          v: "select",
          c: "connector",
          b: "box",
          t: "label",
          l: "line",
          p: "pen",
          e: "eraser",
        }[key];
        post({ event: "command", command: "tool", tool });
      }
    };
    const noteTextInput = () => nativeBridgeRef.current?.noteUserInput();
    const beginRawPointerDiagnostic = () => {
      startInteractionDiagnostic(() => ({
        api: apiRef.current,
        phase: "raw-drag",
        nativeControls: nativeControlsRef.current,
        renderCount: renderCountRef.current,
      }));
    };
    const finishRawPointerDiagnostic = () => {
      finishInteractionDiagnostic();
    };
    const cancelPointerInteraction = () => {
      nativeBridgeRef.current?.completePointerInteraction(
        publicationRef.current.cancelPointerInteraction(),
      );
      finishRawPointerDiagnostic();
    };
    window.addEventListener("keydown", handleKeyDown, true);
    window.addEventListener("beforeinput", noteTextInput, true);
    window.addEventListener("pointerdown", beginRawPointerDiagnostic, true);
    window.addEventListener("pointerup", finishRawPointerDiagnostic, true);
    window.addEventListener("pointercancel", cancelPointerInteraction, true);
    window.addEventListener("blur", cancelPointerInteraction);
    return () => {
      window.removeEventListener("keydown", handleKeyDown, true);
      window.removeEventListener("beforeinput", noteTextInput, true);
      window.removeEventListener("pointerdown", beginRawPointerDiagnostic, true);
      window.removeEventListener("pointerup", finishRawPointerDiagnostic, true);
      window.removeEventListener("pointercancel", cancelPointerInteraction, true);
      window.removeEventListener("blur", cancelPointerInteraction);
      for (const unsubscribe of pointerSubscriptionsRef.current) unsubscribe();
      pointerSubscriptionsRef.current = [];
      nativeBridgeRef.current = null;
      publicationRef.current.reset();
    };
  }, [flushThenPost]);

  return (
    <main className="board-shell">
      <Excalidraw
        excalidrawAPI={installAPI}
        autoFocus={false}
        handleKeyboardGlobally={false}
        gridModeEnabled={false}
        zenModeEnabled={false}
        viewModeEnabled={readOnly}
        theme="light"
        onChange={handleChange}
        validateEmbeddable={() => false}
        renderEmbeddable={() => null}
        onLinkOpen={(_element, event) => event.preventDefault()}
        UIOptions={{
          tools: { image: false },
          canvasActions: {
            changeViewBackgroundColor: false,
            clearCanvas: false,
            export: false,
            loadScene: false,
            saveToActiveFile: false,
            toggleTheme: false,
          },
        }}
      />
      <BoardChromeControls
        controls={nativeControls}
        onAction={handleNativeAction}
      />
      <SemanticOverlayHost store={overlayStoreRef.current} />
    </main>
  );
}

window.addEventListener("error", (event) => {
  post({ event: "failure", message: String(event.message ?? "Board editor failed") });
});
window.addEventListener("unhandledrejection", () => {
  post({ event: "failure", message: "Board editor could not complete that action" });
});

createRoot(document.getElementById("root")).render(<BoardEditor />);
