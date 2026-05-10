import { useState } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import { createProject } from "../lib/ipc";
import type { ProjectView } from "../lib/types";

export function NewProjectDialog({
  onClose,
  onCreated,
}: {
  onClose: () => void;
  onCreated: (view: ProjectView) => void;
}) {
  const [name, setName] = useState("");
  const [repoPath, setRepoPath] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  async function pickFolder() {
    const picked = await open({
      directory: true,
      multiple: false,
      title: "Choose project repository",
    });
    if (typeof picked === "string") {
      setRepoPath(picked);
      // Default the name to the basename of the chosen folder if blank.
      if (!name) {
        const base = picked.split("/").filter(Boolean).pop() ?? "";
        setName(base);
      }
    }
  }

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      const view = await createProject({
        name: name.trim(),
        repo_path: repoPath.trim(),
      });
      onCreated(view);
    } catch (err) {
      setError(String(err));
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <form className="new-session-form" onSubmit={submit}>
          <h3>New project</h3>
          <label>
            Repository
            <div className="folder-picker">
              <input
                value={repoPath}
                readOnly
                placeholder="(no folder selected)"
                onClick={pickFolder}
              />
              <button type="button" onClick={pickFolder}>
                Choose folder…
              </button>
            </div>
          </label>
          <label>
            Name
            <input
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="my-project"
              required
            />
          </label>
          {error && <div className="form-error">{error}</div>}
          <div className="modal-buttons">
            <button type="button" onClick={onClose}>
              Cancel
            </button>
            <button
              type="submit"
              className="primary"
              disabled={!name.trim() || !repoPath.trim() || submitting}
            >
              {submitting ? "Creating…" : "Create"}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
