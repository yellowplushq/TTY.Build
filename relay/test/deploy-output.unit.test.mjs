import assert from "node:assert/strict";
import test from "node:test";

import {
  extractCurrentVersionId,
  isWorkerVersionId,
} from "../../scripts/parse-wrangler-version.mjs";

const first = "2ebc8d9b-a076-4f02-b27b-7708aa86326d";
const current = "dcb121aa-73f3-4235-928f-396714094e48";

test("extracts the complete current Worker version from Wrangler output", () => {
  const output = [
    "Uploaded tty-build-relay",
    `Current Version ID: ${current}`,
  ].join("\n");
  assert.equal(extractCurrentVersionId(output), current);
  assert.equal(isWorkerVersionId(current), true);
});

test("strips terminal escapes and selects the last deployment version", () => {
  const output = [
    `Current Version ID: ${first}`,
    `\u001b[32mCurrent Version ID:\u001b[0m \u001b[1m${current}\u001b[0m`,
  ].join("\n");
  assert.equal(extractCurrentVersionId(output), current);
});

test("rejects a missing or abbreviated version ID", () => {
  assert.equal(extractCurrentVersionId("Current Version ID: dcb121aa"), null);
  assert.equal(extractCurrentVersionId("deployment finished"), null);
  assert.equal(isWorkerVersionId("dcb121aa"), false);
});
