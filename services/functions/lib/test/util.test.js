"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const node_test_1 = require("node:test");
const node_assert_1 = __importDefault(require("node:assert"));
const util_1 = require("../util");
(0, node_test_1.test)("builds the job URL and strips trailing slashes", () => {
    node_assert_1.default.strictEqual((0, util_1.buildRefreshUrl)("https://api.example.run.app/"), "https://api.example.run.app/api/v1/internal/jobs/refresh");
});
(0, node_test_1.test)("rejects non-https base URLs", () => {
    node_assert_1.default.throws(() => (0, util_1.buildRefreshUrl)("http://localhost:8000"));
});
