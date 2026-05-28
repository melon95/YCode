// Thin wrapper around `@tauri-apps/plugin-updater`. Keeps every call point
// in the UI from having to know about the plugin's slightly chatty API
// (Update | null returns, optional progress callbacks).
//
// All errors are bubbled up — callers decide whether to swallow them
// (background startup check) or surface them (Settings "Check now" button).

import { check, type Update } from "@tauri-apps/plugin-updater";

/// Hits the configured endpoint and returns the pending update, or `null`
/// when the user is already on the latest version.
export async function checkForUpdate(): Promise<Update | null> {
  return await check();
}

/// Drives the actual download + install. Tauri restarts the app once the
/// install step completes, so anything queued after `downloadAndInstall`
/// in the same tick won't run.
export async function installUpdate(
  update: Update,
  onProgress?: (downloaded: number, total: number | null) => void,
): Promise<void> {
  let downloaded = 0;
  let total: number | null = null;
  await update.downloadAndInstall((event) => {
    switch (event.event) {
      case "Started":
        total = event.data.contentLength ?? null;
        onProgress?.(0, total);
        break;
      case "Progress":
        downloaded += event.data.chunkLength;
        onProgress?.(downloaded, total);
        break;
      case "Finished":
        onProgress?.(total ?? downloaded, total);
        break;
    }
  });
}
