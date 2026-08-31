// Settings → 编辑器与语言。Lists every built-in LSP manifest and lets the
// user install or uninstall the binary. Owns its own IPC state — the parent
// `SettingsModal` doesn't touch it because LSP install state lives in the
// SQLite `lsp_installations` table, not in `ConfigView`.

import { useCallback, useEffect, useRef, useState } from "react";
import { toast } from "@heroui/react";
import {
  listenSessionEvents,
  lspInstall,
  lspListManifests,
  lspUninstall,
} from "../lib/ipc";
import type { InstallStage, LspManifestView } from "../lib/types";
import {
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
            `已安装 ${serverId}${kind.version ? ` (${kind.version})` : ""}`,
          );
        } else {
          toast.danger(`安装失败:${kind.error ?? "未知错误"}`);
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
      toast.danger(`安装失败:${e}`);
    }
  }

  async function handleUninstall(server: LspManifestView) {
    const id = server.manifest.id;
    try {
      await lspUninstall(id);
      toast.success(`已卸载 ${id}`);
      await refresh();
    } catch (e) {
      toast.danger(`卸载失败:${e}`);
    }
  }

  if (error) {
    return (
      <div className="settings-section">
        <h2>编辑器与语言</h2>
        <p className="settings-lede">读取语言服务列表失败:{error}</p>
      </div>
    );
  }

  const installedCount =
    manifests?.filter((m) => m.installation !== null).length ?? 0;

  return (
    <div className="settings-section">
      <h2>编辑器与语言</h2>
      <p className="settings-lede">
        内置编辑器与语言服务。语言服务给编辑器带来跳转定义和语义高亮 ——
        只装你真正会编辑的语言,每个都有几 MB 到几十 MB。
      </p>

      <SettingGroupLabel>编辑器</SettingGroupLabel>
      <SettingCard>
        <SettingRow
          name="字体 / 字号"
          desc="字号可在「外观」页与界面、终端一起调整"
          pendingReason="编辑器字体独立配置未实现,当前跟随外观设置"
        >
          <SettingChip>见外观</SettingChip>
        </SettingRow>
        <SettingRow
          name="缩进"
          desc="跟随打开文件的既有缩进"
          pendingReason="尚未做成可配置项 —— CodeMirror 目前按文件内容推断"
        >
          <SettingChip>自动识别</SettingChip>
        </SettingRow>
        <SettingRow
          name="显示缩进参考线"
          desc="在嵌套层级间画竖直参考线"
          pendingReason="CodeMirror 缩进参考线未接入配置"
        >
          <SettingToggle label="显示缩进参考线" checked={false} disabled />
        </SettingRow>
        <SettingRow
          name="保存时格式化"
          desc="调用项目自带的 formatter"
          pendingReason="需要接入项目的 formatter 配置,尚未实现"
        >
          <SettingToggle label="保存时格式化" checked={false} disabled />
        </SettingRow>
      </SettingCard>

      <SettingGroupLabel>
        语言服务{manifests ? ` · 已安装 ${installedCount}` : ""}
      </SettingGroupLabel>
      <SettingCard>
        {!manifests ? (
          <SettingRow name="读取中…" />
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
    </div>
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
  const { manifest, installation, platform_supported, requirement_message } =
    server;
  const installing = isPending || progress !== undefined;
  const installed = installation !== null;
  const canInstall = platform_supported && !requirement_message && !installing;

  // Only blockers and progress get a description. The manifest's own blurb
  // is English prose several lines long — it pushed every other row out of
  // rhythm to say what the server id already says.
  const desc = !platform_supported
    ? "当前平台不支持"
    : requirement_message && !installed
      ? requirement_message
      : progress
        ? progress.message
        : undefined;

  return (
    <SettingRow
      name={manifest.display_name}
      desc={desc}
      icon={<span className="lsp-letter">{letterFor(manifest.display_name)}</span>}
    >
      <SettingValue align="end">{manifest.id}</SettingValue>
      {installing ? (
        <SettingChip tone="warn">
          {progress?.percent != null ? `${progress.percent}%` : "安装中…"}
        </SettingChip>
      ) : installed ? (
        <SettingChip tone="on" title={installation?.version ?? undefined}>
          {installation?.version ? `v${installation.version}` : "已安装"}
        </SettingChip>
      ) : (
        <SettingChip>未安装</SettingChip>
      )}
      {installed ? (
        <SettingAction
          label={`卸载 ${manifest.display_name}`}
          tone="danger"
          disabled={installing}
          onClick={onUninstall}
        >
          <TrashIcon />
        </SettingAction>
      ) : (
        <SettingAction
          label={`安装 ${manifest.display_name}`}
          title={
            !platform_supported
              ? "当前平台不支持"
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
