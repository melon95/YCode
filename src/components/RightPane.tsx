import { useCallback, useEffect, useRef, useState } from "react";
import { displaySessionTitle, useStore, type RightTab } from "../lib/store";
import type { SessionView } from "../lib/types";
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
import { PanelCard } from "./ui/PanelCard";
import { IconButton } from "./ui/IconButton";
import { WorkspaceTargetPicker } from "./WorkspaceTargetPicker";

export function RightPane() {
  const projects = useStore((s) => s.projects);
  const sessions = useStore((s) => s.sessions);
  const workspaceSessionByProject = useStore(
    (s) => s.workspaceSessionByProject,
  );
  const activeProjectId = useStore((s) => s.activeProjectId);
  const rightTab = useStore((s) => s.rightTab);
  const openPanels = useStore((s) => s.openPanels);
  const togglePanelOpen = useStore((s) => s.togglePanelOpen);
  // Which card, if any, is filling the stack. Local rather than persisted:
  // maximising is a momentary "let me look at this properly", not a layout
  // preference worth restoring on the next launch.
  const [solo, setSolo] = useState<RightTab | null>(null);
  const isOpen = (tab: RightTab) => openPanels.includes(tab);
  const setRightTab = useStore((s) => s.setRightTab);
  const openFiles = useStore((s) => s.openFiles);
  const selectedFilePath = useStore((s) => s.selectedFilePath);
  const dirtyFiles = useStore((s) => s.dirtyFiles);
  const previewFilePath = useStore((s) => s.previewFilePath);
  const openFile = useStore((s) => s.openFile);
  const setSelectedFilePath = useStore((s) => s.setSelectedFilePath);
  const activeProject = activeProjectId ? projects[activeProjectId] : null;
  const hasOpenFiles = openFiles.length > 0;
  const activeWorkspaceSession = activeProject
    ? workspaceSession(
        activeProject.id,
        workspaceSessionByProject[activeProject.id],
        sessions,
      )
    : null;
  const activeWorkspaceSessionId = activeWorkspaceSession?.id;
  const activeWorkspaceRoot =
    activeWorkspaceSession?.worktree_path ?? activeProject?.repo_path;
  const activeWorkspaceKey = activeProject
    ? `${activeProject.id}:${activeWorkspaceSessionId ?? "main"}`
    : "none";

  // —— 变更面板的绑定目标 ——
  // 预览稿行为(bindChanges):中栏聚焦哪个 pane,变更卡片就展示哪个会话
  // 的 diff。优先级:锁定 > 焦点会话(activeId,须属于当前项目)> 右栏
  // target picker 的手选(workspaceSessionByProject)。锁定后停止跟随,
  // 固定在锁定那一刻解析出的目标。
  const activeId = useStore((s) => s.activeId);
  const liveTitles = useStore((s) => s.liveTitles);
  // 锁定是"看一会儿这个会话的 diff"的临时动作,放本地 state、不持久化。
  // 记下项目 id:切到别的项目后锁定自然失效(该项目里恢复跟随/手选)。
  // sessionId 为 null 表示锁定在主仓库。
  const [changesLock, setChangesLock] = useState<{
    projectId: string;
    sessionId: string | null;
  } | null>(null);

  // 焦点会话:必须存在且属于当前项目才可跟随。
  const focusSession =
    activeId && activeProject && sessions[activeId]?.project_id === activeProject.id
      ? sessions[activeId]
      : null;

  // 锁定是否仍然有效:同一项目,且(若指向会话)该会话行还在。会话被
  // 删除/归档后锁定失效,自动回到跟随逻辑,而不是停在一个空目标上。
  const validLock =
    changesLock &&
    activeProject &&
    changesLock.projectId === activeProject.id &&
    (changesLock.sessionId === null || sessions[changesLock.sessionId])
      ? changesLock
      : null;
  const changesLockValid = validLock !== null;

  // 最终绑定的会话(null = 主仓库)。跟随焦点时,无 worktree 的共享会话
  // 也算合法目标 —— 它的 diff 就是主仓库的 diff。
  const changesSession = validLock
    ? validLock.sessionId
      ? sessions[validLock.sessionId]
      : null
    : (focusSession ?? activeWorkspaceSession);
  // 只有 worktree 会话才把 sessionId 传给 ChangesPanel(它以此定位隔离
  // 工作树);共享会话与主仓库都走 undefined。
  const changesSessionId = changesSession?.worktree_path
    ? changesSession.id
    : undefined;
  const changesKey = activeProject
    ? `${activeProject.id}:${changesSessionId ?? "main"}`
    : "none";

  // chip 文字如实反映当前跟随的目标:worktree 会话显示其分支,否则显示
  // 主仓库;tooltip 里补充来源(锁定 / 跟随焦点 / 手选)与会话标题。
  const changesBindLabel = changesSession?.worktree_path
    ? (changesSession.branch ?? changesSession.base_branch ?? "worktree")
    : "主仓库";
  const changesBindTitle = changesLockValid
    ? changesSession
      ? `已锁定:${displaySessionTitle(changesSession, liveTitles)}`
      : "已锁定:主仓库"
    : focusSession
      ? `跟随焦点会话:${displaySessionTitle(focusSession, liveTitles)}`
      : changesSession
        ? `手选目标:${displaySessionTitle(changesSession, liveTitles)}`
        : "主仓库";

  const toggleChangesLock = useCallback(() => {
    if (!activeProject) return;
    setChangesLock((cur) =>
      cur && cur.projectId === activeProject.id
        ? null
        : // 锁定捕获"此刻"解析出的目标,而不是持续引用跟随逻辑。
          {
            projectId: activeProject.id,
            sessionId: changesSession?.id ?? null,
          },
    );
  }, [activeProject, changesSession]);

  // —— 卡片头计数 ——
  // diff 文件数由 ChangesPanel 经 onFileCount 上报进 store(画布工具条
  // 角标共用);面板关闭/无项目时清空,避免角标挂着过期数字。
  const changesFileCount = useStore((s) => s.changesFileCount);
  const setChangesFileCount = useStore((s) => s.setChangesFileCount);
  const changesMounted = !!activeProject && isOpen("changes");
  useEffect(() => {
    if (!changesMounted) setChangesFileCount(null);
  }, [changesMounted, setChangesFileCount]);

  // 未完成(非 done)todo 数,数据源与工具条角标一致(store.todos)。
  const todosByProject = useStore((s) => s.todos);
  const openTodoCount = activeProject
    ? (todosByProject[activeProject.id] ?? []).filter(
        (t) => t.status !== "done",
      ).length
    : 0;

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
      {/* Panel switching moved to the canvas toolbar (see CanvasToolbar) —
          the strip here now only carries open editor files, which are a
          different axis: *which file*, not *which panel*. With no files open
          it isn't rendered at all, rather than leaving an empty band. */}
      {openFiles.length > 0 && (
      <div className="right-pane-tabs" role="tablist" aria-label="Open files">
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
                (isPreview ? " preview" : "") +
                (openFiles.length === 1 ? " single" : "")
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
      )}
      <div className="right-pane-body panel-stack">
        <PanelCard
          title="文件"
          // Static label rather than the picker: one editable copy of the
          // control (in the terminal card) is enough — three would just be
          // three ways to set the same value.
          bind={
            <>
              <BindArrow />
              <span className="mono">
                {/* checked-out 的分支,不是 base_branch —— 与变更卡一致。 */}
                {activeWorkspaceSession?.worktree_path
                  ? (activeWorkspaceSession.branch ??
                    activeWorkspaceSession.base_branch ??
                    "worktree")
                  : "主仓库"}
              </span>
            </>
          }
          open={isOpen("files") || isOpen("editor")}
          solo={solo === "files"}
          onToggleSolo={() => setSolo(solo === "files" ? null : "files")}
          onClose={() => {
            togglePanelOpen("files");
            if (isOpen("editor")) togglePanelOpen("editor");
          }}
        >
        {(() => {
          const workspaceVisible =
            !!activeProject &&
            ((rightTab === "files" && !hasOpenFiles) ||
              (rightTab === "editor" && hasOpenFiles && !!selectedFilePath) ||
              // In the stacked layout the card itself decides visibility, so
              // the inner surface stays shown whenever the card is open.
              isOpen("files") ||
              isOpen("editor"));
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
                  const project = projects[pid];
                  if (!project) return null;
                  const isActive = pid === activeProject?.id;
                  const targetSession = workspaceSession(
                    pid,
                    workspaceSessionByProject[pid],
                    sessions,
                  );
                  const targetSessionId = targetSession?.id;
                  const targetRoot =
                    targetSession?.worktree_path ?? project.repo_path;
                  return (
                    <div
                      key={pid}
                      className={"file-tree-host" + (isActive ? "" : " hidden")}
                    >
                      <FileTreePanel
                        key={`${pid}:${targetSessionId ?? "main"}`}
                        projectId={pid}
                        sessionId={targetSessionId}
                        rootPath={targetRoot}
                      />
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
                  <EditorPanel
                    key={activeWorkspaceKey}
                    projectId={activeProject.id}
                    sessionId={activeWorkspaceSessionId}
                    rootPath={activeWorkspaceRoot}
                  />
                </div>
              )}
            </div>
          );
        })()}
        {!activeProject && (
          <div className="empty">Select a project first.</div>
        )}
        </PanelCard>

        <PanelCard
          title="变更"
          open={isOpen("changes")}
          // 绑定 chip 如实反映当前跟随/锁定的目标(见上方解析逻辑)。
          bind={
            <>
              <BindArrow />
              <span className="mono" title={changesBindTitle}>
                {changesBindLabel}
              </span>
            </>
          }
          // 预览稿的「3 个文件」计数;仅在面板挂载、数字可信时显示。
          count={
            changesFileCount != null ? `${changesFileCount} 个文件` : undefined
          }
          // 预览稿的 #chg-pin:锁定后停止跟随焦点,固定在锁定那一刻的目标。
          actions={
            <IconButton
              size="sm"
              active={changesLockValid}
              onClick={toggleChangesLock}
              disabled={!activeProject}
              title={
                changesLockValid
                  ? "已锁定 · 点击恢复跟随焦点"
                  : "锁定到当前会话(不跟随焦点)"
              }
              aria-label={
                changesLockValid ? "解除锁定,恢复跟随焦点" : "锁定到当前会话"
              }
            >
              <PinIcon />
            </IconButton>
          }
          solo={solo === "changes"}
          onToggleSolo={() => setSolo(solo === "changes" ? null : "changes")}
          onClose={() => togglePanelOpen("changes")}
        >
          {activeProject && isOpen("changes") && (
            // Key by project so switching projects remounts the panel: its branch
            // menu, remote-op flags, and any in-flight git requests all belong to
            // one repo and must not leak into the next (a stale checkout would run
            // against the wrong repo otherwise).
            <ChangesPanel
              key={changesKey}
              projectId={activeProject.id}
              sessionId={changesSessionId}
              baseBranch={changesSession?.base_branch ?? undefined}
              onFileCount={setChangesFileCount}
            />
          )}
        </PanelCard>

        <PanelCard
          title="待办"
          open={isOpen("todos")}
          // 未完成 todo 数,与画布工具条的角标同源(store.todos)。
          count={openTodoCount > 0 ? openTodoCount : undefined}
          solo={solo === "todos"}
          onToggleSolo={() => setSolo(solo === "todos" ? null : "todos")}
          onClose={() => togglePanelOpen("todos")}
        >
          {activeProject && isOpen("todos") && (
            <TodoPanel projectId={activeProject.id} />
          )}
        </PanelCard>
        <PanelCard
          title="终端"
          open={isOpen("terminal")}
          // The binding label *is* the control: this is where you both see
          // and change which checkout the right column's tools point at.
          bind={
            activeProject ? (
              <WorkspaceTargetPicker projectId={activeProject.id} />
            ) : undefined
          }
          solo={solo === "terminal"}
          onToggleSolo={() => setSolo(solo === "terminal" ? null : "terminal")}
          onClose={() => togglePanelOpen("terminal")}
        >
        {/* One split tree per visited project, stacked + hidden via
            display:none for the inactive ones. Switching projects flips
            visibility instead of unmounting, so every pane's shell keeps
            running in the background. */}
        {Array.from(visitedProjects).map((pid) => {
          const proj = projects[pid];
          const state = splitStates[pid];
          if (!proj || !state) return null;
          const isActiveProject = pid === activeProject?.id;
          // Visibility now follows the card, not the old single-tab state:
          // with a stacked layout the terminal can be on screen alongside
          // Files, and xterm needs `visible` to be true to fit + repaint.
          const visible = isActiveProject && isOpen("terminal");
          const targetSession = workspaceSession(
            pid,
            workspaceSessionByProject[pid],
            sessions,
          );
          const targetSessionId = targetSession?.id;
          const targetRoot = targetSession?.worktree_path ?? proj.repo_path;
          return (
            <div
              key={pid}
              className={"manual-terminal-host" + (visible ? "" : " hidden")}
            >
              <RightTerminalSplit
                key={`${pid}:${targetSessionId ?? "main"}`}
                tree={state.tree}
                cwd={targetRoot}
                projectId={pid}
                sessionId={targetSessionId}
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
        </PanelCard>
      </div>
    </section>
  );
}

/// 变更卡片「锁定到当前会话」按钮的图钉图标(与预览稿 #chg-pin 同形)。
function PinIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round">
      <path d="M12 17v5" />
      <path d="M9 10.8V4h6v6.8a2 2 0 0 0 .6 1.4l1.4 1.4V17H7v-3.4l1.4-1.4a2 2 0 0 0 .6-1.4z" />
    </svg>
  );
}

/// The little arrow that prefixes a panel's binding label.
function BindArrow() {
  return (
    <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round">
      <path d="M5 12h14" />
      <path d="m13 6 6 6-6 6" />
    </svg>
  );
}

function workspaceSession(
  projectId: string,
  requestedSessionId: string | null | undefined,
  sessions: Record<string, SessionView>,
): SessionView | null {
  if (!requestedSessionId) return null;
  const session = sessions[requestedSessionId];
  if (
    !session ||
    session.project_id !== projectId ||
    !session.worktree_path
  ) {
    return null;
  }
  return session;
}

function basename(path: string): string {
  const idx = path.lastIndexOf("/");
  return idx >= 0 ? path.slice(idx + 1) : path;
}




