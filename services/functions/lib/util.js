"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.buildRefreshUrl = buildRefreshUrl;
function buildRefreshUrl(base) {
    if (!/^https:\/\//.test(base))
        throw new Error("API base URL must be https");
    return base.replace(/\/+$/, "") + "/api/v1/internal/jobs/refresh";
}
