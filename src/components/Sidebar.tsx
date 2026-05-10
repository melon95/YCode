import { useStore } from "../lib/store";
import type { SidebarTab } from "../lib/store";
import { SessionRow } from "./SessionRow";

const TABS: { id: SidebarTab; label: string }[] = [
  { id: "sessions", label: "Sessions" },
  { id: "files", label: "Files" },
  { id: "diff", label: "Changes" },
];

export function Sidebar() {
  const projects = useStore((s) => s.projects);
  const activeProjectId = useStore((s) => s.activeProjectId);
  const sidebarTab = useStore((s) => s.sidebarTab);
  const setSidebarTab = useStore((s) => s.setSidebarTab);
  const activeProject = activeProjectId ? projects[activeProjectId] : null;

  return (
    <aside className="sidebar">
      <div className="sidebar-tabs">
        {TABS.map((t) => (
          <button
            key={t.id}
            className={"sidebar-tab" + (sidebarTab === t.id ? " active" : "")}
            onClick={() => setSidebarTab(t.id)}
          >
            {t.label}
          </button>
        ))}
      </div>
      <div className="sidebar-content">
        {!activeProject ? (
          <div className="empty">
            No project selected.
            <br />
            Create one with <em>+</em> in the top bar.
          </div>
        ) : sidebarTab === "sessions" ? (
          <SessionsPanel projectId={activeProject.id} />
        ) : sidebarTab === "files" ? (
          <PlaceholderPanel
            title="File tree"
            note={`Will list files under ${activeProject.repo_path}`}
          />
        ) : (
          <PlaceholderPanel
            title="Changed files"
            note="Will list git-modified files (staged + unstaged)"
          />
        )}
      </div>
    </aside>
  );
}

function SessionsPanel({ projectId }: { projectId: string }) {
  const sessions = useStore((s) => s.sessions);
  const owned = Object.values(sessions)
    .filter((s) => s.project_id === projectId)
    .sort((a, b) => b.updated_at_ms - a.updated_at_ms);

  if (owned.length === 0) {
    return <div className="project-empty">No sessions yet.</div>;
  }
  return (
    <>
      {owned.map((s) => (
        <SessionRow key={s.id} session={s} />
      ))}
    </>
  );
}

function PlaceholderPanel({ title, note }: { title: string; note: string }) {
  return (
    <div className="empty">
      <strong>{title}</strong>
      <br />
      {note}
    </div>
  );
}
