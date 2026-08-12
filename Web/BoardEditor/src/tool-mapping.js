export const excalTypeForNativeTool = (tool, boxKind = "generic") => {
  if (tool === "box") {
    if (boxKind === "decision") return "diamond";
    if (boxKind === "ellipse") return "ellipse";
    return "rectangle";
  }
  return ({
    hand: "hand",
    select: "selection",
    connector: "arrow",
    label: "text",
    line: "line",
    pen: "freedraw",
    eraser: "eraser",
  })[tool] ?? "selection";
};

export const nativeToolForExcalType = (type) => ({
  hand: "hand",
  selection: "select",
  rectangle: "box",
  diamond: "box",
  ellipse: "box",
  arrow: "connector",
  line: "line",
  freedraw: "pen",
  text: "label",
  eraser: "eraser",
})[type] ?? "select";

export const boxKindForExcalType = (type, fallback) => ({
  rectangle: "generic",
  diamond: "decision",
  ellipse: "ellipse",
})[type] ?? fallback;
