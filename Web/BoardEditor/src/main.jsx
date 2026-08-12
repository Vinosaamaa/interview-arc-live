import React, {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
} from "react";
import { createRoot } from "react-dom/client";
import {
  Excalidraw,
  convertToExcalidrawElements,
  getNonDeletedElements,
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
  BOARD_CHROME_FALLBACK_PLACEMENT,
  boardChromeActionConfigurations,
  resolveBoardChromePlacement,
} from "./board-chrome.js";
import "./style.css";

const bridge = window.webkit?.messageHandlers?.boardBridge;

const post = (payload) => {
  bridge?.postMessage(payload);
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
  setNativeControls,
  setReadOnly,
  updateSemanticOverlay,
}) => {
  const synchronizeControls = (controls) => {
    nativeControlsRef.current = controls ?? defaultNativeControls;
    setNativeControls(nativeControlsRef.current);
  };
  const refreshOverlay = () => {
    updateSemanticOverlay(api.getSceneElements(), api.getAppState());
  };

  window.interviewArcLoad = (serializedScene) => {
    const scene = JSON.parse(serializedScene);
    const elements = toExcalidrawElements(scene);
    loadingRef.current = true;
    publication.reset();
    setReadOnly(Boolean(scene.readOnly));
    synchronizeControls(scene.controls);
    currentBoxKindRef.current = scene.boxKind ?? "generic";
    previousActiveToolRef.current = excalTypeForNativeTool(
      scene.tool,
      scene.boxKind,
    );
    api.updateScene({
      elements,
      appState: {
        selectedElementIds: scene.selectedID
          ? { [scene.selectedID]: true }
          : {},
        zoom: { value: Number(scene.zoom ?? 1) },
        viewBackgroundColor: "transparent",
        ...itemStyleForTool(scene.tool),
      },
    });
    window.requestAnimationFrame(() => {
      if (!scene.readOnly) {
        api.setActiveTool({
          type: excalTypeForNativeTool(scene.tool, scene.boxKind),
        });
      }
      if (elements.length > 0) {
        api.scrollToContent(elements, {
          fitToContent: false,
          animate: false,
        });
      }
      window.requestAnimationFrame(() => {
        refreshOverlay();
        loadingRef.current = false;
      });
    });
    return elements.length;
  };

  window.interviewArcSetState = (serializedState) => {
    const state = JSON.parse(serializedState);
    currentBoxKindRef.current = state.boxKind ?? currentBoxKindRef.current;
    setReadOnly(Boolean(state.readOnly));
    synchronizeControls(state.controls);
    if (!state.readOnly) {
      previousActiveToolRef.current = excalTypeForNativeTool(
        state.tool,
        state.boxKind,
      );
      api.setActiveTool({
        type: excalTypeForNativeTool(state.tool, state.boxKind),
      });
    }
    const zoom = Number(state.zoom);
    api.updateScene({
      appState: {
        selectedElementIds: state.selectedID
          ? { [state.selectedID]: true }
          : {},
        ...(Number.isFinite(zoom) ? { zoom: { value: zoom } } : {}),
        ...itemStyleForTool(state.tool),
      },
    });
    window.requestAnimationFrame(refreshOverlay);
  };

  const snapshot = () => normalizeScene(
    api.getSceneElements(),
    api.getAppState(),
    api.getFiles(),
    currentBoxKindRef.current,
  );
  window.interviewArcFlush = () => {
    publication.reset();
    return snapshot();
  };
  window.interviewArcSnapshot = snapshot;
  window.interviewArcRuntimeState = () => ({
    activeTool: api.getAppState().activeTool.type,
    nativeControls: nativeControlsRef.current,
  });
};

const useBoardChromePlacement = () => {
  const controlsRef = useRef(null);
  const fullControlsWidthRef = useRef(null);
  const [compact, setCompact] = useState(false);
  const [placement, setPlacement] = useState(
    BOARD_CHROME_FALLBACK_PLACEMENT,
  );

  useLayoutEffect(() => {
    let animationFrame = null;
    const measure = () => {
      const controls = controlsRef.current;
      const container = document.querySelector(".board-shell");
      const toolbar = document.querySelector(".App-toolbar-container");
      if (!controls || !container || !toolbar) return;
      const controlsRect = controls.getBoundingClientRect();
      const containerRect = container.getBoundingClientRect();
      const toolbarRect = toolbar.getBoundingClientRect();
      if (!compact) fullControlsWidthRef.current = controlsRect.width;
      const next = resolveBoardChromePlacement({
        container: containerRect,
        toolbar: toolbarRect,
        currentControlsWidth: controlsRect.width,
        fullControlsWidth: fullControlsWidthRef.current ?? controlsRect.width,
        viewportWidth: window.innerWidth,
      });
      if (next.compact !== compact) {
        setCompact(next.compact);
        return;
      }
      setPlacement({ right: next.right, top: next.top });
    };
    const scheduleMeasure = () => {
      if (animationFrame !== null) window.cancelAnimationFrame(animationFrame);
      animationFrame = window.requestAnimationFrame(measure);
    };
    const resizeObserver = new ResizeObserver(scheduleMeasure);
    const mutationObserver = new MutationObserver(scheduleMeasure);
    if (controlsRef.current) resizeObserver.observe(controlsRef.current);
    const container = document.querySelector(".board-shell");
    if (container) resizeObserver.observe(container);
    const toolbar = document.querySelector(".App-toolbar-container");
    if (toolbar) resizeObserver.observe(toolbar);
    mutationObserver.observe(document.body, { childList: true, subtree: true });
    window.addEventListener("resize", scheduleMeasure);
    scheduleMeasure();
    return () => {
      if (animationFrame !== null) window.cancelAnimationFrame(animationFrame);
      resizeObserver.disconnect();
      mutationObserver.disconnect();
      window.removeEventListener("resize", scheduleMeasure);
    };
  }, [compact]);

  return { compact, controlsRef, placement };
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
  const { compact, controlsRef, placement } = useBoardChromePlacement();
  const status = controls.notice ?? controls.revisionStatus;

  return (
    <div
      aria-label="Board revisions and export"
      className="interview-arc-board-controls"
      data-compact={compact ? "true" : "false"}
      ref={controlsRef}
      role="toolbar"
      style={placement}
    >
      <span
        className={`interview-arc-board-status${controls.noticeIsError ? " interview-arc-board-status--error" : ""}`}
        title={status}
        role={controls.noticeIsError ? "alert" : "status"}
      >
        {status}
      </span>
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
          <span className="interview-arc-board-action__label">
            {action.label}
          </span>
        </button>
      ))}
    </div>
  );
};

function BoardEditor() {
  const [readOnly, setReadOnly] = useState(false);
  const [nativeControls, setNativeControls] = useState(defaultNativeControls);
  const [overlayScene, setOverlayScene] = useState({
    elements: [],
    appState: null,
  });
  const apiRef = useRef(null);
  const loadingRef = useRef(false);
  const nativeControlsRef = useRef(defaultNativeControls);
  const overlayFingerprintRef = useRef("");
  const pointerSubscriptionsRef = useRef([]);
  const currentBoxKindRef = useRef("generic");
  const previousActiveToolRef = useRef("selection");
  const publicationRef = useRef(null);
  if (publicationRef.current === null) {
    publicationRef.current = createScenePublicationController((scene) => {
      if (loadingRef.current) return;
      const { elements, appState, files } = scene;
      post(normalizeScene(
        elements,
        appState,
        files,
        currentBoxKindRef.current,
      ));
    });
  }

  const updateSemanticOverlay = useCallback((elements, appState) => {
    const snapshot = semanticOverlaySnapshot(elements, appState);
    const { fingerprint } = snapshot;
    if (overlayFingerprintRef.current === fingerprint) return;
    overlayFingerprintRef.current = fingerprint;
    setOverlayScene({ elements: snapshot.elements, appState });
  }, []);

  const handleChange = useCallback((elements, appState, files) => {
    if (loadingRef.current) return;
    const activeTool = appState?.activeTool?.type ?? "selection";
    if (activeTool !== previousActiveToolRef.current) {
      currentBoxKindRef.current = boxKindForExcalType(
        activeTool,
        currentBoxKindRef.current,
      );
      previousActiveToolRef.current = activeTool;
    }
    updateSemanticOverlay(elements, appState);
    publicationRef.current.acceptScene({ elements, appState, files });
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
    for (const unsubscribe of pointerSubscriptionsRef.current) unsubscribe();
    pointerSubscriptionsRef.current = [
      api.onPointerDown(() => {
        publicationRef.current.beginPointerInteraction();
      }),
      api.onPointerUp(() => {
        publicationRef.current.endPointerInteraction();
      }),
    ];

    installNativeWindowBridge({
      api,
      currentBoxKindRef,
      loadingRef,
      nativeControlsRef,
      previousActiveToolRef,
      publication: publicationRef.current,
      setNativeControls,
      setReadOnly,
      updateSemanticOverlay,
    });

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
    const cancelPointerInteraction = () => {
      publicationRef.current.cancelPointerInteraction();
    };
    window.addEventListener("keydown", handleKeyDown, true);
    window.addEventListener("pointercancel", cancelPointerInteraction, true);
    window.addEventListener("blur", cancelPointerInteraction);
    return () => {
      window.removeEventListener("keydown", handleKeyDown, true);
      window.removeEventListener("pointercancel", cancelPointerInteraction, true);
      window.removeEventListener("blur", cancelPointerInteraction);
      for (const unsubscribe of pointerSubscriptionsRef.current) unsubscribe();
      pointerSubscriptionsRef.current = [];
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
        renderTopRightUI={() => (
          <BoardChromeControls
            controls={nativeControls}
            onAction={handleNativeAction}
          />
        )}
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
      <SemanticNodeOverlay
        elements={overlayScene.elements}
        appState={overlayScene.appState}
      />
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
