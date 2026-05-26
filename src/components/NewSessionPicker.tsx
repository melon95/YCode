// "New task" picker shown in the middle pane when the active project has no
// sessions. Clicking an agent immediately creates a session (no extra dialog
// or title prompt — the agent's display name becomes the session title).
//
// The agent list comes straight from the store (populated at startup from
// the backend's JSON config). No hardcoded filtering — every configured
// profile is shown, with `available: false` ones disabled so the user can
// see at a glance which CLIs they still need to install.

import { useMemo, useState } from "react";
import { Card } from "@heroui/react";
import { createSession } from "../lib/ipc";
import { useStore } from "../lib/store";
import type { AgentProfileView, ProjectView } from "../lib/types";
import ycodeLogoUrl from "../assets/ycode-logo.svg";
import { AgentIcon } from "./AgentIcon";

export function NewSessionPicker({ project }: { project: ProjectView }) {
  const agents = useStore((s) => s.agents);
  const [creatingId, setCreatingId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const upsertSession = useStore((s) => s.upsertSession);
  const openSessionInLayout = useStore((s) => s.openSessionInLayout);

  // Show only agents whose command resolved on PATH (per user request —
  // unavailable agents are noise in the picker; Settings is where they
  // surface). Within the available set, introspect-bound profiles go first
  // (they integrate with the history sidebar), then PTY-only ones; config
  // order preserved within each group.
  const sorted = useMemo(() => {
    const available = agents.filter((a) => a.available);
    const introspectable = available.filter((a) => !!a.introspect);
    const ptyOnly = available.filter((a) => !a.introspect);
    return [...introspectable, ...ptyOnly];
  }, [agents]);

  async function pick(agent: AgentProfileView) {
    if (!agent.available || creatingId) return;
    setCreatingId(agent.id);
    setError(null);
    try {
      const view = await createSession({
        agent_profile_id: agent.id,
        project_id: project.id,
        // Empty — SessionRow shows the live CLI title (or "New session")
        // until the user double-clicks to rename.
        title: "",
      });
      upsertSession(view);
      openSessionInLayout(view.id);
    } catch (err) {
      setError(String(err));
    } finally {
      setCreatingId(null);
    }
  }

  return (
    <div className="new-session-picker-host">
      <Card variant="default" className="new-session-picker">
        <div className="picker-icon" aria-hidden>
          <img src={ycodeLogoUrl} alt="" className="picker-logo" />
        </div>
        <h2 className="picker-title">New Session</h2>
        <p className="picker-subtitle">
          Pick an agent to start a new session in {project.name}
        </p>
        {error && <div className="form-error">{error}</div>}
        <div className="picker-agents">
          {sorted.length === 0 && !error && (
            <div className="empty" style={{ padding: 12 }}>
              No agents configured. Edit
              <code> ~/.config/ycode/config.json</code> to add one.
            </div>
          )}
          {sorted.map((agent) => (
            <button
              key={agent.id}
              type="button"
              className={
                "picker-agent" +
                (agent.available ? "" : " unavailable") +
                (creatingId === agent.id ? " creating" : "")
              }
              onClick={() => pick(agent)}
              disabled={!agent.available || creatingId !== null}
              title={
                agent.available
                  ? `${agent.command}`
                  : `${agent.command} — not on PATH`
              }
            >
              <div className="picker-agent-avatar">
                <AgentIcon
                  icon={agent.icon}
                  variant={agent.icon_variant}
                  fallbackChar={agent.display_name}
                  size={28}
                />
              </div>
              <div className="picker-agent-name">{agent.display_name}</div>
              {!agent.available && (
                <span className="picker-agent-status">Not Configured</span>
              )}
              <span
                className={
                  "picker-agent-dot " +
                  (agent.available ? "available" : "unavailable")
                }
                aria-hidden
              />
            </button>
          ))}
        </div>
      </Card>
    </div>
  );
}
