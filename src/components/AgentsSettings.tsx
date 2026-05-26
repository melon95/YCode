// Master-detail editor for the agents list inside the Settings modal.
// Holds no IPC state of its own — the parent owns the staged ConfigView
// and we mutate via `onChange`.

import { useEffect, useState } from "react";
import { Button } from "@heroui/react";
import { probeCommand } from "../lib/ipc";
import type { AgentLaunchProfileView, ConfigView } from "../lib/types";
import { AgentIcon } from "./AgentIcon";
import { IconPicker } from "./IconPicker";

const INTROSPECT_OPTIONS = [
  { value: "", label: "None (PTY-only, no history sidebar)" },
  { value: "claude", label: "Claude jsonl parser" },
  { value: "codex", label: "Codex jsonl parser" },
];

/// Built-in agent ids — these ship with canonical brand icons that we don't
/// want users to second-guess. Renaming the id (i.e., diverging from the
/// default) is the gesture that re-opens the icon controls.
const BUILTIN_AGENT_IDS = new Set(["claude-code", "codex", "gemini-cli"]);

interface Props {
  config: ConfigView;
  onChange: (next: ConfigView) => void;
}

export function AgentsSettings({ config, onChange }: Props) {
  const [selectedIdx, setSelectedIdx] = useState<number>(
    config.agents.length > 0 ? 0 : -1,
  );

  // Keep the selected index in range when the list shrinks (delete) or
  // grows (add — auto-select the new entry).
  useEffect(() => {
    if (selectedIdx >= config.agents.length) {
      setSelectedIdx(config.agents.length - 1);
    }
  }, [config.agents.length, selectedIdx]);

  function updateAgent(idx: number, patch: Partial<AgentLaunchProfileView>) {
    const next = config.agents.slice();
    next[idx] = { ...next[idx], ...patch };
    onChange({ ...config, agents: next });
  }

  function addAgent() {
    const fresh: AgentLaunchProfileView = {
      id: uniqueId(config.agents.map((a) => a.id), "new-agent"),
      display_name: "New Agent",
      command: "",
      args: [],
      env: {},
      icon: null,
      icon_variant: null,
      color: null,
      introspect: null,
    };
    const agents = [...config.agents, fresh];
    onChange({ ...config, agents });
    setSelectedIdx(agents.length - 1);
  }

  function deleteAgent(idx: number) {
    const agents = config.agents.slice();
    agents.splice(idx, 1);
    onChange({ ...config, agents });
    setSelectedIdx(Math.min(idx, agents.length - 1));
  }

  const selected =
    selectedIdx >= 0 && selectedIdx < config.agents.length
      ? config.agents[selectedIdx]
      : null;

  // Cross-row uniqueness check — feeds inline validation in the editor.
  const otherIds = config.agents
    .filter((_, i) => i !== selectedIdx)
    .map((a) => a.id);
  const idCollision = selected ? otherIds.includes(selected.id) : false;

  return (
    <div className="agents-settings">
      <div className="agents-list">
        <div className="agents-list-header">
          <span className="agents-list-count">
            {config.agents.length} agent{config.agents.length === 1 ? "" : "s"}
          </span>
          <Button size="sm" variant="outline" onPress={addAgent}>
            + New
          </Button>
        </div>
        <div className="agents-list-rows">
          {config.agents.map((a, i) => (
            <button
              key={i}
              type="button"
              className={
                "agent-row" + (i === selectedIdx ? " selected" : "")
              }
              onClick={() => setSelectedIdx(i)}
            >
              <span className="agent-row-icon">
                <AgentIcon
                  icon={a.icon}
                  variant={a.icon_variant}
                  fallbackChar={a.display_name || a.id}
                  size={16}
                />
              </span>
              <span className="agent-row-name">
                {a.display_name || a.id}
              </span>
              <span className="agent-row-cmd">{a.command || "—"}</span>
            </button>
          ))}
          {config.agents.length === 0 && (
            <div className="agents-list-empty">
              No agents configured.
              <br />
              Click + New to add one.
            </div>
          )}
        </div>
      </div>
      <div className="agent-editor">
        {selected ? (
          <AgentEditor
            agent={selected}
            idCollision={idCollision}
            onChange={(patch) => updateAgent(selectedIdx, patch)}
            onDelete={() => deleteAgent(selectedIdx)}
          />
        ) : (
          <div className="agent-editor-empty">
            Select an agent on the left, or click <strong>+ New</strong> to
            add one.
          </div>
        )}
      </div>
    </div>
  );
}

interface EditorProps {
  agent: AgentLaunchProfileView;
  idCollision: boolean;
  onChange: (patch: Partial<AgentLaunchProfileView>) => void;
  onDelete: () => void;
}

function AgentEditor({ agent, idCollision, onChange, onDelete }: EditorProps) {
  const [probeState, setProbeState] = useState<
    "idle" | "probing" | "ok" | "missing"
  >("idle");

  async function runProbe() {
    if (!agent.command) {
      setProbeState("missing");
      return;
    }
    setProbeState("probing");
    try {
      const ok = await probeCommand(agent.command);
      setProbeState(ok ? "ok" : "missing");
    } catch {
      setProbeState("missing");
    }
  }

  // Reset probe indicator when the user edits the command.
  function setCommand(c: string) {
    onChange({ command: c });
    setProbeState("idle");
  }

  const envEntries = Object.entries(agent.env);

  function setEnvKey(oldKey: string, newKey: string) {
    if (oldKey === newKey) return;
    const next: Record<string, string> = {};
    for (const [k, v] of Object.entries(agent.env)) {
      // ts-rs maps BTreeMap to `{ [k]?: string }`, so values are nominally
      // optional — fall back to "" so the user can still rename a key whose
      // value hasn't been set yet.
      next[k === oldKey ? newKey : k] = v ?? "";
    }
    onChange({ env: next });
  }

  function setEnvValue(key: string, value: string) {
    onChange({ env: { ...agent.env, [key]: value } });
  }

  function removeEnvEntry(key: string) {
    const next = { ...agent.env };
    delete next[key];
    onChange({ env: next });
  }

  function addEnvEntry() {
    const newKey = uniqueEnvKey(Object.keys(agent.env));
    onChange({ env: { ...agent.env, [newKey]: "" } });
  }

  return (
    <div className="agent-editor-form">
      <Field label="id" hint="kebab-case; appears in URLs and DB rows">
        <input
          type="text"
          value={agent.id}
          onChange={(e) => onChange({ id: e.target.value })}
          className={"native-input" + (idCollision ? " error" : "")}
        />
        {idCollision && (
          <div className="field-error">Another agent already uses this id.</div>
        )}
      </Field>

      <Field label="display name">
        <input
          type="text"
          value={agent.display_name ?? ""}
          onChange={(e) =>
            onChange({ display_name: e.target.value || null })
          }
          className="native-input"
          placeholder={agent.id}
        />
      </Field>

      <Field label="command" hint="binary name on PATH or absolute path">
        <div className="field-row">
          <input
            type="text"
            value={agent.command}
            onChange={(e) => setCommand(e.target.value)}
            className="native-input"
          />
          <Button size="sm" variant="outline" onPress={runProbe}>
            {probeState === "probing" ? "Probing…" : "Test"}
          </Button>
          {probeState === "ok" && (
            <span className="probe-result probe-ok">✓ on PATH</span>
          )}
          {probeState === "missing" && (
            <span className="probe-result probe-missing">✗ not found</span>
          )}
        </div>
      </Field>

      <Field
        label="args"
        hint="one per line; passed to the CLI before any --resume flag"
      >
        <textarea
          value={agent.args.join("\n")}
          onChange={(e) =>
            onChange({
              args: e.target.value.split("\n").filter((s) => s.length > 0),
            })
          }
          rows={3}
          className="native-input mono"
          placeholder="--no-color&#10;--debug"
        />
      </Field>

      <Field label="env" hint="$VAR_NAME values are expanded from the shell">
        <div className="env-list">
          {envEntries.map(([k, v]) => (
            <div key={k} className="env-row">
              <input
                type="text"
                value={k}
                onChange={(e) => setEnvKey(k, e.target.value)}
                className="native-input mono"
                placeholder="KEY"
              />
              <input
                type="text"
                value={v}
                onChange={(e) => setEnvValue(k, e.target.value)}
                className="native-input mono"
                placeholder="value or $VAR"
              />
              <Button
                size="sm"
                variant="ghost"
                isIconOnly
                onPress={() => removeEnvEntry(k)}
                aria-label={`Remove ${k}`}
              >
                ×
              </Button>
            </div>
          ))}
          <Button
            size="sm"
            variant="outline"
            onPress={addEnvEntry}
            className="env-add"
          >
            + Add env var
          </Button>
        </div>
      </Field>

      <Field
        label="introspect"
        hint="bind to a jsonl parser so sessions show in the history sidebar"
      >
        <select
          value={agent.introspect ?? ""}
          onChange={(e) =>
            onChange({ introspect: e.target.value || null })
          }
          className="native-select"
        >
          {INTROSPECT_OPTIONS.map((o) => (
            <option key={o.value} value={o.value}>
              {o.label}
            </option>
          ))}
        </select>
      </Field>

      {BUILTIN_AGENT_IDS.has(agent.id) ? (
        <div className="field-hint" style={{ paddingTop: 4 }}>
          Icon, variant, and color are managed by the built-in profile.
          Change <code>id</code> to customize them.
        </div>
      ) : (
        <>
          <Field label="icon">
            <IconPicker
              value={agent.icon}
              onChange={(icon) => onChange({ icon })}
            />
          </Field>

          <Field label="icon variant">
            <select
              value={agent.icon_variant ?? "color"}
              onChange={(e) =>
                onChange({ icon_variant: e.target.value || null })
              }
              className="native-select"
            >
              <option value="color">Color (brand-tinted)</option>
              <option value="mono">Mono (currentColor)</option>
            </select>
          </Field>

          <Field label="color" hint="advisory; not yet rendered anywhere">
            <div className="field-row">
              <input
                type="color"
                value={agent.color ?? "#888888"}
                onChange={(e) => onChange({ color: e.target.value })}
                className="native-color"
              />
              <input
                type="text"
                value={agent.color ?? ""}
                onChange={(e) =>
                  onChange({ color: e.target.value || null })
                }
                className="native-input mono"
                placeholder="#rrggbb"
              />
            </div>
          </Field>
        </>
      )}

      <div className="agent-editor-actions">
        <Button variant="ghost" onPress={onDelete} className="danger">
          Delete agent
        </Button>
      </div>
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

function uniqueId(existing: string[], base: string): string {
  if (!existing.includes(base)) return base;
  let n = 2;
  while (existing.includes(`${base}-${n}`)) n++;
  return `${base}-${n}`;
}

function uniqueEnvKey(existing: string[]): string {
  let n = 1;
  while (existing.includes(`KEY_${n}`)) n++;
  return `KEY_${n}`;
}
