import { useState } from "react";
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

export function TopBar() {
  const [creatingProject, setCreatingProject] = useState(false);
  const upsertProject = useStore((s) => s.upsertProject);
  const setActiveProjectId = useStore((s) => s.setActiveProjectId);
  const removeProject = useStore((s) => s.removeProject);
  const activeProjectId = useStore((s) => s.activeProjectId);
  const projects = useStore((s) => s.projects);

  const projectList = Object.values(projects).sort(
    (a, b) => a.created_at_ms - b.created_at_ms,
  );

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

  return (
    <header className="topbar">
      <strong className="brand">YCode</strong>
      <div className="project-tabs">
        {projectList.map((p) => {
          const active = p.id === activeProjectId;
          return (
            <div
              key={p.id}
              className={"project-tab" + (active ? " active" : "")}
              onClick={() => setActiveProjectId(p.id)}
              title={p.repo_path}
            >
              <span className="project-tab-name">{p.name}</span>
              <Button
                size="sm"
                variant="ghost"
                isIconOnly
                onPress={() => onDeleteProject(p)}
                className="project-tab-close-btn"
                aria-label="Delete project"
              >
                ×
              </Button>
            </div>
          );
        })}
        <Button
          size="sm"
          variant="outline"
          isIconOnly
          onPress={onAddProject}
          isDisabled={creatingProject}
          aria-label="New project"
        >
          +
        </Button>
      </div>
    </header>
  );
}

export function NewSessionDialog({
  project,
  onClose,
  onCreated,
}: {
  project: ProjectView;
  onClose: () => void;
  onCreated: (view: SessionView) => void;
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
      const firstAvailable = filtered.find((a) => a.available) ?? filtered[0];
      if (firstAvailable) setAgentId(firstAvailable.id);
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
