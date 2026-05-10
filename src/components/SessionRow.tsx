import { archiveSession, restartSession } from "../lib/ipc";
import { useStore } from "../lib/store";
import { isRestartable, statusLabel, type SessionView } from "../lib/types";

export function SessionRow({ session: s }: { session: SessionView }) {
  const activeId = useStore((st) => st.activeId);
  const setActiveId = useStore((st) => st.setActiveId);
  const removeSession = useStore((st) => st.removeSession);
  const upsertSession = useStore((st) => st.upsertSession);

  const label = statusLabel(s.status);

  function select() {
    setActiveId(s.id);
  }

  async function archive(e: React.MouseEvent) {
    e.stopPropagation();
    if (!confirm(`Archive "${s.title}"? Live processes will be killed.`)) {
      return;
    }
    try {
      await archiveSession(s.id);
      removeSession(s.id);
    } catch (err) {
      alert(`Archive failed: ${err}`);
    }
  }

  async function restart(e: React.MouseEvent) {
    e.stopPropagation();
    try {
      const view = await restartSession(s.id);
      upsertSession(view);
    } catch (err) {
      alert(`Restart failed: ${err}`);
    }
  }

  return (
    <div
      className={"session-row" + (s.id === activeId ? " active" : "")}
      onClick={select}
    >
      <div className="title">{s.title}</div>
      <div className="meta">
        <span className={`dot ${label}`} />
        <span>{label}</span>
        <span style={{ marginLeft: "auto", color: "var(--muted)" }}>
          {s.agent_profile}
        </span>
      </div>
      <div className="row-actions">
        {isRestartable(s.status) && (
          <button onClick={restart} title="Restart this session">
            ↻
          </button>
        )}
        <button onClick={archive} title="Archive this session">
          ×
        </button>
      </div>
    </div>
  );
}
