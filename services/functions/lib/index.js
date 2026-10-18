"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.scheduledRefresh = exports.onAuthUserDeleted = void 0;
const functionsV1 = __importStar(require("firebase-functions/v1"));
const scheduler_1 = require("firebase-functions/v2/scheduler");
const params_1 = require("firebase-functions/params");
const app_1 = require("firebase-admin/app");
const firestore_1 = require("firebase-admin/firestore");
const storage_1 = require("firebase-admin/storage");
const google_auth_library_1 = require("google-auth-library");
const util_1 = require("./util");
(0, app_1.initializeApp)();
const API_BASE_URL = (0, params_1.defineString)("CASCADE_API_BASE_URL"); // Cloud Run service URL, set at deploy time
/**
 * Account-deletion workflow: when a Firebase Auth user is deleted (by the API or by the user
 * via the console/SDK) remove everything we hold for them. Idempotent and safe to retry.
 * Data is removed immediately; backups/log retention are documented in docs/security.md.
 */
exports.onAuthUserDeleted = functionsV1.auth.user().onDelete(async (user) => {
    const uid = user.uid;
    await (0, firestore_1.getFirestore)().recursiveDelete((0, firestore_1.getFirestore)().doc(`users/${uid}`));
    await (0, storage_1.getStorage)().bucket().deleteFiles({ prefix: `users/${uid}/`, force: true });
    functionsV1.logger.info("deleted user data", { uidHash: uid.slice(0, 4) + "…" }); // never log full ids/values
});
/**
 * Periodic forecast refresh. Calls the API's internal job, which re-runs the deterministic
 * engine for every user and creates deduplicated alerts. No Gemini calls => bounded cost.
 * Auth: OIDC identity token minted for the Cloud Run audience (the function's service account
 * must hold roles/run.invoker on the API service).
 */
exports.scheduledRefresh = (0, scheduler_1.onSchedule)({ schedule: "every 6 hours", timeoutSeconds: 300, retryCount: 1 }, async () => {
    const base = API_BASE_URL.value();
    const client = await new google_auth_library_1.GoogleAuth().getIdTokenClient(base);
    const res = await client.request({ url: (0, util_1.buildRefreshUrl)(base), method: "POST" });
    functionsV1.logger.info("refresh job finished", { status: res.status });
});
