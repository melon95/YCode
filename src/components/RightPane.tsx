import { useEffect } from "react";
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
  const setSelectedFilePath = useStore((s) => s.setSelectedFilePath);
  const activeProject = activeProjectId ? projects[activeProjectId] : null;
  const hasOpenFiles = openFiles.length > 0;

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
          return (
            <button
              key={path}
              type="button"
              className={"right-file-tab" + (active ? " active" : "")}
              onClick={() => showFile(path)}
              role="tab"
              aria-selected={active}
              title={path}
            >
              <span className="right-file-tab-name">{basename(path)}</span>
              {dirtyFiles[path] && <span className="right-file-tab-dirty">M</span>}
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
        {rightTab === "files" && !hasOpenFiles ? (
          activeProject ? (
            <FileTreePanel projectId={activeProject.id} />
          ) : (
            <div className="empty">Select a project first.</div>
          )
        ) : rightTab === "editor" ? (
          activeProject ? (
            hasOpenFiles ? (
              <div className="right-editor-workspace">
                <div className="right-editor-file-tree">
                  <FileTreePanel projectId={activeProject.id} />
                </div>
                <div className="right-editor-main">
                  <EditorPanel projectId={activeProject.id} />
                </div>
              </div>
            ) : (
              <EditorPanel projectId={activeProject.id} />
            )
          ) : (
            <div className="empty">Select a project first.</div>
          )
        ) : null}
        {activeProject ? (
          <div
            className={
              "manual-terminal-host" +
              (rightTab === "terminal" ? "" : " hidden")
            }
          >
            <ManualTerminal
              key={activeProject.id}
              cwd={activeProject.repo_path}
              visible={rightTab === "terminal"}
            />
          </div>
        ) : rightTab === "terminal" ? (
          <div className="empty">Select a project first.</div>
        ) : null}
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
