import { archiveSession, replayEvents, restartSession } from "../lib/ipc";
import { useStore } from "../lib/store";
import { stateLabel, type SessionView } from "../lib/types";

export function SessionRow({ session: s }: { session: SessionView }) {
  const activeId = useStore((st) => st.activeId);
  const setActiveId = useStore((st) => st.setActiveId);
  const setEvents = useStore((st) => st.setEvents);
  const removeSession = useStore((st) => st.removeSession);
  const upsertSession = useStore((st) => st.upsertSession);
  const eventsForId = useStore((st) => st.events[s.id]);

  const label = stateLabel(s.state);
  const showRestart = label === "done" || label === "error";

  async function select() {
    setActiveId(s.id);
    // Backfill transcript on first selection only — subsequent selects use
    // the in-memory log accumulated from live events.
    if (!eventsForId || eventsForId.length === 0) {
      const entries = await replayEvents({ session_id: s.id, from_seq: 0 });
      setEvents(
        s.id,
        entries.map((e) => e.event),
      );
    }
  }

  async function archive(e: React.MouseEvent) {
    e.stopPropagation();
    if (!confirm(`Archive "${s.title}"? The worktree will be removed; the branch is kept.`)) {
      return;
    }
    try {
      await archiveSession(s.id, false);
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
      setEvents(view.id, []);
      // Force a transcript refetch when this row is the active one.
      if (activeId === s.id) await select();
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
        {showRestart && (
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
