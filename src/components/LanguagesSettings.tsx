// Settings → Languages. Lists every built-in LSP manifest and lets the user
// install or uninstall the binary. Owns its own IPC state — the parent
// `SettingsModal` doesn't touch it because LSP install state lives in the
// SQLite `lsp_installations` table, not in `ConfigView`.

import { useCallback, useEffect, useRef, useState } from "react";
import { Button, toast } from "@heroui/react";
import {
  listenSessionEvents,
  lspInstall,
  lspListManifests,
  lspUninstall,
} from "../lib/ipc";
import type { InstallStage, LspManifestView } from "../lib/types";

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
            `Installed ${serverId}${kind.version ? ` (${kind.version})` : ""}`,
          );
        } else {
          toast.danger(`Install failed: ${kind.error ?? "unknown error"}`);
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
      toast.danger(`Install failed: ${e}`);
    }
  }

  async function handleUninstall(server: LspManifestView) {
    const id = server.manifest.id;
    try {
      await lspUninstall(id);
      toast.success(`Uninstalled ${id}`);
      await refresh();
    } catch (e) {
      toast.danger(`Uninstall failed: ${e}`);
    }
  }

  if (error) {
    return (
      <div className="languages-settings">
        <p className="settings-section-blurb">Could not load LSP list: {error}</p>
      </div>
    );
  }

  if (!manifests) {
    return (
      <div className="languages-settings">
        <div className="settings-loading">Loading…</div>
      </div>
    );
  }

  return (
    <div className="languages-settings">
      <p className="settings-section-blurb">
        Language Servers add go-to-definition and semantic highlighting to the
        editor. Install only the ones for languages you actually edit — each
        download is several megabytes.
      </p>
      <div className="lsp-list">
        {manifests.map((server) => (
          <LspCard
            key={server.manifest.id}
            server={server}
            progress={progress[server.manifest.id]}
            isPending={pending.has(server.manifest.id)}
            onInstall={() => handleInstall(server)}
            onUninstall={() => handleUninstall(server)}
          />
        ))}
      </div>
    </div>
  );
}

interface LspCardProps {
  server: LspManifestView;
  progress: InstallProgressState | undefined;
  isPending: boolean;
  onInstall: () => void;
  onUninstall: () => void;
}

function LspCard({
  server,
  progress,
  isPending,
  onInstall,
  onUninstall,
}: LspCardProps) {
  const { manifest, installation, platform_supported, requirement_message } =
    server;
  const installing = isPending || progress !== undefined;
  const installed = installation !== null;
  const canInstall = platform_supported && !requirement_message && !installing;

  return (
    <div className="lsp-card">
      <div className="lsp-card-head">
        <div className="lsp-card-title">
          <span className="lsp-card-name">{manifest.display_name}</span>
          <span className="lsp-card-id">{manifest.id}</span>
        </div>
        <LspStatusBadge
          installed={installed}
          installing={installing}
          version={installation?.version}
        />
      </div>
      <p className="lsp-card-description">{manifest.description}</p>
      <div className="lsp-card-meta">
        <span className="lsp-card-meta-label">Files:</span>
        {manifest.file_extensions.map((ext) => (
          <code key={ext} className="lsp-card-ext">
            {ext}
          </code>
        ))}
      </div>
      {!platform_supported && (
        <div className="lsp-card-warning">Unsupported on this platform.</div>
      )}
      {requirement_message && !installed && (
        <div className="lsp-card-warning">{requirement_message}</div>
      )}
      {progress && (
        <div className="lsp-card-progress">
          <div className="lsp-card-progress-bar">
            <div
              className="lsp-card-progress-fill"
              style={{
                width:
                  progress.percent !== null ? `${progress.percent}%` : "100%",
                // Indeterminate (`percent === null`) shows a slow pulse via
                // the `.indeterminate` modifier so users know we're not stuck.
                opacity: progress.percent === null ? 0.5 : 1,
              }}
            />
          </div>
          <div className="lsp-card-progress-label">{progress.message}</div>
        </div>
      )}
      <div className="lsp-card-actions">
        {manifest.homepage && (
          <a
            className="lsp-card-link"
            href={manifest.homepage}
            target="_blank"
            rel="noreferrer noopener"
          >
            Learn more
          </a>
        )}
        <div className="flex-1" />
        {installed ? (
          <Button
            variant="ghost"
            onPress={onUninstall}
            isDisabled={installing}
          >
            Uninstall
          </Button>
        ) : (
          <Button
            variant="primary"
            onPress={onInstall}
            isDisabled={!canInstall}
          >
            {installing ? "Installing…" : "Install"}
          </Button>
        )}
      </div>
    </div>
  );
}

function LspStatusBadge({
  installed,
  installing,
  version,
}: {
  installed: boolean;
  installing: boolean;
  version: string | undefined;
}) {
  if (installing) {
    return <span className="lsp-card-badge installing">Installing…</span>;
  }
  if (installed) {
    return (
      <span className="lsp-card-badge installed" title={version ?? undefined}>
        Installed{version ? ` · ${version}` : ""}
      </span>
    );
  }
  return <span className="lsp-card-badge">Not installed</span>;
}
