const number = (value) => Number(value ?? 0);

const relevantElement = (element) =>
  !element.isDeleted
  && (
    element.customData?.iaElementType === "box"
    || (element.type === "arrow" && element.customData?.iaLabel)
  );

const elementFingerprint = (element) => ({
  id: String(element.id ?? ""),
  type: String(element.type ?? ""),
  x: number(element.x),
  y: number(element.y),
  width: number(element.width),
  height: number(element.height),
  points: (element.points ?? []).map((point) => [
    number(point?.[0]),
    number(point?.[1]),
  ]),
  strokeColor: String(element.strokeColor ?? ""),
  kind: String(element.customData?.iaKind ?? ""),
  label: String(element.customData?.iaLabel ?? ""),
});

export const semanticOverlayFingerprint = (elements, appState) => JSON.stringify({
  viewport: {
    zoom: number(appState?.zoom?.value ?? 1),
    scrollX: number(appState?.scrollX),
    scrollY: number(appState?.scrollY),
    offsetLeft: number(appState?.offsetLeft),
    offsetTop: number(appState?.offsetTop),
  },
  elements: (elements ?? [])
    .filter(relevantElement)
    .map(elementFingerprint),
});
