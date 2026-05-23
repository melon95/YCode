// "New task" picker shown in the middle pane when the active project has no
// sessions. Clicking an agent immediately creates a session (no extra dialog
// or title prompt — the agent's display name becomes the session title).

import { useEffect, useState } from "react";
import { Card } from "@heroui/react";
import { createSession, listAgents } from "../lib/ipc";
import { useStore } from "../lib/store";
import type { AgentProfileView, ProjectView } from "../lib/types";

export function NewSessionPicker({ project }: { project: ProjectView }) {
  const [agents, setAgents] = useState<AgentProfileView[]>([]);
  const [creatingId, setCreatingId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const upsertSession = useStore((s) => s.upsertSession);
  const setActiveId = useStore((s) => s.setActiveId);

  useEffect(() => {
    let cancelled = false;
    listAgents()
      .then((list) => {
        // The default config registers a `bash` profile so users have a
        // fallback shell, but it's not an "AI agent" — hide it from the picker.
        // Users who really want a shell session can use the second-terminal
        // panel in the right column.
        if (!cancelled) setAgents(list.filter((a) => a.id !== "bash"));
      })
      .catch((err) => {
        if (!cancelled) setError(String(err));
      });
    return () => {
      cancelled = true;
    };
  }, []);

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
      setActiveId(view.id);
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
          <BotIcon />
        </div>
        <h2 className="picker-title">New task</h2>
        <p className="picker-subtitle">
          Pick an agent to start a new session in {project.name}
        </p>
        {error && <div className="form-error">{error}</div>}
        <div className="picker-agents">
          {agents.length === 0 && !error && (
            <div className="empty" style={{ padding: 12 }}>
              Loading agents…
            </div>
          )}
          {agents.map((agent) => (
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
                {agent.display_name.charAt(0).toUpperCase()}
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

function BotIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      width="48"
      height="48"
    >
      <rect x="4" y="8" width="16" height="12" rx="3" />
      <path d="M12 3v5" />
      <circle cx="12" cy="3" r="0.8" fill="currentColor" />
      <circle cx="9" cy="13" r="1" fill="currentColor" />
      <circle cx="15" cy="13" r="1" fill="currentColor" />
      <path d="M9 17h6" />
    </svg>
  );
}
