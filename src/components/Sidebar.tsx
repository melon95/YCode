import { useState } from "react";
import { Button } from "@heroui/react";
import { useStore } from "../lib/store";
import { SessionRow } from "./SessionRow";
import { NewSessionDialog } from "./TopBar";

export function Sidebar() {
  const [sessionOpen, setSessionOpen] = useState(false);
  const upsertSession = useStore((s) => s.upsertSession);
  const setActiveId = useStore((s) => s.setActiveId);
  const projects = useStore((s) => s.projects);
  const activeProjectId = useStore((s) => s.activeProjectId);
  const activeProject = activeProjectId ? projects[activeProjectId] : null;

  return (
    <aside className="sidebar">
      <div className="sidebar-header">
        <span>Sessions</span>
        <Button
          size="sm"
          variant="primary"
          onPress={() => setSessionOpen(true)}
          isDisabled={!activeProject}
          className="sidebar-new-session"
          isIconOnly
          aria-label="New session"
        >
          +
        </Button>
      </div>
      <div className="sidebar-content">
        {!activeProject ? (
          <div className="empty">
            No project selected.
            <br />
            Create one with <em>+</em> in the top bar.
          </div>
        ) : (
          <SessionsPanel projectId={activeProject.id} />
        )}
      </div>
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
