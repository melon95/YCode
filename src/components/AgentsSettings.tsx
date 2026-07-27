// Agents settings: a single list of configured agents (added from the
// catalog) plus the catalog to add more. Agents are catalog-defined — id,
// command, args, env, introspect and icon all come from the built-in profile,
// so there's no per-agent detail editor: the panel just lists what's installed
// and lets you add/remove. Holds no IPC state of its own — the parent owns the
// staged ConfigView and we mutate via `onChange`.

import { useState } from "react";
import type { AgentLaunchProfileView, ConfigView } from "../lib/types";
import { useEscapeGuard } from "../lib/useEscapeGuard";
import { AgentIcon } from "./AgentIcon";

const KNOWN_AGENTS: AgentLaunchProfileView[] = [
  {
    id: "claude-code",
    display_name: "Claude Code",
    command: "claude",
    args: [],
    env: {},
    icon: "ClaudeCode",
    icon_variant: null,
    color: null,
    introspect: "claude",
  },
  {
    id: "codex",
    display_name: "Codex",
    command: "codex",
    args: [],
    env: {},
    icon: "Codex",
    icon_variant: null,
    color: null,
    introspect: "codex",
  },
  {
    id: "gemini-cli",
    display_name: "Gemini CLI",
    command: "gemini",
    args: [],
    env: {},
    icon: "GeminiCLI",
    icon_variant: null,
    color: null,
    introspect: null,
  },
  {
    id: "opencode",
    display_name: "OpenCode",
    command: "opencode",
    args: [],
    env: {},
    icon: null,
    icon_variant: null,
    color: null,
    introspect: null,
  },
  {
    id: "cursor-agent",
    display_name: "Cursor Agent",
    command: "cursor-agent",
    args: [],
    env: {},
    icon: null,
    icon_variant: null,
    color: null,
    introspect: null,
  },
  {
    id: "qwen-code",
    display_name: "Qwen Code",
    command: "qwen",
    args: [],
    env: {},
    icon: "Qwen",
    icon_variant: null,
    color: null,
    introspect: null,
  },
  {
    id: "goose",
    display_name: "Goose",
    command: "goose",
    args: [],
    env: {},
    icon: null,
    icon_variant: null,
    color: null,
    introspect: null,
  },
  {
    id: "kilo-code",
    display_name: "Kilo Code",
    command: "kilo",
    args: [],
    env: {},
    icon: "KiloCode",
    icon_variant: null,
    color: null,
    introspect: null,
  },
  {
    id: "copilot",
    display_name: "GitHub Copilot",
    command: "copilot",
    args: [],
    env: {},
    icon: "GithubCopilot",
    icon_variant: null,
    color: null,
    introspect: null,
  },
  {
    id: "aider",
    display_name: "Aider",
    command: "aider",
    args: [],
    env: {},
    icon: null,
    icon_variant: null,
    color: null,
    introspect: null,
  },
  {
    id: "amp",
    display_name: "Amp",
    command: "amp",
    args: [],
    env: {},
    icon: null,
    icon_variant: null,
    color: null,
    introspect: null,
  },
  {
    id: "crush",
    display_name: "Crush",
    command: "crush",
    args: [],
    env: {},
    icon: null,
    icon_variant: null,
    color: null,
    introspect: null,
  },
  {
    id: "plandex",
    display_name: "Plandex",
    command: "plandex",
    args: [],
    env: {},
    icon: null,
    icon_variant: null,
    color: null,
    introspect: null,
  },
];

interface Props {
  config: ConfigView;
  onChange: (next: ConfigView) => void;
}

export function AgentsSettings({ config, onChange }: Props) {
  // Inline "custom agent" form state. Lets users add any CLI not in the
  // catalog without re-introducing the full per-agent editor.
  const [adding, setAdding] = useState(false);
  const [customName, setCustomName] = useState("");
  const [customCommand, setCustomCommand] = useState("");

  function addKnownAgent(template: AgentLaunchProfileView) {
    onChange({ ...config, agents: [...config.agents, cloneAgent(template)] });
  }

  function deleteAgent(idx: number) {
    const agents = config.agents.slice();
    agents.splice(idx, 1);
    onChange({ ...config, agents });
  }

  const configuredIds = new Set(config.agents.map((a) => a.id));

  function confirmCustom() {
    const command = customCommand.trim();
    if (!command) return;
    const name = customName.trim();
    const id = uniqueId(kebab(name || command), configuredIds);
    const agent: AgentLaunchProfileView = {
      id,
      display_name: name || null,
      command,
      args: [],
      env: {},
      icon: null,
      icon_variant: null,
      color: null,
      introspect: null,
    };
    onChange({ ...config, agents: [...config.agents, agent] });
    setCustomName("");
    setCustomCommand("");
    setAdding(false);
  }

  function cancelCustom() {
    setCustomName("");
    setCustomCommand("");
    setAdding(false);
  }

  // Let Escape close the inline editor before the settings workspace itself.
  useEscapeGuard(cancelCustom, adding);

  const availableAgents = KNOWN_AGENTS.filter(
    (agent) => !configuredIds.has(agent.id),
  );

  return (
    <div className="agents-settings">
      <header className="settings-pane-heading">
        <h2>Agents</h2>
        <p>Choose which coding agents are available when starting a session.</p>
        <span>
          {config.agents.length} configured
        </span>
      </header>

      <section className="agent-group" aria-labelledby="configured-agents">
        <h3 id="configured-agents">Configured</h3>
        <div className="agents-list configured">
          {config.agents.length === 0 && (
            <p className="agents-list-empty">No agents configured yet.</p>
          )}
          {config.agents.map((agent, idx) => {
            const label = agent.display_name || agent.id;
            return (
              <div key={agent.id} className="agent-row configured">
                <span className="agent-row-icon">
                  <AgentIcon
                    icon={agent.icon}
                    variant={agent.icon_variant}
                    fallbackChar={label}
                    size={24}
                  />
                </span>
                <span className="agent-row-name">{label}</span>
                <code className="agent-row-command">{agent.command}</code>
                <span className="agent-row-status">Configured</span>
                <button
                  type="button"
                  className="agent-row-delete"
                  onClick={() => deleteAgent(idx)}
                  aria-label={`Remove ${label}`}
                >
                  Remove
                </button>
              </div>
            );
          })}
        </div>
      </section>

      <section className="agent-group" aria-labelledby="available-agents">
        <h3 id="available-agents">Available agents</h3>
        <div className="agents-list available">
          {availableAgents.map((agent) => {
            const label = agent.display_name || agent.id;
            return (
              <button
                key={agent.id}
                type="button"
                className="agent-row addable"
                onClick={() => addKnownAgent(agent)}
                title={`Add ${label}`}
              >
                <span className="agent-row-icon">
                <AgentIcon
                  icon={agent.icon}
                  variant={agent.icon_variant}
                  fallbackChar={label}
                  size={24}
                />
                </span>
                <span className="agent-row-name">{label}</span>
                <span className="agent-row-add">+ Add</span>
              </button>
            );
          })}

          {adding ? (
            <div className="agent-custom-form">
              <input
                type="text"
                className="native-input"
                placeholder="Display name (optional)"
                value={customName}
                autoFocus
                onChange={(e) => setCustomName(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter") confirmCustom();
                }}
              />
              <input
                type="text"
                className="native-input mono"
                placeholder="command (binary on PATH)"
                value={customCommand}
                onChange={(e) => setCustomCommand(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter") confirmCustom();
                }}
              />
              <button
                type="button"
                className="agent-custom-confirm"
                onClick={confirmCustom}
                disabled={!customCommand.trim()}
              >
                Add
              </button>
              <button
                type="button"
                className="agent-custom-cancel"
                onClick={cancelCustom}
              >
                Cancel
              </button>
            </div>
          ) : (
            <button
              type="button"
              className="agent-row addable agent-row-custom"
              onClick={() => setAdding(true)}
              title="Add a custom agent CLI"
            >
              <span className="agent-row-icon agent-row-custom-icon">+</span>
              <span className="agent-row-name">Custom agent…</span>
              <span className="agent-row-add">+ Add</span>
            </button>
          )}
        </div>
      </section>
    </div>
  );
}

/** kebab-case an arbitrary string for use as an agent id. */
function kebab(s: string): string {
  return (
    s
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "") || "agent"
  );
}

/** Ensure `base` doesn't collide with an existing id; suffix -2, -3, … */
function uniqueId(base: string, taken: Set<string>): string {
  if (!taken.has(base)) return base;
  let n = 2;
  while (taken.has(`${base}-${n}`)) n++;
  return `${base}-${n}`;
}

function cloneAgent(agent: AgentLaunchProfileView): AgentLaunchProfileView {
  return {
    ...agent,
    args: [...agent.args],
    env: { ...agent.env },
  };
}
