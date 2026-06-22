// Settings → Notifications: gates the global agent-turn-complete toast and
// wires the per-agent CLI hook installers.
//
// Two distinct sources of state:
//
// 1. `config.notifications` (staged in the parent ConfigView; saved on
//    "Save"). Pure UI gating — enable/disable + only-when-unfocused.
//
// 2. Per-agent install state on disk (~/.claude/settings.json hook,
//    ~/.codex/config.toml notify). Mutated immediately on button press
//    via the backend's `agent_install_hook` / `agent_uninstall_hook`
//    commands — these aren't undoable via "Cancel", so we treat them
//    like the file-tree's add-folder button: side effect on click.

import { useCallback, useEffect, useState } from "react";
import { Button, toast } from "@heroui/react";
import {
  agentHookStatus,
  agentInstallCodexChain,
  agentInstallHook,
  agentUninstallHook,
  mcpInstall,
  mcpStatus,
  mcpUninstall,
  testNotification,
  type AgentPatchStatus,
  type McpStatus,
} from "../lib/ipc";
import type { ConfigView } from "../lib/types";

interface Props {
  config: ConfigView;
  onChange: (next: ConfigView) => void;
}

type AgentId = "claude" | "codex" | "gemini";

const AGENT_LABEL: Record<AgentId, string> = {
  claude: "Claude Code",
  codex: "Codex",
  gemini: "Gemini CLI",
};

export function NotificationsSettings({ config, onChange }: Props) {
  // Mutating helpers for the staged config slice.
  function set<K extends keyof ConfigView["notifications"]>(
    key: K,
    value: ConfigView["notifications"][K],
  ) {
    onChange({
      ...config,
      notifications: { ...config.notifications, [key]: value },
    });
  }

  const enabled = config.notifications.enabled;

  return (
    <div className="appearance-settings">
      <p className="settings-section-blurb">
        Surface a system notification when an agent CLI finishes its turn so
        you don't have to keep an eye on the terminal. Each agent installs a
        small command in its own config (Claude <code>Stop</code> hook, Codex{" "}
        <code>notify</code>) that pings YCode.
      </p>

      <Field
        label="Enable notifications"
        hint="Master switch. When off, agent CLI hooks still fire but YCode swallows the event."
      >
        <input
          type="checkbox"
          checked={enabled}
          onChange={(e) => set("enabled", e.target.checked)}
        />
      </Field>

      <Field
        label="Only when YCode is unfocused"
        hint="If you keep YCode in the foreground, the terminal already shows the agent finishing — silence the toast in that case."
      >
        <input
          type="checkbox"
          checked={config.notifications.only_when_unfocused}
          onChange={(e) => set("only_when_unfocused", e.target.checked)}
          disabled={!enabled}
        />
      </Field>

      <div className="field">
        <Button
          size="sm"
          variant="outline"
          isDisabled={!enabled}
          onPress={() => {
            testNotification()
              .then(() => toast.success("Test notification fired"))
              .catch((err) => toast.danger(`Test failed: ${err}`));
          }}
        >
          Send test notification
        </Button>
        <div className="field-hint">
          On macOS this prompts for the system notification permission the
          first time.
        </div>
      </div>

      <hr style={{ border: "none", borderTop: "1px solid var(--rule)", margin: "8px 0" }} />

      <p className="settings-section-blurb">
        Per-agent hook installation. These edit files inside the agent's own
        config dir; a one-shot backup is written next to each file the first
        time we touch it (<code>.ycode.bak</code>).
      </p>

      <AgentRow agent="claude" />
      <AgentRow agent="codex" />
      <AgentRow agent="gemini" />

      <hr style={{ border: "none", borderTop: "1px solid var(--rule)", margin: "8px 0" }} />

      <p className="settings-section-blurb">
        Project todo list over MCP. Registers the bundled <code>ycode-mcp</code>{" "}
        server in the agent's config (Claude <code>~/.claude.json</code>, Codex{" "}
        <code>~/.codex/config.toml</code>) so the model can read and edit the
        current project's todos via <code>list_todos</code> / <code>add_todo</code>{" "}
        / <code>update_todo</code> / <code>delete_todo</code>. The project is
        inferred from the terminal — no project id needed.
      </p>

      <McpAgentRow agent="claude" />
      <McpAgentRow agent="codex" />
    </div>
  );
}

interface McpAgentRowProps {
  agent: "claude" | "codex";
}

function McpAgentRow({ agent }: McpAgentRowProps) {
  const [status, setStatus] = useState<McpStatus | null>(null);
  const [busy, setBusy] = useState(false);

  const refresh = useCallback(() => {
    mcpStatus(agent)
      .then(setStatus)
      .catch((err) => toast.danger(`${AGENT_LABEL[agent]} MCP status: ${err}`));
  }, [agent]);

  useEffect(refresh, [refresh]);

  async function onInstall() {
    setBusy(true);
    try {
      setStatus(await mcpInstall(agent));
      toast.success(`${AGENT_LABEL[agent]} todo MCP registered`);
    } catch (err) {
      toast.danger(`Install failed: ${err}`);
    } finally {
      setBusy(false);
    }
  }

  async function onUninstall() {
    setBusy(true);
    try {
      setStatus(await mcpUninstall(agent));
      toast.success(`${AGENT_LABEL[agent]} todo MCP removed`);
    } catch (err) {
      toast.danger(`Uninstall failed: ${err}`);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="field">
      <label className="field-label">
        {AGENT_LABEL[agent]}
        {status === "installed" && (
          <span style={{ marginLeft: 8, color: "var(--muted)", fontSize: 11 }}>
            registered
          </span>
        )}
      </label>
      {status === null ? (
        <div className="field-hint">Checking…</div>
      ) : status === "installed" ? (
        <Button size="sm" variant="ghost" onPress={onUninstall} isDisabled={busy}>
          {busy ? "Removing…" : "Remove todo MCP"}
        </Button>
      ) : (
        <Button size="sm" variant="primary" onPress={onInstall} isDisabled={busy}>
          {busy ? "Registering…" : "Register todo MCP"}
        </Button>
      )}
    </div>
  );
}

interface AgentRowProps {
  agent: AgentId;
}

function AgentRow({ agent }: AgentRowProps) {
  const [status, setStatus] = useState<AgentPatchStatus | null>(null);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState(false);

  const refresh = useCallback(() => {
    if (agent === "gemini") return; // unsupported in v1
    setLoading(true);
    agentHookStatus(agent)
      .then(setStatus)
      .catch((err) => toast.danger(`${AGENT_LABEL[agent]} status: ${err}`))
      .finally(() => setLoading(false));
  }, [agent]);

  useEffect(refresh, [refresh]);

  async function onInstall() {
    setBusy(true);
    try {
      const next = await agentInstallHook(agent as "claude" | "codex");
      setStatus(next);
      if (next.agent === "codex" && next.kind === "conflict_user_set") {
        toast.warning(
          "Codex already has a notify command — leaving your config alone.",
        );
      } else {
        toast.success(`${AGENT_LABEL[agent]} hook installed`);
      }
    } catch (err) {
      toast.danger(`Install failed: ${err}`);
    } finally {
      setBusy(false);
    }
  }

  async function onInstallChain() {
    if (status?.agent !== "codex" || status.kind !== "conflict_user_set") return;
    setBusy(true);
    try {
      const next = await agentInstallCodexChain(status.existing ?? []);
      setStatus(next);
      toast.success(`${AGENT_LABEL[agent]} hook installed on top of your notify`);
    } catch (err) {
      toast.danger(`Install failed: ${err}`);
    } finally {
      setBusy(false);
    }
  }

  async function onUninstall() {
    setBusy(true);
    try {
      const next = await agentUninstallHook(agent as "claude" | "codex");
      setStatus(next);
      toast.success(`${AGENT_LABEL[agent]} hook removed`);
    } catch (err) {
      toast.danger(`Uninstall failed: ${err}`);
    } finally {
      setBusy(false);
    }
  }

  // Gemini is the simplest case: no hook integration in v1.
  if (agent === "gemini") {
    return (
      <div className="field">
        <label className="field-label">{AGENT_LABEL[agent]}</label>
        <div
          className="field-hint"
          title="Gemini CLI has no Claude-style Stop hook. Planned for a later release."
        >
          Not supported in v1
        </div>
      </div>
    );
  }

  const inner = (() => {
    if (loading || !status) return <div className="field-hint">Checking…</div>;

    if (status.agent === "codex" && status.kind === "conflict_user_set") {
      const existing = status.existing ?? [];
      return (
        <>
          <div className="field-hint">
            You already set <code>notify</code> in <code>~/.codex/config.toml</code>:{" "}
            <code>{existing.join(" ")}</code>. YCode can wrap it so both fire
            on the same Codex event — Uninstall will restore your original.
          </div>
          <Button
            size="sm"
            variant="primary"
            onPress={onInstallChain}
            isDisabled={busy || existing.length === 0}
          >
            {busy ? "Installing…" : "Install on top of existing"}
          </Button>
        </>
      );
    }

    if (status.kind === "installed") {
      return (
        <Button size="sm" variant="ghost" onPress={onUninstall} isDisabled={busy}>
          {busy ? "Removing…" : "Remove hook"}
        </Button>
      );
    }

    return (
      <Button size="sm" variant="primary" onPress={onInstall} isDisabled={busy}>
        {busy ? "Installing…" : "Install hook"}
      </Button>
    );
  })();

  return (
    <div className="field">
      <label className="field-label">
        {AGENT_LABEL[agent]}
        {status?.kind === "installed" && (
          <span style={{ marginLeft: 8, color: "var(--muted)", fontSize: 11 }}>
            installed
          </span>
        )}
      </label>
      {inner}
    </div>
  );
}

function Field({
  label,
  hint,
  children,
}: {
  label: string;
  hint?: string;
  children: React.ReactNode;
}) {
  return (
    <div className="field">
      <label className="field-label">{label}</label>
      {hint && <div className="field-hint">{hint}</div>}
      {children}
    </div>
  );
}
