import assert from "node:assert/strict";
import test from "node:test";

import {
  boxKindForExcalType,
  excalTypeForNativeTool,
  nativeToolForExcalType,
} from "../src/tool-mapping.js";

test("Excalidraw shape choices survive the native state round trip", () => {
  for (const [type, kind] of [
    ["rectangle", "generic"],
    ["diamond", "decision"],
    ["ellipse", "ellipse"],
  ]) {
    assert.equal(nativeToolForExcalType(type), "box");
    assert.equal(boxKindForExcalType(type, "service"), kind);
    assert.equal(excalTypeForNativeTool("box", kind), type);
  }
});

test("Excalidraw line and free draw remain distinct tools", () => {
  assert.equal(nativeToolForExcalType("line"), "line");
  assert.equal(nativeToolForExcalType("freedraw"), "pen");
  assert.equal(excalTypeForNativeTool("line"), "line");
  assert.equal(excalTypeForNativeTool("pen"), "freedraw");
});

test("hand, select, arrow, text, and eraser round trip", () => {
  for (const [excal, native] of [
    ["hand", "hand"],
    ["selection", "select"],
    ["arrow", "connector"],
    ["text", "label"],
    ["eraser", "eraser"],
  ]) {
    assert.equal(nativeToolForExcalType(excal), native);
    assert.equal(excalTypeForNativeTool(native), excal);
  }
});
