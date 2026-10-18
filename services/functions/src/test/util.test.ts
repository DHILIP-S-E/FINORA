import { test } from "node:test";
import assert from "node:assert";
import { buildRefreshUrl } from "../util";

test("builds the job URL and strips trailing slashes", () => {
  assert.strictEqual(buildRefreshUrl("https://api.example.run.app/"), "https://api.example.run.app/api/v1/internal/jobs/refresh");
});

test("rejects non-https base URLs", () => {
  assert.throws(() => buildRefreshUrl("http://localhost:8000"));
});
