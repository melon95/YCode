import { useCallback, useEffect, useRef, useState } from "react";
import { useStore } from "../lib/store";
import { FileTreePanel } from "./FileTreePanel";
import { EditorPanel } from "./EditorPanel";
import { ChangesPanel } from "./ChangesPanel";
import { TodoPanel } from "./TodoPanel";
import {
  RightTerminalSplit,
  closePane,
  newSplitState,
  splitPane,
  updateRatio,
  type ProjectSplitState,
  type SplitDirection,
  type SplitPath,
} from "./RightTerminalSplit";

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

  // File-tree column width, in pixels. Only consulted in the `with-editor`
  // workspace mode — tree-only mode keeps the existing `1fr` rule from CSS.
  // Persisted across reloads via localStorage; defaults to a sane 280px
  // (the previous static 32% looked about right at the most common right-
  // pane width). Min 180px matches the prior CSS minmax floor; the 600px
  // ceiling keeps the editor from collapsing on a narrow window.
  const FILE_TREE_MIN = 180;
  const FILE_TREE_MAX = 600;
  const FILE_TREE_STORAGE_KEY = "ycode-file-tree-width";
  const [fileTreeWidth, setFileTreeWidth] = useState<number>(() => {
    if (typeof window === "undefined") return 280;
    const raw = window.localStorage.getItem(FILE_TREE_STORAGE_KEY);
    const n = raw ? parseInt(raw, 10) : NaN;
    if (!Number.isFinite(n)) return 280;
    return Math.min(FILE_TREE_MAX, Math.max(FILE_TREE_MIN, n));
  });
  useEffect(() => {
    if (typeof window === "undefined") return;
    try {
      window.localStorage.setItem(FILE_TREE_STORAGE_KEY, String(fileTreeWidth));
    } catch {
      /* quota / privacy mode — best effort */
    }
  }, [fileTreeWidth]);

  const [resizing, setResizing] = useState(false);
  // Drag start snapshot. Captured on pointerdown; consumed by the
  // pointermove effect below. A ref (not state) so updating it during a
  // drag doesn't trigger re-renders.
  const dragStartRef = useRef<{ x: number; w: number } | null>(null);
  const onResizerPointerDown = useCallback(
    (e: React.PointerEvent<HTMLDivElement>) => {
      // Only the primary mouse button / single touch. Right-clicks shouldn't
      // start a resize.
      if (e.button !== 0) return;
      e.preventDefault();
      dragStartRef.current = { x: e.clientX, w: fileTreeWidth };
      setResizing(true);
    },
    [fileTreeWidth],
  );

  // Drag-lifecycle effect. Listeners and body-style locks are owned by an
  // effect (rather than installed inline on pointerdown) so that an unmount
  // mid-drag — possible if the active project disappears while the user is
  // holding the handle — still tears them down via the cleanup. Keying off
  // `resizing` makes start/stop symmetric.
  useEffect(() => {
    if (!resizing) return;
    const onMove = (ev: PointerEvent) => {
      const start = dragStartRef.current;
      if (!start) return;
      const dx = ev.clientX - start.x;
      setFileTreeWidth(
        Math.min(FILE_TREE_MAX, Math.max(FILE_TREE_MIN, start.w + dx)),
      );
    };
    const onUp = () => setResizing(false);
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
    // Keep the cursor steady and prevent text selection during the drag,
    // even when the pointer strays off the 1px handle into adjacent panes.
    const prevCursor = document.body.style.cursor;
    const prevUserSelect = document.body.style.userSelect;
    document.body.style.cursor = "col-resize";
    document.body.style.userSelect = "none";
    return () => {
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
      document.body.style.cursor = prevCursor;
      document.body.style.userSelect = prevUserSelect;
      dragStartRef.current = null;
    };
  }, [resizing]);

  // Set of project ids the user has touched this session. We mount one
  // terminal subtree per visited project and only flip visibility on switch,
  // so long-running shells (e.g. `npm run dev`) don't get killed just
  // because the user briefly tabbed to another project.
  const [visitedProjects, setVisitedProjects] = useState<Set<string>>(new Set());
  // Per-project split tree for the right-pane terminal. In-memory only —
  // reloading the app reverts every project to a single pane. Keyed by
  // project id so switching projects preserves each one's layout.
  const [splitStates, setSplitStates] = useState<
    Record<string, ProjectSplitState>
  >({});
  useEffect(() => {
    if (!activeProjectId) return;
    setVisitedProjects((prev) => {
      if (prev.has(activeProjectId)) return prev;
      const next = new Set(prev);
      next.add(activeProjectId);
      return next;
    });
  }, [activeProjectId]);

  // Drop a project from the visited set + split state when it disappears
  // from the store (user deleted it). Its terminals unmount, shells die.
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
    setSplitStates((prev) => {
      let changed = false;
      const next = { ...prev };
      for (const id of Object.keys(prev)) {
        if (!projects[id]) {
          delete next[id];
          changed = true;
        }
      }
      return changed ? next : prev;
    });
  }, [projects]);

  // Make sure every visited project has a split state. Visited set is
  // updated first; this effect fills the matching split entry on the next
  // render pass.
  useEffect(() => {
    setSplitStates((prev) => {
      let changed = false;
      const next = { ...prev };
      for (const pid of visitedProjects) {
        if (!next[pid]) {
          next[pid] = newSplitState();
          changed = true;
        }
      }
      return changed ? next : prev;
    });
  }, [visitedProjects]);

  const handleSplit = useCallback(
    (pid: string, paneId: string, direction: SplitDirection) => {
      setSplitStates((prev) => {
        const cur = prev[pid];
        if (!cur) return prev;
        return { ...prev, [pid]: splitPane(cur, paneId, direction) };
      });
    },
    [],
  );

  const handleClosePane = useCallback((pid: string, paneId: string) => {
    setSplitStates((prev) => {
      const cur = prev[pid];
      if (!cur) return prev;
      return { ...prev, [pid]: closePane(cur, paneId) };
    });
  }, []);

  const handleUpdateRatio = useCallback(
    (pid: string, path: SplitPath, ratio: number) => {
      setSplitStates((prev) => {
        const cur = prev[pid];
        if (!cur) return prev;
        return { ...prev, [pid]: updateRatio(cur, path, ratio) };
      });
    },
    [],
  );

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
        <button
          type="button"
          className={"right-pane-tab" + (rightTab === "changes" ? " active" : "")}
          onClick={() => setRightTab("changes")}
          aria-label="Changes"
          aria-selected={rightTab === "changes"}
          role="tab"
          title="Changes"
        >
          <ChangesIcon />
        </button>
        <button
          type="button"
          className={"right-pane-tab" + (rightTab === "todos" ? " active" : "")}
          onClick={() => setRightTab("todos")}
          aria-label="Todos"
          aria-selected={rightTab === "todos"}
          role="tab"
          title="Todos"
        >
          <TodosIcon />
        </button>
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
              style={
                editorVisible
                  ? {
                      // 3-column grid only in editor mode: tree | 1px handle |
                      // editor. `.tree-only`'s `1fr` from the stylesheet wins
                      // for the tree-only case (no inline style applied).
                      gridTemplateColumns: `${fileTreeWidth}px 1px minmax(0, 1fr)`,
                    }
                  : undefined
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
              {/* Drag handle. Lives between tree and editor in the grid;
                  the hit area is widened in CSS via a pseudo-element so the
                  user doesn't need pixel-perfect aim. */}
              {editorVisible && (
                <div
                  className={
                    "file-tree-resizer" + (resizing ? " dragging" : "")
                  }
                  role="separator"
                  aria-orientation="vertical"
                  aria-label="Resize file tree"
                  onPointerDown={onResizerPointerDown}
                />
              )}
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
        {rightTab === "changes" && activeProject && (
          <ChangesPanel projectId={activeProject.id} />
        )}
        {rightTab === "todos" && activeProject && (
          <TodoPanel projectId={activeProject.id} />
        )}
        {/* One split tree per visited project, stacked + hidden via
            display:none for the inactive ones. Switching projects flips
            visibility instead of unmounting, so every pane's shell keeps
            running in the background. */}
        {Array.from(visitedProjects).map((pid) => {
          const proj = projects[pid];
          const state = splitStates[pid];
          if (!proj || !state) return null;
          const isActiveProject = pid === activeProject?.id;
          const visible = isActiveProject && rightTab === "terminal";
          return (
            <div
              key={pid}
              className={"manual-terminal-host" + (visible ? "" : " hidden")}
            >
              <RightTerminalSplit
                tree={state.tree}
                cwd={proj.repo_path}
                projectId={pid}
                visible={visible}
                onSplit={(paneId, direction) =>
                  handleSplit(pid, paneId, direction)
                }
                onClose={(paneId) => handleClosePane(pid, paneId)}
                onUpdateRatio={(path, ratio) =>
                  handleUpdateRatio(pid, path, ratio)
                }
              />
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

function ChangesIcon() {
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
      <circle cx="6" cy="6" r="2.5" />
      <circle cx="6" cy="18" r="2.5" />
      <circle cx="18" cy="12" r="2.5" />
      <path d="M6 8.5v7" />
      <path d="M8.5 6h4.5a3 3 0 0 1 3 3v.5" />
    </svg>
  );
}

function TodosIcon() {
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
      <path d="M9 6h11" />
      <path d="M9 12h11" />
      <path d="M9 18h11" />
      <path d="M4 6l1 1 1.5-1.5" />
      <path d="M4 12l1 1 1.5-1.5" />
      <path d="M4 17.5h1.5" />
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
