// Manual update probe inside Settings → Updates. The background check on
// startup is owned by `UpdateNotice`; this button covers the "I think
// there's a new version, let me look right now" case and surfaces errors
// (offline, malformed feed) that the silent path swallows.

import { useState } from "react";
import { Button, toast } from "@heroui/react";
import { getVersion } from "@tauri-apps/api/app";
import { useEffect } from "react";
import { checkForUpdate } from "../lib/updater";

export function UpdatesSettings() {
  const [current, setCurrent] = useState<string>("…");
  const [checking, setChecking] = useState(false);

  useEffect(() => {
    let cancelled = false;
    getVersion()
      .then((v) => !cancelled && setCurrent(v))
      .catch(() => !cancelled && setCurrent("unknown"));
    return () => {
      cancelled = true;
    };
  }, []);

  async function onCheck() {
    if (checking) return;
    setChecking(true);
    try {
      const update = await checkForUpdate();
      if (!update) {
        toast.success("You're on the latest version.");
        return;
      }
      // Reuse the same toast UI rendered by `UpdateNotice` instead of
      // duplicating the install flow inside Settings.
      window.dispatchEvent(
        new CustomEvent("ycode:update-available", { detail: update }),
      );
      toast.success(`Update available: v${update.version}`);
    } catch (err) {
      toast.danger(`Check failed: ${err}`);
    } finally {
      setChecking(false);
    }
  }

  return (
    <div className="appearance-settings">
      <p className="settings-section-blurb">
        YCode checks for updates a few seconds after launch. Click below to
        re-check on demand.
      </p>
      <div className="field">
        <label className="field-label">Current version</label>
        <div className="readonly-field">v{current}</div>
      </div>
      <div className="field">
        <Button variant="primary" onPress={onCheck} isDisabled={checking}>
          {checking ? "Checking…" : "Check for updates"}
        </Button>
      </div>
    </div>
  );
}
