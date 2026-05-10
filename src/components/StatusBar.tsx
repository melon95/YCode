import { useStore } from "../lib/store";
import { statusLabel } from "../lib/types";

export function StatusBar() {
  const sessions = useStore((s) => s.sessions);
  const active = useStore((s) => (s.activeId ? s.sessions[s.activeId] : null));

  const total = Object.values(sessions);
  const live = total.filter((s) => s.status.type === "Running").length;
  const counts = total.length === 0 ? "" : `${live} running / ${total.length} total`;
  const right = active
    ? `${active.agent_profile} · ${statusLabel(active.status)}`
    : "";

  return (
    <footer className="statusbar">
      <span>{counts}</span>
      <span style={{ marginLeft: "auto" }}>{right}</span>
    </footer>
  );
}
