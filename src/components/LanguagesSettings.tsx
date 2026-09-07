// Settings → 编辑器与语言。Lists every built-in LSP manifest and lets the
// user install or uninstall the binary. Owns its own IPC state — the parent
// `SettingsModal` doesn't touch it because LSP install state lives in the
// SQLite `lsp_installations` table, not in `ConfigView`.

import { useCallback, useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { toast } from "../lib/toast";
import {
  listenSessionEvents,
  lspInstall,
  lspListManifests,
  lspUninstall,
} from "../lib/ipc";
import type { InstallStage, LspManifestView } from "../lib/types";
import {
  SettingSection,
  SettingAction,
  SettingCard,
  SettingChip,
  SettingGroupLabel,
  SettingRow,
  SettingToggle,
  SettingValue,
} from "./ui/SettingControls";

interface InstallProgressState {
  stage: InstallStage;
  percent: number | null;
  message: string;
}

export function LanguagesSettings() {
  const { t } = useTranslation();
  const [manifests, setManifests] = useState<LspManifestView[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  // Per-server in-flight install progress. Keyed by manifest id. Cleared on
  // `LspInstallFinished`.
  const [progress, setProgress] = useState<Record<string, InstallProgressState>>(
    {},
  );
  // Servers the user just clicked "Install" on but haven't received the first
  // progress event for yet — keeps the button in the "installing" state during
  // the initial latency window.
  const [pending, setPending] = useState<Set<string>>(new Set());

  const refresh = useCallback(async () => {
    try {
      const list = await lspListManifests();
      setManifests(list);
      setError(null);
    } catch (e) {
      setError(`${e}`);
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  // Stash refresh in a ref so the event listener doesn't rebind on every
  // staged render — the unlisten path runs once when the modal closes.
  const refreshRef = useRef(refresh);
  refreshRef.current = refresh;

  useEffect(() => {
    let unlisten: (() => void) | undefined;
    let cancelled = false;
    listenSessionEvents((event) => {
      const { kind, session_id: serverId } = event;
      if (kind.type === "LspInstallProgress") {
        setProgress((prev) => ({
          ...prev,
          [serverId]: {
            stage: kind.stage,
            percent: kind.percent,
            message: kind.message,
          },
        }));
        setPending((prev) => {
          if (!prev.has(serverId)) return prev;
          const next = new Set(prev);
          next.delete(serverId);
          return next;
        });
      } else if (kind.type === "LspInstallFinished") {
        setProgress((prev) => {
          if (!(serverId in prev)) return prev;
          const next = { ...prev };
          delete next[serverId];
          return next;
        });
        setPending((prev) => {
          if (!prev.has(serverId)) return prev;
          const next = new Set(prev);
          next.delete(serverId);
          return next;
        });
        if (kind.ok) {
          toast.success(
            kind.version
            ? t("settings.languages.installedWithVersion", {
                name: serverId,
                version: kind.version,
              })
            : t("settings.languages.installed", { name: serverId }),
          );
        } else {
          toast.danger(
            t("settings.languages.installFailed", {
              error: kind.error ?? t("settings.languages.unknownError"),
            }),
          );
        }
        void refreshRef.current();
      } else if (kind.type === "LspUninstalled") {
        void refreshRef.current();
      }
    })
      .then((fn) => {
        if (cancelled) fn();
        else unlisten = fn;
      })
      .catch((e) => console.warn("languages settings listen failed", e));
    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, []);

  async function handleInstall(server: LspManifestView) {
    const id = server.manifest.id;
    setPending((prev) => {
      const next = new Set(prev);
      next.add(id);
      return next;
    });
    try {
      await lspInstall(id);
    } catch (e) {
      setPending((prev) => {
        const next = new Set(prev);
        next.delete(id);
        return next;
      });
      toast.danger(t("settings.languages.installFailed", { error: e }));
    }
  }

  async function handleUninstall(server: LspManifestView) {
    const id = server.manifest.id;
    try {
      await lspUninstall(id);
      toast.success(t("settings.languages.uninstalled", { name: id }));
      await refresh();
    } catch (e) {
      toast.danger(t("settings.languages.uninstallFailed", { error: e }));
    }
  }

  if (error) {
    return (
      <SettingSection
        title={t("settings.languages.title")}
        lede={<>{t("settings.languages.loadFailed", { error })}</>}
      >
      </SettingSection>
    );
  }

  const installedCount =
    manifests?.filter((m) => m.installation !== null).length ?? 0;

  return (
    <SettingSection
      title={t("settings.languages.title")}
      lede={
        <>
          {t("settings.languages.lede")}
        </>
      }
    >
      <SettingGroupLabel>{t("settings.languages.editor")}</SettingGroupLabel>
      <SettingCard>
        <SettingRow
          name={t("settings.languages.fontRow")}
          desc={t("settings.languages.fontRowDesc")}
          pendingReason={t("settings.languages.fontRowPending")}
        >
          <SettingChip>{t("settings.languages.seeAppearance")}</SettingChip>
        </SettingRow>
        <SettingRow
          name={t("settings.languages.indent")}
          desc={t("settings.languages.indentDesc")}
          pendingReason={t("settings.languages.indentPending")}
        >
          <SettingChip>{t("settings.languages.autoDetect")}</SettingChip>
        </SettingRow>
        <SettingRow
          name={t("settings.languages.indentGuides")}
          desc={t("settings.languages.indentGuidesDesc")}
          pendingReason={t("settings.languages.indentGuidesPending")}
        >
          <SettingToggle label={t("settings.languages.indentGuides")} checked={false} disabled />
        </SettingRow>
        <SettingRow
          name={t("settings.languages.formatOnSave")}
          desc={t("settings.languages.formatOnSaveDesc")}
          pendingReason={t("settings.languages.formatOnSavePending")}
        >
          <SettingToggle label={t("settings.languages.formatOnSave")} checked={false} disabled />
        </SettingRow>
      </SettingCard>

      <SettingGroupLabel>
        {manifests
          ? t("settings.languages.serversInstalled", { count: installedCount })
          : t("settings.languages.servers")}
      </SettingGroupLabel>
      <SettingCard>
        {!manifests ? (
          <SettingRow name={t("common.loading")} />
        ) : (
          manifests.map((server) => (
            <LspRow
              key={server.manifest.id}
              server={server}
              progress={progress[server.manifest.id]}
              isPending={pending.has(server.manifest.id)}
              onInstall={() => handleInstall(server)}
              onUninstall={() => handleUninstall(server)}
            />
          ))
        )}
      </SettingCard>
    </SettingSection>
  );
}

interface LspRowProps {
  server: LspManifestView;
  progress: InstallProgressState | undefined;
  isPending: boolean;
  onInstall: () => void;
  onUninstall: () => void;
}

function LspRow({
  server,
  progress,
  isPending,
  onInstall,
  onUninstall,
}: LspRowProps) {
  const { t } = useTranslation();
  const { manifest, installation, platform_supported, requirement_message } =
    server;
  const installing = isPending || progress !== undefined;
  const installed = installation !== null;
  const canInstall = platform_supported && !requirement_message && !installing;

  // Only blockers and progress get a description. The manifest's own blurb
  // is English prose several lines long — it pushed every other row out of
  // rhythm to say what the server id already says.
  const desc = !platform_supported
    ? t("settings.languages.unsupportedPlatform")
    : requirement_message && !installed
      ? requirement_message
      : progress
        ? progress.message
        : undefined;

  return (
    <SettingRow
      name={manifest.display_name}
      desc={desc}
      icon={<span className="font-mono text-[9.5px] font-bold tracking-[0.02em]">{letterFor(manifest.display_name)}</span>}
    >
      <SettingValue align="end">{manifest.id}</SettingValue>
      {installing ? (
        <SettingChip tone="warn">
          {progress?.percent != null
                ? t("settings.languages.installingPercent", { percent: progress.percent })
                : t("settings.languages.installing")}
        </SettingChip>
      ) : installed ? (
        <SettingChip tone="on" title={installation?.version ?? undefined}>
          {installation?.version
                ? `v${installation.version}`
                : t("settings.languages.installedShort")}
        </SettingChip>
      ) : (
        <SettingChip>{t("settings.languages.notInstalled")}</SettingChip>
      )}
      {installed ? (
        <SettingAction
          label={t("settings.languages.uninstall", { name: manifest.display_name })}
          tone="danger"
          disabled={installing}
          onClick={onUninstall}
        >
          <TrashIcon />
        </SettingAction>
      ) : (
        <SettingAction
          label={t("settings.languages.install", { name: manifest.display_name })}
          title={
            !platform_supported
              ? t("settings.languages.unsupportedPlatform")
              : (requirement_message ?? undefined)
          }
          disabled={!canInstall}
          onClick={onInstall}
        >
          <DownloadIcon />
        </SettingAction>
      )}
    </SettingRow>
  );
}

/// Two-letter tag for the row icon (TS, RS, PY…). Falls back to one letter
/// for single-word names that don't abbreviate.
function letterFor(name: string): string {
  const compact = name.replace(/[^A-Za-z]/g, "");
  return compact.slice(0, 2).toUpperCase() || name.slice(0, 1);
}

function TrashIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="M3 6h18M8 6V4a1 1 0 0 1 1-1h6a1 1 0 0 1 1 1v2" />
      <path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6" />
      <path d="M10 11v6M14 11v6" />
    </svg>
  );
}
function DownloadIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="M12 3v12" />
      <path d="m7 11 5 5 5-5" />
      <path d="M4 19h16" />
    </svg>
  );
}
