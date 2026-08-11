import React, { useCallback, useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  Excalidraw,
  convertToExcalidrawElements,
  getNonDeletedElements,
} from "@excalidraw/excalidraw";
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
  textByContainer.get(element.id)?.text ?? "";

const pointAt = (element, index) => {
  const points = element.points ?? [];
  const resolvedIndex = index < 0 ? points.length + index : index;
  const point = points[resolvedIndex] ?? [0, 0];
  return {
    x: Number(element.x ?? 0) + Number(point[0] ?? 0),
    y: Number(element.y ?? 0) + Number(point[1] ?? 0),
  };
};

const normalizeScene = (elements, appState, files, currentBoxKind) => {
  const live = getNonDeletedElements(elements);
  const textByContainer = new Map(
    live
      .filter((element) => element.type === "text" && element.containerId)
      .map((element) => [element.containerId, element]),
  );
  const supported = [];
  let unsupportedElementCount = Object.keys(files ?? {}).length;

  for (const element of live) {
    if (element.containerId) continue;
    const customData = element.customData ?? {};
    const boardID = typeof customData.iaElementID === "string"
      ? customData.iaElementID
      : null;

    if (element.type === "rectangle") {
      supported.push({
        type: "box",
        webID: element.id,
        boardID,
        x: Number(element.x),
        y: Number(element.y),
        width: Number(element.width),
        height: Number(element.height),
        label: elementLabel(element, textByContainer),
        nodeKind: typeof customData.iaKind === "string"
          ? customData.iaKind
          : currentBoxKind,
        fill: normalizedHex(element.backgroundColor, "#ffffff"),
        stroke: normalizedHex(element.strokeColor, "#4b3abf"),
      });
      continue;
    }

    if (element.type === "arrow") {
      const start = pointAt(element, 0);
      const end = pointAt(element, -1);
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
        label: elementLabel(element, textByContainer),
        stroke: normalizedHex(element.strokeColor, "#1f2937"),
      });
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

const toExcalidrawElements = (scene) => {
  const skeletons = scene.elements.map((element) => {
    if (element.type === "box") {
      return {
        type: "rectangle",
        id: element.boardID,
        x: element.x,
        y: element.y,
        width: element.width,
        height: element.height,
        backgroundColor: element.fill,
        strokeColor: element.stroke,
        fillStyle: "solid",
        strokeWidth: 2,
        roughness: 0,
        roundness: { type: 3 },
        label: element.label
          ? { text: element.label, fontSize: 16, fontFamily: 2 }
          : undefined,
        customData: {
          iaElementID: element.boardID,
          iaKind: element.nodeKind,
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
        points: [
          [0, 0],
          [element.endX - element.startX, element.endY - element.startY],
        ],
        strokeColor: element.stroke,
        strokeWidth: 2,
        roughness: 0,
        start: element.sourceID ? { id: element.sourceID } : undefined,
        end: element.targetID ? { id: element.targetID } : undefined,
        label: element.label
          ? { text: element.label, fontSize: 14, fontFamily: 2 }
          : undefined,
        customData: {
          iaElementID: element.boardID,
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
        text: element.text,
        strokeColor: element.color,
        fontSize: 16,
        fontFamily: 2,
        customData: { iaElementID: element.boardID },
      };
    }

    return strokeSkeleton(element);
  });

  return convertToExcalidrawElements(skeletons, { regenerateIds: false });
};

function BoardEditor() {
  const [readOnly, setReadOnly] = useState(false);
  const apiRef = useRef(null);
  const loadingRef = useRef(false);
  const pointerDownRef = useRef(false);
  const pendingRef = useRef(null);
  const debounceRef = useRef(null);
  const currentBoxKindRef = useRef("service");

  const publish = useCallback(() => {
    if (loadingRef.current || !pendingRef.current) return;
    const { elements, appState, files } = pendingRef.current;
    pendingRef.current = null;
    post(normalizeScene(elements, appState, files, currentBoxKindRef.current));
  }, []);

  const schedulePublish = useCallback(() => {
    window.clearTimeout(debounceRef.current);
    if (!pointerDownRef.current) {
      debounceRef.current = window.setTimeout(publish, 300);
    }
  }, [publish]);

  const handleChange = useCallback((elements, appState, files) => {
    if (loadingRef.current) return;
    pendingRef.current = { elements, appState, files };
    schedulePublish();
  }, [schedulePublish]);

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
          currentItemFontFamily: 2,
          currentItemRoughness: 0,
          currentItemStrokeColor: "#4b3abf",
          currentItemBackgroundColor: "#ffffff",
          currentItemFillStyle: "solid",
        },
      });
      if (!scene.readOnly) {
        api.setActiveTool({ type: toolType(scene.tool) });
      }
      api.history.clear();
      requestAnimationFrame(() => requestAnimationFrame(() => {
        loadingRef.current = false;
        if (elements.length > 0) {
          api.scrollToContent(elements, { fitToContent: true });
        }
      }));
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
        },
      });
    };

    window.interviewArcSnapshot = () => normalizeScene(
      api.getSceneElements(),
      api.getAppState(),
      api.getFiles(),
      currentBoxKindRef.current,
    );

    document.documentElement.dataset.interviewArcBoardReady = "true";
    post({ event: "ready" });
  }, []);

  useEffect(() => {
    const handleKeyDown = (event) => {
      const key = event.key.toLowerCase();
      const command = event.metaKey || event.ctrlKey;
      if (command && key === "z") {
        event.preventDefault();
        post({ event: "command", command: event.shiftKey ? "redo" : "undo" });
      } else if (event.metaKey && key === "s") {
        event.preventDefault();
        post({ event: "command", command: "saveRevision" });
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
        gridModeEnabled={true}
        zenModeEnabled={true}
        viewModeEnabled={readOnly}
        theme="light"
        onChange={handleChange}
        onPointerDown={() => { pointerDownRef.current = true; }}
        onPointerUp={() => {
          pointerDownRef.current = false;
          window.clearTimeout(debounceRef.current);
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
