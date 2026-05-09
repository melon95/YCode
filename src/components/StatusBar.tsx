import { useStore } from "../lib/store";
import { stateLabel } from "../lib/types";

export function StatusBar() {
  const sessions = useStore((s) => s.sessions);
  const active = useStore((s) =>
    s.activeId ? s.sessions[s.activeId] : null,
  );

  const total = Object.values(sessions);
  const live = total.filter((s) => s.is_live).length;
  const counts = total.length === 0 ? "" : `${live} live / ${total.length} total`;
  const right = active
    ? `${active.agent_profile} · ${stateLabel(active.state)}`
    : "";

  return (
    <footer className="statusbar">
      <span>{counts}</span>
      <span style={{ marginLeft: "auto" }}>{right}</span>
    </footer>
  );
}
