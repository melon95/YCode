// Settings → 集成:how ycode talks to the agents, in one place.
//
// These three blocks used to be scattered — hook installers and MCP
// registration buried inside the notifications page, the `ycode` shell
// command behind a nav entry labelled 「终端」. They belong together: each one
// is ycode reaching into something outside itself (an agent's config dir,
// /usr/local/bin, the OS URL handler), and each takes effect the moment you
// click rather than on Save.
//
// That last point is why none of this lives in the staged `ConfigView`. The
// backend writes the agent's own files; there is nothing for "取消" to roll
// back, so the buttons say what they did via a toast instead.

import { useCallback, useEffect, useMemo, useState } from "react";
import { Trans, useTranslation } from "react-i18next";
import { i18next } from "../lib/i18n";
import { toast } from "../lib/toast";
import { platform } from "@tauri-apps/plugin-os";
import {
  agentHookStatus,
  agentInstallCodexChain,
  agentInstallHook,
  agentUninstallHook,
  cliInstall,
  cliStatus,
  cliUninstall,
  mcpInstall,
  mcpStatus,
  mcpUninstall,
  type AgentPatchStatus,
  type CliInstallStatus,
  type McpStatus,
} from "../lib/ipc";
import { useStore } from "../lib/store";
import { AgentIcon } from "./AgentIcon";
import {
  SettingSection,
  SettingAction,
  SettingCard,
  SettingChip,
  SettingGroupLabel,
  SettingNote,
  SettingRow,
  SettingValue,
} from "./ui/SettingControls";

type HookAgent = "claude" | "codex";

const AGENT_LABEL: Record<HookAgent, string> = {
  claude: "Claude Code",
  codex: "Codex",
};
const AGENT_ICON: Record<HookAgent, string> = {
  claude: "ClaudeCode",
  codex: "Codex",
};
/// Where each agent's patch lands. Shown as its own row because "what did
/// ycode write to my machine" is the first question this page has to answer.
const AGENT_TARGET: Record<HookAgent, string> = {
  claude: "~/.claude/settings.json",
  codex: "~/.codex/config.toml",
};
/// How we edited it. Separate from the path so the path itself stays short
/// enough to render without being ellipsised away.
const AGENT_TARGET_NOTE: Record<HookAgent, string> = {
  claude: "settings.integrations.hookNoteClaude",
  codex: "settings.integrations.hookNoteCodex",
};
/// The events each installed hook actually reports. Hard-coded because they
/// are a property of the patch we write, not something the backend returns.
const AGENT_EVENTS: Record<HookAgent, string[]> = {
  claude: ["Stop"],
  codex: ["notify"],
};

export function IntegrationsSettings() {
  const { t } = useTranslation();
  // Only the agents the user actually configured, and only the two the
  // backend can patch. Listing a fixed claude/codex/gemini trio meant the
  // page advertised integrations for CLIs that weren't installed — and kept
  // showing Codex after someone removed it from the catalogue.
  const agents = useStore((s) => s.agents);
  const hookAgents = useMemo(
    () =>
      agents
        .map((a) => a.introspect)
        .filter((i): i is HookAgent => i === "claude" || i === "codex")
        .filter((i, idx, all) => all.indexOf(i) === idx),
    [agents],
  );

  return (
    <SettingSection
      title={t("settings.integrations.title")}
      lede={
        <>
          <Trans i18nKey="settings.integrations.lede" components={{ 1: <b /> }} />
        </>
      }
    >
      <SettingGroupLabel>{t("settings.integrations.hookGroup")}</SettingGroupLabel>
      <SettingCard>
        {hookAgents.length === 0 ? (
          <SettingRow
            name={t("settings.integrations.noAgents")}
            desc={t("settings.integrations.noAgentsDesc")}
          />
        ) : (
          hookAgents.map((a) => <HookRows key={a} agent={a} />)
        )}
      </SettingCard>
      <SettingNote>
        <Trans
          i18nKey="settings.integrations.hookNote"
          components={{ 1: <b />, 3: <code /> }}
        />
      </SettingNote>

      <SettingGroupLabel>{t("settings.integrations.mcpGroup")}</SettingGroupLabel>
      <SettingCard>
        {hookAgents.map((a) => (
          <McpRow key={a} agent={a} />
        ))}
        <SettingRow name={t("settings.integrations.transport")}>
          <SettingValue align="end">
            ycode-mcp sidecar · Unix domain socket
          </SettingValue>
        </SettingRow>
      </SettingCard>
      <SettingNote>
        <Trans
          i18nKey="settings.integrations.mcpNote"
          components={{ 1: <code />, 3: <code />, 5: <code />, 7: <code /> }}
        />
      </SettingNote>

      <SettingGroupLabel>{t("settings.integrations.systemGroup")}</SettingGroupLabel>
      <SettingCard>
        <CliRow />
        <SettingRow
          name={
            <>
              <Trans
                i18nKey="settings.integrations.deepLink"
                components={{ 1: <code /> }}
              />
            </>
          }
          desc={t("settings.integrations.deepLinkDesc")}
        >
          <SettingChip tone="on" title={t("settings.integrations.deepLinkBy")}>
            {t("settings.integrations.registered")}
          </SettingChip>
        </SettingRow>
      </SettingCard>
    </SettingSection>
  );
}

/* ---------- hooks ---------- */

function HookRows({ agent }: { agent: HookAgent }) {
  const { t } = useTranslation();
  const [status, setStatus] = useState<AgentPatchStatus | null>(null);
  const [busy, setBusy] = useState(false);

  const refresh = useCallback(() => {
    agentHookStatus(agent)
      .then(setStatus)
      .catch((err) =>
        toast.danger(
          t("settings.integrations.hookReadFailed", {
            agent: AGENT_LABEL[agent],
            error: err,
          }),
        ),
      );
  }, [agent]);

  useEffect(refresh, [refresh]);

  async function run(
    action: () => Promise<AgentPatchStatus>,
    success: string,
  ) {
    setBusy(true);
    try {
      const next = await action();
      setStatus(next);
      if (next.agent === "codex" && next.kind === "conflict_user_set") {
        toast.warning(t("settings.integrations.codexHasNotify"));
      } else {
        toast.success(success);
      }
    } catch (err) {
      toast.danger(t("settings.integrations.actionFailed", { error: err }));
      refresh();
    } finally {
      setBusy(false);
    }
  }

  const installed = status?.kind === "installed";
  const conflict =
    status?.agent === "codex" && status.kind === "conflict_user_set";
  const existing = (status?.agent === "codex" && status.existing) || [];

  return (
    <>
      <SettingRow
        name={AGENT_LABEL[agent]}
        icon={<AgentIcon icon={AGENT_ICON[agent]} fallbackChar={AGENT_LABEL[agent]} size={22} />}
        desc={
          conflict ? (
            <>
              <Trans
                i18nKey="settings.integrations.codexConflict"
                values={{ existing: existing.join(" ") }}
                components={{ 1: <code />, 3: <code /> }}
              />
            </>
          ) : undefined
        }
      >
        {status === null ? (
          <SettingChip>{t("common.loading")}</SettingChip>
        ) : (
          <>
            {installed &&
              AGENT_EVENTS[agent].map((e) => (
                <SettingChip key={e} tone="on">
                  {e}
                </SettingChip>
              ))}
            {conflict && <SettingChip tone="warn">{t("settings.integrations.notConnected")}</SettingChip>}
            {!installed && !conflict && <SettingChip>{t("settings.integrations.notConnected")}</SettingChip>}
            {conflict ? (
              <SettingAction
                label={t("settings.integrations.chainAfter")}
                title={t("settings.integrations.chainAfterHint")}
                disabled={busy || existing.length === 0}
                onClick={() =>
                  void run(
                    () => agentInstallCodexChain(existing),
                    t("settings.integrations.hookChained", { agent: AGENT_LABEL[agent] }),
                  )
                }
              >
                <PlusIcon />
              </SettingAction>
            ) : installed ? (
              <SettingAction
                label={t("settings.integrations.removeHook")}
                tone="danger"
                disabled={busy}
                onClick={() =>
                  void run(
                    () => agentUninstallHook(agent),
                    t("settings.integrations.hookRemoved", { agent: AGENT_LABEL[agent] }),
                  )
                }
              >
                <TrashIcon />
              </SettingAction>
            ) : (
              <SettingAction
                label={t("settings.integrations.installHook")}
                disabled={busy}
                onClick={() =>
                  void run(
                    () => agentInstallHook(agent),
                    t("settings.integrations.hookInstalled", { agent: AGENT_LABEL[agent] }),
                  )
                }
              >
                <PlusIcon />
              </SettingAction>
            )}
          </>
        )}
      </SettingRow>
      {installed && (
        <SettingRow
          name={<span className="font-normal text-subtle">{t("settings.integrations.writeLocation")}</span>}
          desc={t(AGENT_TARGET_NOTE[agent])}
        >
          <SettingValue align="end" title={AGENT_TARGET[agent]}>
            {AGENT_TARGET[agent]}
          </SettingValue>
        </SettingRow>
      )}
    </>
  );
}

/* ---------- MCP ---------- */

function McpRow({ agent }: { agent: HookAgent }) {
  const { t } = useTranslation();
  const [status, setStatus] = useState<McpStatus | null>(null);
  const [busy, setBusy] = useState(false);

  const refresh = useCallback(() => {
    mcpStatus(agent)
      .then(setStatus)
      .catch((err) =>
        toast.danger(
          t("settings.integrations.mcpReadFailed", {
            agent: AGENT_LABEL[agent],
            error: err,
          }),
        ),
      );
  }, [agent]);

  useEffect(refresh, [refresh]);

  async function run(action: () => Promise<McpStatus>, success: string) {
    setBusy(true);
    try {
      setStatus(await action());
      toast.success(success);
    } catch (err) {
      toast.danger(t("settings.integrations.actionFailed", { error: err }));
    } finally {
      setBusy(false);
    }
  }

  return (
    <SettingRow
      name={AGENT_LABEL[agent]}
      desc={t("settings.integrations.todoMcpDesc")}
      icon={<AgentIcon icon={AGENT_ICON[agent]} fallbackChar={AGENT_LABEL[agent]} size={22} />}
    >
      {status === null ? (
        <SettingChip>{t("common.loading")}</SettingChip>
      ) : status === "installed" ? (
        <>
          <SettingChip tone="on">{t("settings.integrations.registered")}</SettingChip>
          <SettingAction
            label={t("settings.integrations.unregister")}
            tone="danger"
            disabled={busy}
            onClick={() =>
              void run(
                () => mcpUninstall(agent),
                t("settings.integrations.mcpRemoved", { agent: AGENT_LABEL[agent] }),
              )
            }
          >
            <TrashIcon />
          </SettingAction>
        </>
      ) : (
        <>
          <SettingChip>{t("settings.integrations.notRegistered")}</SettingChip>
          <SettingAction
            label={t("settings.integrations.registerTodoMcp")}
            disabled={busy}
            onClick={() =>
              void run(
                () => mcpInstall(agent),
                t("settings.integrations.mcpRegistered", { agent: AGENT_LABEL[agent] }),
              )
            }
          >
            <PlusIcon />
          </SettingAction>
        </>
      )}
    </SettingRow>
  );
}

/* ---------- ycode CLI ---------- */

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
    return i18next.t("settings.integrations.cliWindows");
  }
  return i18next.t("settings.integrations.cliUnix");
}

function CliRow() {
  const { t } = useTranslation();
  const [status, setStatus] = useState<CliInstallStatus | null>(null);
  const [busy, setBusy] = useState(false);

  const refresh = useCallback(
    () =>
      cliStatus()
        .then(setStatus)
        .catch((err) =>
        toast.danger(t("settings.integrations.cliReadFailed", { error: err })),
      ),
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
        toast.success(t("settings.integrations.cliInstalled"));
      } else {
        toast.warning(t("settings.integrations.cliIncomplete"));
      }
    } catch (err) {
      toast.danger(t("settings.integrations.cliInstallFailed", { error: err }));
      // The failure may itself have changed what's on disk (a partial
      // elevated run), so re-read rather than trusting the stale value.
      await refresh();
    } finally {
      setBusy(false);
    }
  }

  async function onUninstall() {
    setBusy(true);
    try {
      setStatus(await cliUninstall());
      toast.success(t("settings.integrations.cliRemoved"));
    } catch (err) {
      toast.danger(t("settings.integrations.cliRemoveFailed", { error: err }));
      await refresh();
    } finally {
      setBusy(false);
    }
  }

  const name = (
    <>
      <Trans i18nKey="settings.integrations.cliName" components={{ 1: <code /> }} />
    </>
  );
  const desc = (
    <>
      <Trans
        i18nKey="settings.integrations.cliDesc"
        components={{ 1: <code />, 3: <code /> }}
      />
    </>
  );

  if (status === null) {
    return (
      <SettingRow name={name} desc={desc}>
        <SettingChip>{t("common.loading")}</SettingChip>
      </SettingRow>
    );
  }

  if (status.kind === "conflict") {
    return (
      <SettingRow name={name} desc={`${status.path} — ${status.detail}`}>
        {/* The path is occupied by something we didn't create, so there is no
            safe action to offer — but the user needs a way to re-read the
            state after clearing it by hand, and mount is otherwise the only
            trigger. */}
        <SettingChip tone="warn">{t("settings.integrations.occupied")}</SettingChip>
        <SettingAction label={t("settings.integrations.recheck")} onClick={() => void refresh()}>
          <RefreshIcon />
        </SettingAction>
      </SettingRow>
    );
  }

  if (status.kind === "installed") {
    return (
      <SettingRow name={name} desc={desc}>
        <SettingChip tone="on" title={`${status.path} → ${status.target}`}>
          {status.path}
        </SettingChip>
        <SettingAction
          label={t("settings.integrations.removeCli")}
          tone="danger"
          disabled={busy}
          onClick={() => void onUninstall()}
        >
          <TrashIcon />
        </SettingAction>
      </SettingRow>
    );
  }

  if (status.kind === "stale") {
    return (
      <SettingRow
        name={name}
        desc={t("settings.integrations.staleTarget", {
              path: status.path,
              target: status.target,
            })}
      >
        <SettingChip tone="warn">{t("settings.integrations.needsRepair")}</SettingChip>
        <SettingAction
          label={t("settings.integrations.repairCli")}
          disabled={busy}
          onClick={() => void onInstall()}
        >
          <RefreshIcon />
        </SettingAction>
      </SettingRow>
    );
  }

  return (
    <SettingRow name={name} desc={installHint()}>
      <SettingChip>{t("settings.languages.notInstalled")}</SettingChip>
      <SettingAction
        label={t("settings.integrations.installCli")}
        disabled={busy}
        onClick={() => void onInstall()}
      >
        <PlusIcon />
      </SettingAction>
    </SettingRow>
  );
}

/* ---------- glyphs ---------- */

function PlusIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" aria-hidden>
      <path d="M12 5v14M5 12h14" />
    </svg>
  );
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
function RefreshIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="M21 12a9 9 0 1 1-3-6.7" />
      <path d="M21 4v5h-5" />
    </svg>
  );
}
