import { useStore } from "../lib/store";
import { SessionRow } from "./SessionRow";

export function Sidebar() {
  const sessions = useStore((s) => s.sessions);
  const sorted = Object.values(sessions).sort(
    (a, b) => b.updated_at_ms - a.updated_at_ms,
  );

  if (sorted.length === 0) {
    return (
      <aside className="sidebar">
        <div className="empty">No sessions yet.</div>
      </aside>
    );
  }

  return (
    <aside className="sidebar">
      {sorted.map((s) => (
        <SessionRow key={s.id} session={s} />
      ))}
    </aside>
  );
}
