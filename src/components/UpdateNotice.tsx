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
import { toast } from "../lib/toast";
import type { Update } from "@tauri-apps/plugin-updater";
import { checkForUpdate, installUpdate, type InstallPhase } from "../lib/updater";

/// Wait this long after mount before hitting the network. Avoids
/// competing with the initial workspace fetch + window-state restore.
const STARTUP_DELAY_MS = 5_000;

function progressLabel(
  progress: { phase: InstallPhase; done: number; total: number | null } | null,
): string {
  if (!progress) return "Preparing…";
  if (progress.phase === "installing") return "Installing…";
  if (progress.phase === "done") return "Restarting…";
  return progress.total
    ? `Downloading ${Math.round((progress.done / progress.total) * 100)}%…`
    : "Preparing…";
}

export function UpdateNotice() {
  const [update, setUpdate] = useState<Update | null>(null);
  const [installing, setInstalling] = useState(false);
  const [progress, setProgress] = useState<{
    phase: InstallPhase;
    done: number;
    total: number | null;
  } | null>(null);
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
    setProgress({ phase: "downloading", done: 0, total: null });
    try {
      await installUpdate(update, (phase, done, total) => {
        setProgress({ phase, done, total });
      });
      // `installUpdate` calls `relaunch()` itself; anything below is
      // unreachable in practice — the process is replaced before this
      // line runs. Kept as a defensive no-op for environments where
      // relaunch silently fails.
    } catch (err) {
      setInstalling(false);
      setProgress(null);
      toast.danger(`Update failed: ${err}`);
    }
  }

  return (
    <div
      className="fixed right-4 bottom-4 z-900 w-80 py-3 px-3.5 bg-panel
        border border-rule-strong rounded-md
        shadow-[0_12px_32px_rgba(var(--shadow-rgb),0.35)]
        flex flex-col gap-2"
      role="status"
    >
      <div className="font-semibold text-[13px]">
        Update available — v{update.version}
      </div>
      {update.body && (
        <div
          className="text-muted text-xs/[1.4] whitespace-pre-line max-h-[60px] overflow-hidden"
          title={update.body}
        >
          {update.body.split("\n").slice(0, 3).join("\n")}
        </div>
      )}
      {installing ? (
        <div className="text-muted text-xs">{progressLabel(progress)}</div>
      ) : (
        <div className="flex justify-end gap-1.5">
          <button
            type="button"
            className={`${BTN} bg-transparent text-muted border-transparent
              not-disabled:hover:text-text not-disabled:hover:bg-accent-hover-wash`}
            onClick={() => setDismissed(true)}
          >
            Later
          </button>
          <button
            type="button"
            className={`${BTN} bg-accent text-text-on-accent border-accent
              not-disabled:hover:bg-accent-soft not-disabled:hover:border-accent-soft
              disabled:bg-rule disabled:border-rule disabled:text-subtle`}
            onClick={onInstall}
          >
            Install &amp; restart
          </button>
        </div>
      )}
    </div>
  );
}

/// 这两枚按钮是 app 里仅剩的 `.button` 用户,所以整套按钮系统跟着这个
/// 组件走。小号变体(原 `.button--sm`)是唯一在用的尺寸。
const BTN = `min-h-8 py-[5px] px-2.5 rounded-sm border font-ui text-[10px] font-semibold
  tracking-caps-tight uppercase cursor-pointer relative
  transition-[color,background-color,border-color] duration-[var(--duration-fast)] ease-out
  focus-visible:outline-none focus-visible:shadow-[0_0_0_3px_var(--color-accent-edge)]
  disabled:opacity-45 disabled:cursor-not-allowed`.replace(/\s+/g, " ");
