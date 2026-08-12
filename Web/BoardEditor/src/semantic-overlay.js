const number = (value) => Number(value ?? 0);

export const hasCanonicalBoardAngle = (element) =>
  Math.abs(number(element?.angle)) < 0.000_001;

const relevantElement = (element) =>
  !element.isDeleted
  && (
    element.customData?.iaElementType === "box"
    || (element.type === "arrow" && element.customData?.iaLabel)
  );

export const semanticOverlayElements = (elements) =>
  (elements ?? []).filter(relevantElement);

const append = (fingerprint, value) => {
  const text = String(value ?? "");
  return `${fingerprint}${text.length}:${text}`;
};

const fingerprintRelevantElements = (elements, appState) => {
  let fingerprint = "";
  fingerprint = append(fingerprint, number(appState?.zoom?.value ?? 1));
  fingerprint = append(fingerprint, number(appState?.scrollX));
  fingerprint = append(fingerprint, number(appState?.scrollY));
  fingerprint = append(fingerprint, number(appState?.offsetLeft));
  fingerprint = append(fingerprint, number(appState?.offsetTop));

  for (const element of elements) {
    fingerprint = append(fingerprint, element.id);
    fingerprint = append(fingerprint, element.type);
    fingerprint = append(fingerprint, element.version);
    fingerprint = append(fingerprint, element.versionNonce);
    fingerprint = append(fingerprint, number(element.x));
    fingerprint = append(fingerprint, number(element.y));
    fingerprint = append(fingerprint, number(element.width));
    fingerprint = append(fingerprint, number(element.height));
    fingerprint = append(fingerprint, number(element.angle));
    fingerprint = append(fingerprint, element.strokeColor);
    fingerprint = append(fingerprint, element.customData?.iaKind);
    fingerprint = append(fingerprint, element.customData?.iaLabel);
    for (const point of element.points ?? []) {
      fingerprint = append(fingerprint, number(point?.[0]));
      fingerprint = append(fingerprint, number(point?.[1]));
    }
  }
  return fingerprint;
};

export const semanticOverlayFingerprint = (elements, appState) =>
  fingerprintRelevantElements(semanticOverlayElements(elements), appState);

export const semanticOverlaySnapshot = (elements, appState) => {
  const relevantElements = semanticOverlayElements(elements);
  return {
    elements: relevantElements,
    fingerprint: fingerprintRelevantElements(relevantElements, appState),
  };
};
