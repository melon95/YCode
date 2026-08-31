import { useEffect, useMemo, useRef, useState } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import { Popover } from "@base-ui/react/popover";
import { toast } from "@heroui/react";
import { createProject, deleteProject, gitBranch } from "../lib/ipc";
import { captureProjectUiSnapshot, useStore } from "../lib/store";
import {
  projectActivity,
  type ProjectActivity,
  type ProjectView,
  type SessionLight,
  type SessionView,
} from "../lib/types";
import { confirmDialog } from "../lib/confirm";
import { openProjectInNewWindow } from "../lib/multiWindow";
import { statusFromLight } from "../lib/sessionStatus";
import { StatusDot } from "./ui/StatusDot";
import { AttentionInbox } from "./AttentionInbox";
import { ContextMenu, type ContextMenuItem } from "./ContextMenu";

/// How close to the window's top edge the pointer has to get before the
/// auto-hidden bar slides back in. Deliberately larger than the visible
/// 4px sliver so the reveal feels reachable rather than pixel-hunted.
const TOPBAR_REVEAL_ZONE_PX = 6;

/// How long the bar stays peeked open after a keyboard project switch. Long
/// enough to read the newly-active tab, short enough not to linger over the
/// terminal you're typing into.
const TOPBAR_PEEK_MS = 1200;

export function TopBar({
  settingsActive = false,
  overviewActive = false,
}: {
  settingsActive?: boolean;
  /// 项目总览打开时隐藏项目 tab 条(它是跨项目界面,顶着某个项目的 tab
  /// 会造成语境误导),但搜索 / 收件箱 / 设置保持可达。
  overviewActive?: boolean;
}) {
  const [creatingProject, setCreatingProject] = useState(false);
  const [menu, setMenu] = useState<{
    x: number;
    y: number;
    items: ContextMenuItem[];
  } | null>(null);
  const upsertProject = useStore((s) => s.upsertProject);
  const setActiveProjectId = useStore((s) => s.setActiveProjectId);
  const removeProject = useStore((s) => s.removeProject);
  const moveProject = useStore((s) => s.moveProject);
  const activeProjectId = useStore((s) => s.activeProjectId);
  const projects = useStore((s) => s.projects);
  const projectOrder = useStore((s) => s.projectOrder);
  const lockedProjectId = useStore((s) => s.lockedProjectId);
  const lockedByOtherWindows = useStore((s) => s.lockedByOtherWindows);
  const sessions = useStore((s) => s.sessions);
  const activityBySession = useStore((s) => s.activityBySession);
  const autoHideTopBar = useStore((s) => s.autoHideTopBar);
  const [revealed, setRevealed] = useState(false);
  const [peeking, setPeeking] = useState(false);
  const detached = lockedProjectId !== null;
  const [draggedProjectId, setDraggedProjectId] = useState<string | null>(null);
  const [projectDrop, setProjectDrop] = useState<{
    id: string;
    edge: "before" | "after";
  } | null>(null);
  const projectDragRef = useRef<{
    id: string;
    pointerId: number;
    startX: number;
    startY: number;
    active: boolean;
  } | null>(null);
  const projectDropRef = useRef<typeof projectDrop>(null);
  const suppressProjectClickRef = useRef(false);

  // Per-project agent-activity rollup, so each tab shows a status dot telling
  // you whether that project's agents are still working or have all finished.
  const activityByProject = useMemo(() => {
    const byProject: Record<string, SessionView[]> = {};
    for (const s of Object.values(sessions)) {
      (byProject[s.project_id] ??= []).push(s);
    }
    const out: Record<string, ProjectActivity | null> = {};
    for (const [pid, list] of Object.entries(byProject)) {
      out[pid] = projectActivity(list, activityBySession);
    }
    return out;
  }, [sessions, activityBySession]);

  // Pointer-driven reveal for the auto-hide mode. Tracked on `window` rather
  // than the header's own mouseenter, because the collapsed bar is a 4px
  // sliver — too small to reliably enter — and because the pointer has to be
  // able to *leave* through the workspace below and re-hide the bar.
  const headerRef = useRef<HTMLElement | null>(null);
  useEffect(() => {
    if (!autoHideTopBar) {
      setRevealed(false);
      return;
    }
    const onMove = (e: PointerEvent) => {
      if (e.clientY <= TOPBAR_REVEAL_ZONE_PX) {
        setRevealed(true);
        return;
      }
      // Once open, the bar stays open for as long as the pointer is inside
      // it — otherwise the tabs would slide away the moment the user moved
      // down to click one.
      const rect = headerRef.current?.getBoundingClientRect();
      setRevealed(
        !!rect &&
          e.clientY <= rect.bottom &&
          e.clientX >= rect.left &&
          e.clientX <= rect.right,
      );
    };
    // The window losing the pointer entirely (moving into another app, or
    // over a native menu) should settle the bar back to hidden.
    const onLeave = () => setRevealed(false);
    window.addEventListener("pointermove", onMove);
    document.addEventListener("pointerleave", onLeave);
    window.addEventListener("blur", onLeave);
    return () => {
      window.removeEventListener("pointermove", onMove);
      document.removeEventListener("pointerleave", onLeave);
      window.removeEventListener("blur", onLeave);
    };
  }, [autoHideTopBar]);

  // Keyboard project switching (⇧⌘[ / ⇧⌘]) briefly peeks the bar, so a blind
  // switch still shows which project you landed on. Without this the only
  // other on-screen project label is the sidebar's, which ⌘B can collapse —
  // leaving the switch with no feedback at all.
  useEffect(() => {
    if (!autoHideTopBar) return;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const onPeek = () => {
      setPeeking(true);
      clearTimeout(timer);
      timer = setTimeout(() => setPeeking(false), TOPBAR_PEEK_MS);
    };
    window.addEventListener("ycode:peek-topbar", onPeek);
    return () => {
      window.removeEventListener("ycode:peek-topbar", onPeek);
      clearTimeout(timer);
      setPeeking(false);
    };
  }, [autoHideTopBar]);

  const [switcherOpen, setSwitcherOpen] = useState(false);

  // Interactions started from the bar must pin it open: the folder picker
  // and the context menu both move the pointer off the header, which would
  // otherwise collapse the bar out from under the gesture.
  const pinned =
    creatingProject || menu !== null || draggedProjectId !== null || switcherOpen;
  const hidden = autoHideTopBar && !revealed && !pinned && !peeking;

  // Listen for global hotkeys dispatched from `useHotkeys`.
  useEffect(() => {
    const onNewProject = () => {
      if (!detached) void onAddProject();
    };
    window.addEventListener("ycode:new-project", onNewProject);
    return () => {
      window.removeEventListener("ycode:new-project", onNewProject);
    };
  }, [detached, creatingProject]);

  // In a detached window only the locked project shows. In the main window
  // peers' projects are hidden so the same id never appears twice.
  const projectList = useMemo(() => {
    const orderById = new Map(projectOrder.map((id, index) => [id, index]));
    const all = Object.values(projects).slice().sort((a, b) => {
      const aOrder = orderById.get(a.id) ?? Number.MAX_SAFE_INTEGER;
      const bOrder = orderById.get(b.id) ?? Number.MAX_SAFE_INTEGER;
      return aOrder - bOrder || a.created_at_ms - b.created_at_ms;
    });
    if (lockedProjectId) return all.filter((p) => p.id === lockedProjectId);
    return all.filter((p) => !lockedByOtherWindows[p.id]);
  }, [projects, projectOrder, lockedProjectId, lockedByOtherWindows]);

  function clearProjectDrag() {
    projectDragRef.current = null;
    projectDropRef.current = null;
    setDraggedProjectId(null);
    setProjectDrop(null);
  }

  function onProjectPointerMove(e: React.PointerEvent<HTMLDivElement>) {
    const drag = projectDragRef.current;
    if (!drag || drag.pointerId !== e.pointerId) return;
    if (!drag.active) {
      if (Math.hypot(e.clientX - drag.startX, e.clientY - drag.startY) < 4) return;
      drag.active = true;
      setDraggedProjectId(drag.id);
    }
    e.preventDefault();

    const target = document
      .elementFromPoint(e.clientX, e.clientY)
      ?.closest<HTMLElement>(".project-tab");
    const targetId = target?.dataset.projectId;
    if (!target || !targetId || targetId === drag.id) {
      projectDropRef.current = null;
      setProjectDrop(null);
      return;
    }
    const rect = target.getBoundingClientRect();
    const edge = e.clientX < rect.left + rect.width / 2 ? "before" : "after";
    const next = { id: targetId, edge } as const;
    const current = projectDropRef.current;
    if (current?.id !== next.id || current.edge !== next.edge) {
      projectDropRef.current = next;
      setProjectDrop(next);
    }
  }

  function onProjectPointerEnd(e: React.PointerEvent<HTMLDivElement>) {
    const drag = projectDragRef.current;
    if (!drag || drag.pointerId !== e.pointerId) return;
    const drop = projectDropRef.current;
    if (drag.active) {
      suppressProjectClickRef.current = true;
      requestAnimationFrame(() => {
        suppressProjectClickRef.current = false;
      });
    }
    clearProjectDrag();
    if (drag.active && drop) moveProject(drag.id, drop.id, drop.edge);
  }

  function onProjectPointerCancel(e: React.PointerEvent<HTMLDivElement>) {
    const drag = projectDragRef.current;
    if (!drag || drag.pointerId !== e.pointerId) return;
    clearProjectDrag();
  }

  async function onAddProject() {
    if (creatingProject) return;
    setCreatingProject(true);
    try {
      const picked = await open({
        directory: true,
        multiple: false,
        title: "选择项目仓库目录",
      });
      if (typeof picked !== "string") return; // user cancelled
      const name = picked.split("/").filter(Boolean).pop() ?? picked;
      const view = await createProject({ name, repo_path: picked });
      upsertProject(view);
      setActiveProjectId(view.id);
    } catch (err) {
      toast.danger(`创建项目失败:${err}`);
    } finally {
      setCreatingProject(false);
    }
  }

  async function onDeleteProject(p: ProjectView) {
    const ok = await confirmDialog({
      title: `删除项目「${p.name}」?`,
      message: "有活跃会话时无法删除;已归档的会话会保留,但会失去项目关联。",
      confirmLabel: "删除",
      destructive: true,
    });
    if (!ok) return;
    try {
      await deleteProject(p.id);
      removeProject(p.id);
    } catch (err) {
      toast.danger(`删除失败:${err}`);
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
          label: "在新窗口中打开",
          onSelect: () => {
            // Snapshot this project's current panes / editor tabs so the new
            // window inherits the layout instead of resetting to the picker.
            const ui = captureProjectUiSnapshot(p.id) ?? undefined;
            openProjectInNewWindow(p.id, p.name, ui).catch((err) =>
              toast.danger(`在新窗口打开失败:${err}`),
            );
          },
        },
      ],
    });
  }

  return (
    <header
      ref={headerRef}
      className={
        "topbar" +
        (autoHideTopBar ? " auto-hide" : "") +
        (hidden ? " hidden" : "")
      }
      // The collapsed bar is decorative until revealed — keep it off the
      // tab order and out of the a11y tree so keyboard/screen-reader users
      // don't land on invisible controls.
      aria-hidden={hidden || undefined}
      inert={hidden || undefined}
    >
      {/* Detached windows display the project name in the native window
          title bar (set when we spawn the WebviewWindow), so we hide the
          tab strip here to avoid showing the same name twice. */}
      {!detached && !overviewActive && (
        <div
          className="project-tabs"
          onPointerMove={onProjectPointerMove}
          onPointerUp={onProjectPointerEnd}
          onPointerCancel={onProjectPointerCancel}
        >
          {projectList.map((p) => {
            const active = p.id === activeProjectId;
            const activity = activityByProject[p.id] ?? null;
            return (
              <div
                key={p.id}
                className={
                  "project-tab" +
                  (active ? " active" : "") +
                  (draggedProjectId === p.id ? " dragging" : "") +
                  (projectDrop && projectDrop.id === p.id
                    ? ` drop-${projectDrop.edge}`
                    : "")
                }
                data-project-id={p.id}
                onClick={() => {
                  if (suppressProjectClickRef.current) {
                    suppressProjectClickRef.current = false;
                    return;
                  }
                  setActiveProjectId(p.id);
                }}
                onContextMenu={(e) => onProjectContextMenu(e, p)}
                title={p.repo_path}
              >
                {/* Always render a dot so tabs stay visually consistent even
                    with no live sessions (e.g. right after ⌘W closes the last
                    one). `null` activity → a neutral "idle" dot. */}
                <StatusDot
                  status={statusFromLight(activity?.light)}
                  className="project-tab-dot"
                />
                <span
                  className="project-tab-name"
                  onPointerDown={(e) => {
                    if (e.button !== 0) return;
                    projectDragRef.current = {
                      id: p.id,
                      pointerId: e.pointerId,
                      startX: e.clientX,
                      startY: e.clientY,
                      active: false,
                    };
                    e.currentTarget.setPointerCapture?.(e.pointerId);
                  }}
                  title={`拖动以重新排序 · ${p.repo_path}`}
                >
                  {p.name}
                </span>
                {/* Live session count. Tinted red when any of them is waiting
                    on the user, so a background project can say "I need you"
                    without the tab having to be read. */}
                {activity && activity.total > 0 && (
                  <span
                    className={
                      "count-badge" +
                      (activity.counts.waiting > 0 ? " count-badge-hot" : "")
                    }
                    title={activityTooltip(activity)}
                  >
                    {activity.counts.waiting > 0
                      ? activity.counts.waiting
                      : activity.total}
                  </span>
                )}
                <span
                  className="project-tab-close"
                  role="button"
                  aria-label="删除项目"
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
            aria-label="打开项目"
            title="打开项目 (⌘O)"
          >
            <PlusIcon />
          </button>
          <ProjectSwitcher
            projects={projectList}
            activityByProject={activityByProject}
            open={switcherOpen}
            onOpenChange={setSwitcherOpen}
            onPick={(id) => {
              setActiveProjectId(id);
              setSwitcherOpen(false);
            }}
            onAddProject={() => {
              setSwitcherOpen(false);
              void onAddProject();
            }}
          />
        </div>
      )}
      <div className="topbar-actions">
        <button
          type="button"
          className="topbar-search"
          onClick={() => window.dispatchEvent(new CustomEvent("ycode:open-palette"))}
          aria-label="搜索或执行命令 (⌘K)"
          title="搜索或执行命令 (⌘K)"
        >
          <SearchIcon />
          <span>搜索或执行命令</span>
        </button>
        <AttentionInbox />
        <button
          type="button"
          className={`topbar-gear${settingsActive ? " active" : ""}`}
          onClick={() => window.dispatchEvent(new CustomEvent("ycode:open-settings"))}
          aria-label="设置"
          aria-pressed={settingsActive}
          title="设置 (⌘,)"
        >
          <GearIcon />
        </button>
      </div>
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

/// 预览稿的 `.ptab-more`/`.pswitch`:tab 条右端的项目切换下拉。列出「空闲
/// 项目」(没有任何活跃会话的项目 —— 有会话的项目已经靠 tab 上的状态点和
/// 徽章可见,重复列出只会稀释「这里是被遗忘的项目」的含义),底部两条动作
/// 通向项目总览与打开项目。
function ProjectSwitcher({
  projects,
  activityByProject,
  open,
  onOpenChange,
  onPick,
  onAddProject,
}: {
  projects: ProjectView[];
  activityByProject: Record<string, ProjectActivity | null>;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onPick: (id: string) => void;
  onAddProject: () => void;
}) {
  // 分支名按需获取:面板打开时对空闲项目并发取一次 HEAD,失败静默。
  const [branchById, setBranchById] = useState<Record<string, string>>({});
  const idle = useMemo(
    () =>
      projects.filter((p) => {
        const activity = activityByProject[p.id];
        return !activity || activity.total === 0;
      }),
    [projects, activityByProject],
  );
  useEffect(() => {
    if (!open || idle.length === 0) return;
    let cancelled = false;
    void Promise.allSettled(
      idle.map((p) =>
        gitBranch(p.id).then((info) => [p.id, info.head] as const),
      ),
    ).then((results) => {
      if (cancelled) return;
      const next: Record<string, string> = {};
      for (const r of results) {
        if (r.status === "fulfilled") next[r.value[0]] = r.value[1];
      }
      setBranchById(next);
    });
    return () => {
      cancelled = true;
    };
  }, [open, idle]);

  return (
    <Popover.Root open={open} onOpenChange={onOpenChange}>
      <Popover.Trigger
        className="ptab-more"
        aria-label="切换项目"
        title="切换项目"
      >
        <ChevronDownIcon />
        <span className="ptab-more-count">{projects.length}</span>
      </Popover.Trigger>
      <Popover.Portal>
        <Popover.Positioner sideOffset={8} align="start">
          <Popover.Popup className="pswitch">
            {idle.length > 0 && (
              <>
                <div className="pswitch-head">
                  <span className="eyebrow">空闲项目</span>
                </div>
                {idle.map((p) => (
                  <button
                    key={p.id}
                    type="button"
                    className="pswitch-item"
                    onClick={() => onPick(p.id)}
                    title={p.repo_path}
                  >
                    <StatusDot status="idle" labelled={false} />
                    <span className="pswitch-name">{p.name}</span>
                    {branchById[p.id] && (
                      <span className="pswitch-branch">{branchById[p.id]}</span>
                    )}
                  </button>
                ))}
              </>
            )}
            <button
              type="button"
              className="pswitch-foot"
              onClick={() => {
                onOpenChange(false);
                window.dispatchEvent(new CustomEvent("ycode:open-overview"));
              }}
            >
              <GridIcon />
              全部项目总览
              <kbd>⇧⌘P</kbd>
            </button>
            <button type="button" className="pswitch-foot" onClick={onAddProject}>
              <FolderPlusIcon />
              打开项目…
              <kbd>⌘O</kbd>
            </button>
          </Popover.Popup>
        </Popover.Positioner>
      </Popover.Portal>
    </Popover.Root>
  );
}

function ChevronDownIcon() {
  return (
    <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="m6 9 6 6 6-6" />
    </svg>
  );
}

function GridIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden>
      <rect x="3" y="3" width="7" height="7" rx="1.5" />
      <rect x="14" y="3" width="7" height="7" rx="1.5" />
      <rect x="3" y="14" width="7" height="7" rx="1.5" />
      <rect x="14" y="14" width="7" height="7" rx="1.5" />
    </svg>
  );
}

function FolderPlusIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" aria-hidden>
      <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" />
      <path d="M12 11v5M9.5 13.5h5" />
    </svg>
  );
}

function SearchIcon() {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      aria-hidden
    >
      <circle cx="11" cy="11" r="7" />
      <path d="m20 20-4-4" />
    </svg>
  );
}

function PlusIcon() {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      aria-hidden
    >
      <path d="M12 5v14M5 12h14" />
    </svg>
  );
}

const LIGHT_LABEL_CN: Record<SessionLight, string> = {
  running: "进行中",
  waiting: "等你处理",
  done: "已结束",
  error: "出错",
};

/// 项目 tab 状态点的摘要,如「有 agent 仍在运行 · 1 个进行中,2 个等你处理」。
/// 首句反映汇总灯色,后面列出非零的各状态计数。
function activityTooltip(a: ProjectActivity): string {
  const headline =
    a.light === "running"
      ? "有 agent 仍在运行"
      : a.light === "error"
        ? "有 agent 以错误结束"
        : a.light === "waiting"
          ? "有 agent 在等你输入"
          : "所有 agent 已完成";
  const parts: string[] = [];
  for (const light of ["running", "waiting", "done", "error"] as const) {
    if (a.counts[light]) {
      parts.push(`${a.counts[light]} 个${LIGHT_LABEL_CN[light]}`);
    }
  }
  return `${headline} · ${parts.join(",")}`;
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

