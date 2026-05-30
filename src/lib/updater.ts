// Thin wrapper around `@tauri-apps/plugin-updater`. Keeps every call point
// in the UI from having to know about the plugin's slightly chatty API
// (Update | null returns, optional progress callbacks).
//
// All errors are bubbled up — callers decide whether to swallow them
// (background startup check) or surface them (Settings "Check now" button).

import { check, type Update } from "@tauri-apps/plugin-updater";
import { relaunch } from "@tauri-apps/plugin-process";

/// Hits the configured endpoint and returns the pending update, or `null`
/// when the user is already on the latest version.
export async function checkForUpdate(): Promise<Update | null> {
  return await check();
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
