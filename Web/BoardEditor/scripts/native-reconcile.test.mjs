import assert from "node:assert/strict";
import test from "node:test";

import { reconcileNativeElementVersions } from "../src/native-reconcile.js";

test("native reconciliation advances existing Excalidraw versions", () => {
  const reconciled = reconcileNativeElementVersions(
    [{ id: "box-1", x: -140, version: 1, versionNonce: 10, updated: 1 }],
    [{ id: "box-1", x: 80, version: 7, versionNonce: 20, updated: 15 }],
    (id, version) => `${id}:${version}`.length,
  );

  assert.deepEqual(reconciled, [{
    id: "box-1",
    x: -140,
    version: 8,
    versionNonce: 7,
    updated: 16,
  }]);
});

test("native reconciliation leaves a new canonical element untouched", () => {
  const canonical = [{ id: "box-2", x: 40, version: 1 }];
  assert.deepEqual(
    reconcileNativeElementVersions(canonical, [], () => 99),
    canonical,
  );
});
