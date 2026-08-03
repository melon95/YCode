// Settings → Command Line: install the `ycode` shell command.
//
// Like the agent-hook installers in NotificationsSettings, this mutates state
// outside the staged ConfigView (a symlink on Unix, a `.cmd` shim plus a user
// PATH entry on Windows), so the buttons take effect on click rather than on
// "Save".

import { useCallback, useEffect, useState } from "react";
import { Button, toast } from "@heroui/react";
import { platform } from "@tauri-apps/plugin-os";
import { cliInstall, cliStatus, cliUninstall, type CliInstallStatus } from "../lib/ipc";

/// Where the command lands, which differs enough per platform to be worth
/// stating — the user may want to inspect or remove it by hand.
function installHint(): string {
  let os: string;
  try {
    os = platform();
  } catch {
    // Outside Tauri (vitest/jsdom) the plugin throws.
    os = "macos";
  }
  if (os === "windows") {
    return "Writes ycode.cmd into %LOCALAPPDATA%\\YCode\\bin and adds that folder to your user PATH. No administrator rights needed; open a new terminal afterwards.";
  }
  return "Creates a symlink at /usr/local/bin/ycode. You're asked for your password only if that folder isn't writable by you.";
}

export function CommandLineSettings() {
  const [status, setStatus] = useState<CliInstallStatus | null>(null);
  const [busy, setBusy] = useState(false);

  const refresh = useCallback(
    () =>
      cliStatus()
        .then(setStatus)
        .catch((err) => toast.danger(`Command line status: ${err}`)),
    [],
  );

  useEffect(() => {
    void refresh();
  }, [refresh]);

  async function onInstall() {
    setBusy(true);
    try {
      const next = await cliInstall();
      setStatus(next);
      // `cli_install` reports the resulting state rather than throwing on a
      // partial outcome, so a non-`installed` result here is a success return
      // with a failure meaning — announcing "it's on your PATH" while
      // rendering a Repair button underneath would just be a lie.
      if (next.kind === "installed") {
        toast.success("`ycode` is now on your PATH — try it in a new terminal.");
      } else {
        toast.warning("Install did not complete — see the status below.");
      }
    } catch (err) {
      toast.danger(`Install failed: ${err}`);
      // The failure may itself have changed what's on disk (a partial
      // elevated run), so re-read rather than trusting the stale value.
      // Awaited so it can't land after a later install and overwrite it.
      await refresh();
    } finally {
      setBusy(false);
    }
  }

  async function onUninstall() {
    setBusy(true);
    try {
      setStatus(await cliUninstall());
      toast.success("`ycode` command removed");
    } catch (err) {
      toast.danger(`Uninstall failed: ${err}`);
      await refresh();
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="appearance-settings">
      <p className="settings-section-blurb">
        Install the <code>ycode</code> command so you can open a folder from
        any terminal — <code>ycode .</code> opens the current directory,{" "}
        <code>ycode src/main.rs</code> opens that file's repository and focuses
        the file. YCode launches automatically when it isn't already running.
      </p>

      <div className="field">
        <label className="field-label">
          Shell command
          {status?.kind === "installed" && (
            <span style={{ marginLeft: 8, color: "var(--muted)", fontSize: 11 }}>
              installed
            </span>
          )}
        </label>

        {status === null ? (
          <div className="field-hint">Checking…</div>
        ) : status.kind === "conflict" ? (
          <>
            {/* The path is occupied by something we didn't create, so there is
                no safe action to offer — but the user needs a way to re-read
                the state after clearing it by hand, and mount is otherwise the
                only trigger. */}
            <Button size="sm" variant="ghost" onPress={() => void refresh()}>
              Re-check
            </Button>
            <div className="field-hint">
              <code>{status.path}</code> — {status.detail}. YCode won't
              overwrite it; remove it yourself, then re-check.
            </div>
          </>
        ) : status.kind === "installed" ? (
          <>
            <Button size="sm" variant="ghost" onPress={onUninstall} isDisabled={busy}>
              {busy ? "Removing…" : "Uninstall `ycode` command"}
            </Button>
            <div className="field-hint">
              <code>{status.path}</code> → <code>{status.target}</code>
            </div>
          </>
        ) : status.kind === "stale" ? (
          <>
            <Button size="sm" variant="primary" onPress={onInstall} isDisabled={busy}>
              {busy ? "Repairing…" : "Repair `ycode` command"}
            </Button>
            <div className="field-hint">
              <code>{status.path}</code> points at <code>{status.target}</code>,
              which is no longer this build. Repair to point it back here.
            </div>
          </>
        ) : (
          <>
            <Button size="sm" variant="primary" onPress={onInstall} isDisabled={busy}>
              {busy ? "Installing…" : "Install `ycode` command in PATH"}
            </Button>
            <div className="field-hint">{installHint()}</div>
          </>
        )}
      </div>
    </div>
  );
}
