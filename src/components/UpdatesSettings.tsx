// Manual update probe inside Settings → Updates. The background check on
// startup is owned by `UpdateNotice`; this button covers the "I think
// there's a new version, let me look right now" case and surfaces errors
// (offline, malformed feed) that the silent path swallows.

import { useState } from "react";
import { Button, toast } from "@heroui/react";
import { getVersion } from "@tauri-apps/api/app";
import { useEffect } from "react";
import { checkForUpdate } from "../lib/updater";

export function UpdatesSettings({ onClose }: { onClose: () => void }) {
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
      // Reuse the same notice card rendered by `UpdateNotice` instead of
      // duplicating the install flow inside Settings. No extra toast here —
      // the card already announces the version and owns the install action.
      window.dispatchEvent(
        new CustomEvent("ycode:update-available", { detail: update }),
      );
      // Close Settings before the notice card appears. `UpdateNotice` renders
      // outside this modal's DOM subtree, so with Settings still open the first
      // click on "Install & restart" is judged an outside-press and merely
      // dismisses the modal — forcing a second click to actually install.
      onClose();
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
