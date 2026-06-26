import { useEffect, useMemo, useState } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import {
  Button,
  Label,
  Modal,
  ModalBackdrop,
  ModalBody,
  ModalContainer,
  ModalDialog,
  ModalFooter,
  ModalHeader,
  ModalHeading,
  toast,
} from "@heroui/react";
import { listAgents, createSession, createProject, deleteProject } from "../lib/ipc";
import { useStore } from "../lib/store";
import type { AgentProfileView, ProjectView, SessionView } from "../lib/types";
import { confirmDialog } from "../lib/confirm";
import { openProjectInNewWindow } from "../lib/multiWindow";
import { LayoutSwitcher } from "./LayoutSwitcher";
import { SettingsModal } from "./SettingsModal";
import { ContextMenu, type ContextMenuItem } from "./ContextMenu";

export function TopBar() {
  const [creatingProject, setCreatingProject] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [menu, setMenu] = useState<{
    x: number;
    y: number;
    items: ContextMenuItem[];
  } | null>(null);
  const upsertProject = useStore((s) => s.upsertProject);
  const setActiveProjectId = useStore((s) => s.setActiveProjectId);
  const removeProject = useStore((s) => s.removeProject);
  const activeProjectId = useStore((s) => s.activeProjectId);
  const projects = useStore((s) => s.projects);
  const lockedProjectId = useStore((s) => s.lockedProjectId);
  const lockedByOtherWindows = useStore((s) => s.lockedByOtherWindows);
  const detached = lockedProjectId !== null;

  // Listen for global hotkeys dispatched from `useHotkeys`.
  useEffect(() => {
    const onOpenSettings = () => setSettingsOpen(true);
    const onNewProject = () => {
      if (!detached) void onAddProject();
    };
    window.addEventListener("ycode:open-settings", onOpenSettings);
    window.addEventListener("ycode:new-project", onNewProject);
    return () => {
      window.removeEventListener("ycode:open-settings", onOpenSettings);
      window.removeEventListener("ycode:new-project", onNewProject);
    };
  }, [detached, creatingProject]);

  // In a detached window only the locked project shows. In the main window
  // peers' projects are hidden so the same id never appears twice.
  const projectList = useMemo(() => {
    const all = Object.values(projects).sort(
      (a, b) => a.created_at_ms - b.created_at_ms,
    );
    if (lockedProjectId) return all.filter((p) => p.id === lockedProjectId);
    return all.filter((p) => !lockedByOtherWindows[p.id]);
  }, [projects, lockedProjectId, lockedByOtherWindows]);

  async function onAddProject() {
    if (creatingProject) return;
    setCreatingProject(true);
    try {
      const picked = await open({
        directory: true,
        multiple: false,
        title: "Choose project repository",
      });
      if (typeof picked !== "string") return; // user cancelled
      const name = picked.split("/").filter(Boolean).pop() ?? picked;
      const view = await createProject({ name, repo_path: picked });
      upsertProject(view);
      setActiveProjectId(view.id);
    } catch (err) {
      toast.danger(`Create project failed: ${err}`);
    } finally {
      setCreatingProject(false);
    }
  }

  async function onDeleteProject(p: ProjectView) {
    const ok = await confirmDialog({
      title: `Delete project "${p.name}"?`,
      message:
        "Live sessions block deletion; archived sessions stay but lose their project link.",
      confirmLabel: "Delete",
      destructive: true,
    });
    if (!ok) return;
    try {
      await deleteProject(p.id);
      removeProject(p.id);
    } catch (err) {
      toast.danger(`Delete failed: ${err}`);
    }
  }

  function onProjectContextMenu(e: React.MouseEvent, p: ProjectView) {
    e.preventDefault();
    if (detached) return; // detached windows own one project — nothing to detach
    setMenu({
      x: e.clientX,
      y: e.clientY,
      items: [
        {
          label: "Open in New Window",
          onSelect: () => {
            openProjectInNewWindow(p.id, p.name).catch((err) =>
              toast.danger(`Open in new window failed: ${err}`),
            );
          },
        },
      ],
    });
  }

  return (
    <header className="topbar">
      {/* Detached windows display the project name in the native window
          title bar (set when we spawn the WebviewWindow), so we hide the
          tab strip here to avoid showing the same name twice. */}
      {!detached && (
        <div className="project-tabs">
          {projectList.map((p) => {
            const active = p.id === activeProjectId;
            return (
              <div
                key={p.id}
                className={"project-tab" + (active ? " active" : "")}
                onClick={() => setActiveProjectId(p.id)}
                onContextMenu={(e) => onProjectContextMenu(e, p)}
                title={p.repo_path}
              >
                <span className="project-tab-name">{p.name}</span>
                <span
                  className="project-tab-close"
                  role="button"
                  aria-label="Delete project"
                  onClick={(e) => {
                    e.stopPropagation();
                    onDeleteProject(p);
                  }}
                >
                  ×
                </span>
              </div>
            );
          })}
          <button
            type="button"
            className="project-tab-add"
            onClick={onAddProject}
            disabled={creatingProject}
            aria-label="New project"
            title="New project"
          >
            +
          </button>
        </div>
      )}
      <LayoutSwitcher />
      <button
        type="button"
        className="topbar-search"
        onClick={() => window.dispatchEvent(new CustomEvent("ycode:open-palette"))}
        aria-label="Search across sessions (⌘K)"
        title="Search across sessions (⌘K)"
      >
        Search
      </button>
      <button
        type="button"
        className="topbar-gear"
        onClick={() => setSettingsOpen(true)}
        aria-label="Settings"
        title="Settings"
      >
        <GearIcon />
      </button>
      <SettingsModal open={settingsOpen} onClose={() => setSettingsOpen(false)} />
      {menu && (
        <ContextMenu
          x={menu.x}
          y={menu.y}
          items={menu.items}
          onClose={() => setMenu(null)}
        />
      )}
    </header>
  );
}

function GearIcon() {
  return (
    <svg
      width="16"
      height="16"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <circle cx="12" cy="12" r="3" />
      <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" />
    </svg>
  );
}

export function NewSessionDialog({
  project,
  onClose,
  onCreated,
  preferredAgentId,
}: {
  project: ProjectView;
  onClose: () => void;
  onCreated: (view: SessionView) => void;
  /// When provided, pre-selects this agent profile in the picker (assuming
  /// it's installed). Used by the Sidebar's per-agent tab so clicking "+"
  /// after picking Codex defaults to Codex.
  preferredAgentId?: string;
}) {
  const [agents, setAgents] = useState<AgentProfileView[]>([]);
  const [agentId, setAgentId] = useState<string>("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  // Lazy-load the agent list the first time the dialog opens. Hide the
  // `bash` fallback — it's available via the second-terminal panel, not as
  // a project session.
  if (agents.length === 0) {
    listAgents().then((list) => {
      const filtered = list.filter((a) => a.id !== "bash");
      setAgents(filtered);
      const preferred =
        preferredAgentId &&
        filtered.find((a) => a.id === preferredAgentId && a.available);
      const firstAvailable = filtered.find((a) => a.available) ?? filtered[0];
      const pick = preferred ?? firstAvailable;
      if (pick) setAgentId(pick.id);
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
        // Title is empty by default — the CLI's OSC title or the user's
        // double-click rename will fill it in. SessionRow falls back to
        // "New session" when both are blank.
        title: "",
      });
      onCreated(view);
    } catch (err) {
      setError(String(err));
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <Modal isOpen onOpenChange={(open) => !open && onClose()}>
      <ModalBackdrop>
        <ModalContainer placement="center" size="md">
          <ModalDialog>
            <form onSubmit={submit}>
              <ModalHeader>
                <ModalHeading>New session</ModalHeading>
              </ModalHeader>
              <ModalBody className="flex flex-col gap-3">
                <div className="flex flex-col gap-1">
                  <Label>Project</Label>
                  <div className="readonly-field">
                    {project.name}
                    <span className="text-(--muted) ml-2">{project.repo_path}</span>
                  </div>
                </div>
                <div className="flex flex-col gap-1">
                  <Label>Agent</Label>
                  <select
                    value={agentId}
                    onChange={(e) => setAgentId(e.target.value)}
                    className="native-select"
                  >
                    {agents.map((a) => (
                      <option key={a.id} value={a.id} disabled={!a.available}>
                        {a.display_name} ({a.command}
                        {a.available ? "" : " — not installed"})
                      </option>
                    ))}
                  </select>
                </div>
                {error && <div className="form-error">{error}</div>}
              </ModalBody>
              <ModalFooter className="flex justify-end gap-2">
                <Button type="button" variant="ghost" onPress={onClose}>
                  Cancel
                </Button>
                <Button
                  type="submit"
                  variant="primary"
                  isDisabled={!agentId || submitting}
                >
                  {submitting ? "Creating…" : "Create"}
                </Button>
              </ModalFooter>
            </form>
          </ModalDialog>
        </ModalContainer>
      </ModalBackdrop>
    </Modal>
  );
}
