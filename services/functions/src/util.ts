export function buildRefreshUrl(base: string): string {
  if (!/^https:\/\//.test(base)) throw new Error("API base URL must be https");
  return base.replace(/\/+$/, "") + "/api/v1/internal/jobs/refresh";
}
