import React, { useCallback, useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  Excalidraw,
  convertToExcalidrawElements,
  getNonDeletedElements,
} from "@excalidraw/excalidraw";
import {
  hasCanonicalBoardAngle,
  semanticOverlayFingerprint,
} from "./semantic-overlay.js";
import "./style.css";

const bridge = window.webkit?.messageHandlers?.boardBridge;

const post = (payload) => {
  bridge?.postMessage(payload);
};

const toolType = (tool) => ({
  select: "selection",
  box: "rectangle",
  connector: "arrow",
  label: "text",
  pen: "freedraw",
  eraser: "eraser",
}[tool] ?? "selection");

// Excalidraw has a smaller native shape vocabulary than BoardNodeVisual. Keep
// these projections architecture-safe (a service must never look like a
// decision diamond) and retain the canonical visual key for reload/export.
const semanticBoxPresentation = (kind) => ({
  generic: { type: "rectangle", roundness: { type: 3 }, visualKey: "roundedRectangle.componentGrid" },
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
  return <svg viewBox="0 0 28 26" {...common}>{marks}</svg>;
};

const SemanticNodeOverlay = ({ elements, appState }) => {
  const zoom = Number(appState?.zoom?.value ?? 1);
  const scrollX = Number(appState?.scrollX ?? 0);
  const scrollY = Number(appState?.scrollY ?? 0);
  const offsetLeft = Number(appState?.offsetLeft ?? 0);
  const offsetTop = Number(appState?.offsetTop ?? 0);
  const live = getNonDeletedElements(elements);
  const boxes = [];
  const connectors = [];
  for (const element of live) {
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
        return (
          <React.Fragment key={element.id}>
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
              <SemanticPictogram kind={element.customData?.iaKind} />
            </div>
            <div
              className="semantic-node-label"
              style={{
                color: normalizedHex(element.strokeColor, "#1f2937"),
                fontSize: Math.max(11, Math.min(15, 14 * zoom)),
                height: Math.max(20, height * 0.34),
                left: origin.left + Math.max(6, 8 * zoom),
                top: origin.top + height * 0.59,
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

    if (
      element.type === "rectangle"
      || ((element.type === "diamond" || element.type === "ellipse")
        && customData.iaElementType === "box")
    ) {
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
          : currentBoxKind,
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
      || (element.type === "line" && customData.iaElementType === "stroke")
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

function BoardEditor() {
  const [readOnly, setReadOnly] = useState(false);
  const [overlayScene, setOverlayScene] = useState({
    elements: [],
    appState: null,
  });
  const apiRef = useRef(null);
  const loadingRef = useRef(false);
  const overlayFingerprintRef = useRef("");
  const pointerDownRef = useRef(false);
  const pendingRef = useRef(null);
  const currentBoxKindRef = useRef("service");

  const publish = useCallback(() => {
    if (loadingRef.current || !pendingRef.current) return;
    const { elements, appState, files } = pendingRef.current;
    pendingRef.current = null;
    post(normalizeScene(elements, appState, files, currentBoxKindRef.current));
  }, []);

  const updateSemanticOverlay = useCallback((elements, appState) => {
    const fingerprint = semanticOverlayFingerprint(elements, appState);
    if (overlayFingerprintRef.current === fingerprint) return;
    overlayFingerprintRef.current = fingerprint;
    setOverlayScene({ elements, appState });
  }, []);

  const handleChange = useCallback((elements, appState, files) => {
    if (loadingRef.current) return;
    updateSemanticOverlay(elements, appState);
    pendingRef.current = { elements, appState, files };
    if (!pointerDownRef.current) publish();
  }, [publish, updateSemanticOverlay]);

  const installAPI = useCallback((api) => {
    apiRef.current = api;

    window.interviewArcLoad = (serializedScene) => {
      const scene = JSON.parse(serializedScene);
      const elements = toExcalidrawElements(scene);
      loadingRef.current = true;
      setReadOnly(Boolean(scene.readOnly));
      currentBoxKindRef.current = scene.boxKind ?? "service";
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
          api.setActiveTool({ type: toolType(scene.tool) });
        }
        if (elements.length > 0) {
          api.scrollToContent(elements, {
            fitToContent: false,
            animate: false,
          });
        }
        window.requestAnimationFrame(() => {
          updateSemanticOverlay(
            api.getSceneElements(),
            api.getAppState(),
          );
          loadingRef.current = false;
        });
      });
      return elements.length;
    };

    window.interviewArcSetState = (serializedState) => {
      const state = JSON.parse(serializedState);
      currentBoxKindRef.current = state.boxKind ?? currentBoxKindRef.current;
      setReadOnly(Boolean(state.readOnly));
      if (!state.readOnly) {
        api.setActiveTool({ type: toolType(state.tool) });
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
      window.requestAnimationFrame(() => {
        updateSemanticOverlay(
          api.getSceneElements(),
          api.getAppState(),
        );
      });
    };

    window.interviewArcFlush = () => {
      pendingRef.current = null;
      return normalizeScene(
        api.getSceneElements(),
        api.getAppState(),
        api.getFiles(),
        currentBoxKindRef.current,
      );
    };

    window.interviewArcSnapshot = () => normalizeScene(
      api.getSceneElements(),
      api.getAppState(),
      api.getFiles(),
      currentBoxKindRef.current,
    );

    document.documentElement.dataset.interviewArcBoardReady = "true";
    post({ event: "ready" });
  }, [updateSemanticOverlay]);

  useEffect(() => {
    const flushThenPost = (command) => {
      const scene = window.interviewArcFlush?.();
      if (scene) post({ ...scene, event: "flushedCommand", command });
    };
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
      } else if (event.ctrlKey && ["v", "c", "b", "t", "p", "e"].includes(key)) {
        event.preventDefault();
        const tool = {
          v: "select",
          c: "connector",
          b: "box",
          t: "label",
          p: "pen",
          e: "eraser",
        }[key];
        post({ event: "command", command: "tool", tool });
      }
    };
    window.addEventListener("keydown", handleKeyDown, true);
    return () => window.removeEventListener("keydown", handleKeyDown, true);
  }, []);

  return (
    <main className="board-shell">
      <Excalidraw
        excalidrawAPI={installAPI}
        autoFocus={false}
        handleKeyboardGlobally={false}
        gridModeEnabled={false}
        zenModeEnabled={true}
        viewModeEnabled={readOnly}
        theme="light"
        onChange={handleChange}
        onPointerDown={() => { pointerDownRef.current = true; }}
        onPointerUp={() => {
          pointerDownRef.current = false;
          publish();
        }}
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
