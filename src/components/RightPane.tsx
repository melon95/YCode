import { useEffect, useState } from "react";
import { useStore } from "../lib/store";
import { FileTreePanel } from "./FileTreePanel";
import { EditorPanel } from "./EditorPanel";
import { ManualTerminal } from "./ManualTerminal";

export function RightPane() {
  const projects = useStore((s) => s.projects);
  const activeProjectId = useStore((s) => s.activeProjectId);
  const rightTab = useStore((s) => s.rightTab);
  const setRightTab = useStore((s) => s.setRightTab);
  const openFiles = useStore((s) => s.openFiles);
  const selectedFilePath = useStore((s) => s.selectedFilePath);
  const dirtyFiles = useStore((s) => s.dirtyFiles);
  const previewFilePath = useStore((s) => s.previewFilePath);
  const openFile = useStore((s) => s.openFile);
  const setSelectedFilePath = useStore((s) => s.setSelectedFilePath);
  const activeProject = activeProjectId ? projects[activeProjectId] : null;
  const hasOpenFiles = openFiles.length > 0;

  // Set of project ids the user has touched this session. We mount one
  // ManualTerminal per visited project and only flip visibility on switch,
  // so a long-running shell (e.g. `npm run dev`) doesn't get killed just
  // because the user briefly tabbed to another project.
  const [visitedProjects, setVisitedProjects] = useState<Set<string>>(new Set());
  useEffect(() => {
    if (!activeProjectId) return;
    setVisitedProjects((prev) => {
      if (prev.has(activeProjectId)) return prev;
      const next = new Set(prev);
      next.add(activeProjectId);
      return next;
    });
  }, [activeProjectId]);

  // Drop a project from the visited set when it disappears from the store
  // (user deleted it). Its ManualTerminal unmounts and the shell gets killed.
  useEffect(() => {
    setVisitedProjects((prev) => {
      let changed = false;
      const next = new Set(prev);
      for (const id of prev) {
        if (!projects[id]) {
          next.delete(id);
          changed = true;
        }
      }
      return changed ? next : prev;
    });
  }, [projects]);

  useEffect(() => {
    if (!hasOpenFiles && rightTab === "editor") {
      setRightTab("files");
    }
  }, [hasOpenFiles, rightTab, setRightTab]);

  function showFile(path: string) {
    setSelectedFilePath(path);
    setRightTab("editor");
  }

  function closeOpenFile(path: string, e: React.MouseEvent) {
    e.stopPropagation();
    window.dispatchEvent(new CustomEvent("ycode:close-file", { detail: path }));
  }

  return (
    <section className="right-pane">
      <div className="right-pane-tabs" role="tablist" aria-label="Right pane views">
        <button
          type="button"
          className={"right-pane-tab" + (rightTab === "terminal" ? " active" : "")}
          onClick={() => setRightTab("terminal")}
          aria-label="Terminal"
          aria-selected={rightTab === "terminal"}
          role="tab"
          title="Terminal"
        >
          <TerminalIcon />
        </button>
        {!hasOpenFiles && (
          <button
            type="button"
            className={"right-pane-tab" + (rightTab === "files" ? " active" : "")}
            onClick={() => setRightTab("files")}
            aria-label="Files"
            aria-selected={rightTab === "files"}
            role="tab"
            title="Files"
          >
            <FilesIcon />
          </button>
        )}
        {openFiles.length > 0 && <div className="right-pane-tab-separator" />}
        {openFiles.map((path) => {
          const active = rightTab === "editor" && path === selectedFilePath;
          const isPreview = path === previewFilePath;
          return (
            <button
              key={path}
              type="button"
              className={
                "right-file-tab" +
                (active ? " active" : "") +
                (isPreview ? " preview" : "")
              }
              onClick={() => showFile(path)}
              // Double-click pins a preview tab — same semantics as the
              // file tree double-click.
              onDoubleClick={() => {
                if (isPreview) openFile(path, { preview: false });
              }}
              role="tab"
              aria-selected={active}
              title={isPreview ? `${path} (preview — double-click to pin)` : path}
            >
              <span className="right-file-tab-name">{basename(path)}</span>
              {dirtyFiles[path] && (
                <span className="right-file-tab-dirty" aria-label="unsaved">
                  M
                </span>
              )}
              <span
                className="right-file-tab-close"
                onClick={(e) => closeOpenFile(path, e)}
                aria-label={`Close ${basename(path)}`}
                role="button"
              >
                ×
              </span>
            </button>
          );
        })}
      </div>
      <div className="right-pane-body">
        {(() => {
          const workspaceVisible =
            !!activeProject &&
            ((rightTab === "files" && !hasOpenFiles) ||
              (rightTab === "editor" && hasOpenFiles && !!selectedFilePath));
          const editorVisible =
            !!activeProject &&
            rightTab === "editor" &&
            hasOpenFiles &&
            !!selectedFilePath;
          return (
            <div
              className={
                "right-editor-workspace" +
                (workspaceVisible ? "" : " hidden") +
                (editorVisible ? " with-editor" : " tree-only")
              }
            >
              {/* One FileTreePanel per visited project. Switching projects
                  flips `.hidden`, so the new tree doesn't pay listFiles +
                  react-arborist + SVG-icon-fetch on every switch. */}
              <div className="right-editor-file-tree">
                {Array.from(visitedProjects).map((pid) => {
                  if (!projects[pid]) return null;
                  const isActive = pid === activeProject?.id;
                  return (
                    <div
                      key={pid}
                      className={"file-tree-host" + (isActive ? "" : " hidden")}
                    >
                      <FileTreePanel projectId={pid} />
                    </div>
                  );
                })}
              </div>
              {/* Editor follows the active project's openFiles (a global
                  store slice cleared on project switch). One instance is
                  enough — the heavy work is the file tree, not the editor. */}
              {hasOpenFiles && activeProject && (
                <div
                  className={
                    "right-editor-main" + (editorVisible ? "" : " hidden")
                  }
                >
                  <EditorPanel projectId={activeProject.id} />
                </div>
              )}
            </div>
          );
        })()}
        {!activeProject && rightTab !== "terminal" && (
          <div className="empty">Select a project first.</div>
        )}
        {rightTab === "editor" &&
          activeProject &&
          hasOpenFiles &&
          !selectedFilePath && (
            <div className="empty">
              Pick a file from the <strong>Files</strong> tab.
            </div>
          )}
        {!activeProject && rightTab === "terminal" && (
          <div className="empty">Select a project first.</div>
        )}
        {/* One ManualTerminal per visited project, stacked + hidden via
            display:none for the inactive ones. Switching projects flips
            visibility instead of unmounting, so each project's shell keeps
            running in the background. */}
        {Array.from(visitedProjects).map((pid) => {
          const proj = projects[pid];
          if (!proj) return null;
          const isActiveProject = pid === activeProject?.id;
          const visible = isActiveProject && rightTab === "terminal";
          return (
            <div
              key={pid}
              className={"manual-terminal-host" + (visible ? "" : " hidden")}
            >
              <ManualTerminal cwd={proj.repo_path} visible={visible} />
            </div>
          );
        })}
      </div>
    </section>
  );
}

function basename(path: string): string {
  const idx = path.lastIndexOf("/");
  return idx >= 0 ? path.slice(idx + 1) : path;
}

function FilesIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="20"
      height="20"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <path d="M4 4h6l2 2h8v14H4z" />
      <path d="M4 9h16" />
    </svg>
  );
}

function TerminalIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="20"
      height="20"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <path d="M4 5h16v14H4z" />
      <path d="M8 9l3 3-3 3" />
      <path d="M13 16h4" />
    </svg>
  );
}
