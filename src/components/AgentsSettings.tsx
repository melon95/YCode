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

  // While the inline "add custom agent" sub-form is open, Escape cancels it
  // first. Registering through the shared guard means it sits ABOVE the Settings
  // modal's own guard on the stack, so one Escape closes the sub-form and a
  // second closes Settings — instead of a per-input onKeyDown handler that the
  // capture-phase guard would swallow before it ever fired.
  useEscapeGuard(cancelCustom, adding);

  // One flat list: configured agents first (in config order), then the
  // remaining catalog agents you can still add. `addedIdx` is the index into
  // config.agents for added rows, or null for addable ones.
  const rows: { agent: AgentLaunchProfileView; addedIdx: number | null }[] = [
    ...config.agents.map((agent, addedIdx) => ({ agent, addedIdx })),
    ...KNOWN_AGENTS.filter((a) => !configuredIds.has(a.id)).map((agent) => ({
      agent,
      addedIdx: null,
    })),
  ];

  return (
    <div className="agents-settings">
      <div className="agents-list">
        <div className="agents-list-header">
          <span className="agents-list-count">
            {config.agents.length} agent{config.agents.length === 1 ? "" : "s"}
          </span>
        </div>
        <div className="agents-list-rows">
          {rows.map(({ agent, addedIdx }) => {
            const added = addedIdx !== null;
            const label = agent.display_name || agent.id;
            const icon = (
              <span className="agent-row-icon">
                <AgentIcon
                  icon={agent.icon}
                  variant={agent.icon_variant}
                  fallbackChar={label}
                  size={16}
                />
              </span>
            );
            if (added) {
              return (
                <div key={agent.id} className="agent-row">
                  {icon}
                  <span className="agent-row-name">{label}</span>
                  <button
                    type="button"
                    className="agent-row-delete"
                    onClick={() => deleteAgent(addedIdx)}
                    aria-label={`Remove ${label}`}
                    title="Remove agent"
                  >
                    ×
                  </button>
                </div>
              );
            }
            return (
              <button
                key={agent.id}
                type="button"
                className="agent-row addable"
                onClick={() => addKnownAgent(agent)}
                title={`Add ${label}`}
              >
                {icon}
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
            </button>
          )}
        </div>
      </div>
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
