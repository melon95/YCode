import { useMemo } from "react";
import { toast } from "@heroui/react";
import { useStore } from "../lib/store";
import type { SessionView } from "../lib/types";

function targetLabel(session: SessionView): string {
  return session.branch ?? `ycode/${session.id.slice(-8)}`;
}

/**
 * Shared workspace switcher for every repo-facing surface in the right pane.
 * Choosing a session worktree here changes Files, Editor, Changes, LSP,
 * terminal links, and the manual terminal as one atomic UI context.
 */
export function WorkspaceTargetPicker({ projectId }: { projectId: string }) {
  const sessions = useStore((s) => s.sessions);
  const selectedSessionId = useStore(
    (s) => s.workspaceSessionByProject[projectId] ?? null,
  );
  // Only this project's own unsaved edits should block its switch. The live
  // `dirtyFiles` map belongs to the active project, so a background project's
  // stash must never gate us — and vice versa.
  const dirtyCount = useStore((s) =>
    s.activeProjectId === projectId ? Object.keys(s.dirtyFiles).length : 0,
  );
  const setWorkspaceSessionId = useStore((s) => s.setWorkspaceSessionId);

  const worktrees = useMemo(
    () =>
      Object.values(sessions)
        .filter(
          (session): session is SessionView =>
            session.project_id === projectId && !!session.worktree_path,
        )
        .sort((a, b) => b.updated_at_ms - a.updated_at_ms),
    [sessions, projectId],
  );

  const validSelection = worktrees.some(
    (session) => session.id === selectedSessionId,
  );
  const value = validSelection ? selectedSessionId ?? "" : "";

  return (
    <label className="workspace-target-picker">
      <select
        value={value}
        onChange={(event) => {
          const next = event.target.value || null;
          if (dirtyCount > 0) {
            toast.warning("Save or close edited files before switching workspace.");
            event.currentTarget.value = value;
            return;
          }
          setWorkspaceSessionId(projectId, next);
        }}
        title="Select the checkout used by Files, Editor, Changes, LSP, and Terminal"
        aria-label="Workspace target"
      >
        <option value="">Main checkout</option>
        {worktrees.map((session) => (
          <option key={session.id} value={session.id}>
            {targetLabel(session)}
          </option>
        ))}
      </select>
    </label>
  );
}
