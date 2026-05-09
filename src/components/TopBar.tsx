import { useState } from "react";
import { listAgents, createSession } from "../lib/ipc";
import { useStore } from "../lib/store";
import type { AgentProfileView } from "../lib/types";

export function TopBar() {
  const [open, setOpen] = useState(false);
  const upsertSession = useStore((s) => s.upsertSession);
  const setActiveId = useStore((s) => s.setActiveId);

  return (
    <header className="topbar">
      <strong>ycode</strong>
      <button onClick={() => setOpen(true)}>+ New session</button>
      {open && (
        <NewSessionDialog
          onClose={() => setOpen(false)}
          onCreated={(view) => {
            upsertSession(view);
            setActiveId(view.id);
            setOpen(false);
          }}
        />
      )}
    </header>
  );
}

function NewSessionDialog({
  onClose,
  onCreated,
}: {
  onClose: () => void;
  onCreated: (view: import("../lib/types").SessionView) => void;
}) {
  const [agents, setAgents] = useState<AgentProfileView[]>([]);
  const [agentId, setAgentId] = useState<string>("");
  const [repoPath, setRepoPath] = useState("");
  const [title, setTitle] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  // Lazy-load the agent list the first time the dialog opens.
  if (agents.length === 0) {
    listAgents().then((list) => {
      setAgents(list);
      if (list[0]) setAgentId(list[0].id);
    });
  }

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      const view = await createSession({
        agent_profile_id: agentId,
        repo_path: repoPath.trim(),
        title: title.trim(),
      });
      onCreated(view);
    } catch (err) {
      // Inline error rather than alert() — modal stays open so the user
      // can see what failed and adjust their inputs without retyping.
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
            Agent
            <select value={agentId} onChange={(e) => setAgentId(e.target.value)}>
              {agents.map((a) => (
                <option key={a.id} value={a.id}>
                  {a.display_name} ({a.kind})
                </option>
              ))}
            </select>
          </label>
          <label>
            Repository
            <input
              value={repoPath}
              onChange={(e) => setRepoPath(e.target.value)}
              placeholder="/path/to/repo"
              required
            />
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
