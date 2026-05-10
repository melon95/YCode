import { useState } from "react";
import { listAgents, createSession, deleteProject } from "../lib/ipc";
import { useStore } from "../lib/store";
import type { AgentProfileView, ProjectView, SessionView } from "../lib/types";
import { NewProjectDialog } from "./NewProjectDialog";

export function TopBar() {
  const [projectOpen, setProjectOpen] = useState(false);
  const [sessionOpen, setSessionOpen] = useState(false);
  const upsertSession = useStore((s) => s.upsertSession);
  const upsertProject = useStore((s) => s.upsertProject);
  const setActiveId = useStore((s) => s.setActiveId);
  const setActiveProjectId = useStore((s) => s.setActiveProjectId);
  const removeProject = useStore((s) => s.removeProject);
  const activeProjectId = useStore((s) => s.activeProjectId);
  const projects = useStore((s) => s.projects);
  const activeProject = activeProjectId ? projects[activeProjectId] : null;

  const projectList = Object.values(projects).sort(
    (a, b) => a.created_at_ms - b.created_at_ms,
  );

  async function onDeleteProject(p: ProjectView) {
    if (
      !confirm(
        `Delete project "${p.name}"? Live sessions block deletion; archived sessions stay but lose their project link.`,
      )
    ) {
      return;
    }
    try {
      await deleteProject(p.id);
      removeProject(p.id);
    } catch (err) {
      alert(`Delete failed: ${err}`);
    }
  }

  return (
    <header className="topbar">
      <strong className="brand">ycode</strong>
      <div className="project-tabs">
        {projectList.map((p) => {
          const active = p.id === activeProjectId;
          return (
            <div
              key={p.id}
              className={"project-tab" + (active ? " active" : "")}
              onClick={() => setActiveProjectId(p.id)}
              title={p.repo_path}
            >
              <span className="project-tab-name">{p.name}</span>
              <button
                className="project-tab-close"
                onClick={(e) => {
                  e.stopPropagation();
                  onDeleteProject(p);
                }}
                title="Delete project"
              >
                ×
              </button>
            </div>
          );
        })}
        <button
          className="project-tab-add"
          onClick={() => setProjectOpen(true)}
          title="New project"
        >
          +
        </button>
      </div>
      <button
        className="new-session-btn"
        onClick={() => setSessionOpen(true)}
        disabled={!activeProject}
        title={
          activeProject
            ? `Create a session in ${activeProject.name}`
            : "Select a project first"
        }
      >
        + Session
      </button>
      {projectOpen && (
        <NewProjectDialog
          onClose={() => setProjectOpen(false)}
          onCreated={(view) => {
            upsertProject(view);
            setActiveProjectId(view.id);
            setProjectOpen(false);
          }}
        />
      )}
      {sessionOpen && activeProject && (
        <NewSessionDialog
          project={activeProject}
          onClose={() => setSessionOpen(false)}
          onCreated={(view) => {
            upsertSession(view);
            setActiveId(view.id);
            setSessionOpen(false);
          }}
        />
      )}
    </header>
  );
}

function NewSessionDialog({
  project,
  onClose,
  onCreated,
}: {
  project: ProjectView;
  onClose: () => void;
  onCreated: (view: SessionView) => void;
}) {
  const [agents, setAgents] = useState<AgentProfileView[]>([]);
  const [agentId, setAgentId] = useState<string>("");
  const [title, setTitle] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  // Lazy-load the agent list the first time the dialog opens.
  if (agents.length === 0) {
    listAgents().then((list) => {
      setAgents(list);
      const firstAvailable = list.find((a) => a.available) ?? list[0];
      if (firstAvailable) setAgentId(firstAvailable.id);
    });
  }

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      const view = await createSession({
        agent_profile_id: agentId,
        project_id: project.id,
        title: title.trim(),
      });
      onCreated(view);
    } catch (err) {
      setError(String(err));
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <form className="new-session-form" onSubmit={submit}>
          <h3>New session</h3>
          <label>
            Project
            <div className="readonly-field">
              {project.name}
              <span style={{ color: "var(--muted)", marginLeft: 8 }}>
                {project.repo_path}
              </span>
            </div>
          </label>
          <label>
            Agent
            <select value={agentId} onChange={(e) => setAgentId(e.target.value)}>
              {agents.map((a) => (
                <option key={a.id} value={a.id} disabled={!a.available}>
                  {a.display_name} ({a.command}
                  {a.available ? "" : " — not installed"})
                </option>
              ))}
            </select>
          </label>
          <label>
            Title
            <input
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              placeholder="describe this session"
              required
            />
          </label>
          {error && <div className="form-error">{error}</div>}
          <div className="modal-buttons">
            <button type="button" onClick={onClose}>
              Cancel
            </button>
            <button
              type="submit"
              className="primary"
              disabled={!agentId || submitting}
            >
              {submitting ? "Creating…" : "Create"}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
