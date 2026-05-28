// Update-available toast. Renders as a small floating card in the bottom
// corner — non-modal so the user can keep working until they decide.
//
// Mount tree:
//   <App>
//     <UpdateNotice />   ← owns the "available?" check + the prompt UI
//   </App>
//
// Failure mode: a failed check (offline, GitHub down, malformed
// latest.json) is intentionally silent at startup. The Settings "Check
// for updates" button surfaces errors via toast.

import { useEffect, useState } from "react";
import { Button, toast } from "@heroui/react";
import type { Update } from "@tauri-apps/plugin-updater";
import { checkForUpdate, installUpdate } from "../lib/updater";

/// Wait this long after mount before hitting the network. Avoids
/// competing with the initial workspace fetch + window-state restore.
const STARTUP_DELAY_MS = 5_000;

export function UpdateNotice() {
  const [update, setUpdate] = useState<Update | null>(null);
  const [installing, setInstalling] = useState(false);
  const [progress, setProgress] = useState<{ done: number; total: number | null } | null>(null);
  const [dismissed, setDismissed] = useState(false);

  // Background check on mount. Silent failure — we don't want a flaky
  // network to nag the user with an error on every launch.
  useEffect(() => {
    let cancelled = false;
    const t = setTimeout(() => {
      checkForUpdate()
        .then((u) => {
          if (cancelled) return;
          if (u) setUpdate(u);
        })
        .catch(() => {
          /* silent at startup; user can retry via Settings */
        });
    }, STARTUP_DELAY_MS);
    // Lets `SettingsModal` (or anything else) push a manually-checked
    // update into this toast without duplicating the install machinery.
    function onManual(event: Event) {
      const detail = (event as CustomEvent<Update>).detail;
      if (!detail || cancelled) return;
      setDismissed(false);
      setUpdate(detail);
    }
    window.addEventListener("ycode:update-available", onManual);
    return () => {
      cancelled = true;
      clearTimeout(t);
      window.removeEventListener("ycode:update-available", onManual);
    };
  }, []);

  if (!update || dismissed) return null;

  async function onInstall() {
    if (installing || !update) return;
    setInstalling(true);
    setProgress({ done: 0, total: null });
    try {
      await installUpdate(update, (done, total) => {
        setProgress({ done, total });
      });
      // Tauri restarts automatically after install. If we get here it
      // means restart hasn't fired yet — leave the UI in "Installed"
      // state so the user knows it's finishing.
    } catch (err) {
      setInstalling(false);
      setProgress(null);
      toast.danger(`Update failed: ${err}`);
    }
  }

  return (
    <div className="update-notice" role="status">
      <div className="update-notice-title">
        Update available — v{update.version}
      </div>
      {update.body && (
        <div className="update-notice-body" title={update.body}>
          {update.body.split("\n").slice(0, 3).join("\n")}
        </div>
      )}
      {installing ? (
        <div className="update-notice-progress">
          {progress?.total
            ? `Downloading ${Math.round((progress.done / progress.total) * 100)}%…`
            : "Preparing…"}
        </div>
      ) : (
        <div className="update-notice-actions">
          <Button variant="ghost" size="sm" onPress={() => setDismissed(true)}>
            Later
          </Button>
          <Button variant="primary" size="sm" onPress={onInstall}>
            Install &amp; restart
          </Button>
        </div>
      )}
    </div>
  );
}
