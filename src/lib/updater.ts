// Thin wrapper around `@tauri-apps/plugin-updater`. Keeps every call point
// in the UI from having to know about the plugin's slightly chatty API
// (Update | null returns, optional progress callbacks).
//
// All errors are bubbled up — callers decide whether to swallow them
// (background startup check) or surface them (Settings "Check now" button).

import { check, type Update } from "@tauri-apps/plugin-updater";
import { relaunch } from "@tauri-apps/plugin-process";
import { getVersion } from "@tauri-apps/api/app";
import { arch, platform } from "@tauri-apps/plugin-os";
import { getInstanceId } from "./instanceId";

/// Builds the anonymous active-user headers that ride along on the update
/// check. The proxy endpoint (see `analytics/`) records one ping per
/// instance per day from these; nothing here is identifying. Best-effort —
/// a failure to read any field must never block the update check.
async function telemetryHeaders(): Promise<Record<string, string>> {
  const headers: Record<string, string> = {
    "x-ycode-instance": getInstanceId(),
  };
  try {
    headers["x-ycode-version"] = await getVersion();
  } catch {
    /* ignore — version is best-effort */
  }
  try {
    headers["x-ycode-os"] = platform();
  } catch {
    /* ignore */
  }
  try {
    headers["x-ycode-arch"] = arch();
  } catch {
    /* ignore */
  }
  return headers;
}

/// Hits the configured endpoint and returns the pending update, or `null`
/// when the user is already on the latest version.
export async function checkForUpdate(): Promise<Update | null> {
  let headers: Record<string, string> = {};
  try {
    headers = await telemetryHeaders();
  } catch {
    /* ignore — telemetry is never allowed to break the update check */
  }
  return await check({ headers });
}

export type InstallPhase = "downloading" | "installing" | "done";

/// Drives the actual download + install, then relaunches. The plugin's
/// `Finished` event fires once the download is complete; the install
/// (bundle swap, signature verify) runs as the rest of `downloadAndInstall`
/// resolves. On macOS the runtime never auto-restarts — without an
/// explicit `relaunch()` the UI would stall at 100% forever, which is
/// what users were hitting on v0.1.3.
export async function installUpdate(
  update: Update,
  onProgress?: (phase: InstallPhase, downloaded: number, total: number | null) => void,
): Promise<void> {
  let downloaded = 0;
  let total: number | null = null;
  await update.downloadAndInstall((event) => {
    switch (event.event) {
      case "Started":
        total = event.data.contentLength ?? null;
        onProgress?.("downloading", 0, total);
        break;
      case "Progress":
        downloaded += event.data.chunkLength;
        onProgress?.("downloading", downloaded, total);
        break;
      case "Finished":
        onProgress?.("installing", total ?? downloaded, total);
        break;
    }
  });
  onProgress?.("done", total ?? downloaded, total);
  await relaunch();
}
