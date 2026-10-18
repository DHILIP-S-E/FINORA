import * as functionsV1 from "firebase-functions/v1";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { defineString } from "firebase-functions/params";
import { initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import { GoogleAuth } from "google-auth-library";
import { buildRefreshUrl } from "./util";

initializeApp();

const API_BASE_URL = defineString("CASCADE_API_BASE_URL"); // Cloud Run service URL, set at deploy time

/**
 * Account-deletion workflow: when a Firebase Auth user is deleted (by the API or by the user
 * via the console/SDK) remove everything we hold for them. Idempotent and safe to retry.
 * Data is removed immediately; backups/log retention are documented in docs/security.md.
 */
export const onAuthUserDeleted = functionsV1.auth.user().onDelete(async (user) => {
  const uid = user.uid;
  await getFirestore().recursiveDelete(getFirestore().doc(`users/${uid}`));
  await getStorage().bucket().deleteFiles({ prefix: `users/${uid}/`, force: true });
  functionsV1.logger.info("deleted user data", { uidHash: uid.slice(0, 4) + "…" }); // never log full ids/values
});

/**
 * Periodic forecast refresh. Calls the API's internal job, which re-runs the deterministic
 * engine for every user and creates deduplicated alerts. No Gemini calls => bounded cost.
 * Auth: OIDC identity token minted for the Cloud Run audience (the function's service account
 * must hold roles/run.invoker on the API service).
 */
export const scheduledRefresh = onSchedule({ schedule: "every 6 hours", timeoutSeconds: 300, retryCount: 1 }, async () => {
  const base = API_BASE_URL.value();
  const client = await new GoogleAuth().getIdTokenClient(base);
  const res = await client.request({ url: buildRefreshUrl(base), method: "POST" });
  functionsV1.logger.info("refresh job finished", { status: res.status });
});
