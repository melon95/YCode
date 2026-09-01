// 顶栏:项目 tab 已迁入侧边栏(以分组形式),这里只剩全局入口 ——
// 打开项目、搜索/命令面板、等你处理收件箱、设置。窗口标题栏由原生
// 提供,自动隐藏模式保留(藏一根横条是窗口行为)。

import { useEffect, useRef, useState } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import { toast } from "@heroui/react";
import { createProject } from "../lib/ipc";
import { useStore } from "../lib/store";
import { AttentionInbox } from "./AttentionInbox";

/// How close to the window's top edge the pointer has to get before the
/// auto-hidden bar slides back in.
const TOPBAR_REVEAL_ZONE_PX = 6;

/// How long the bar stays peeked open after a keyboard project switch.
const TOPBAR_PEEK_MS = 1200;

export function TopBar({
  settingsActive = false,
}: {
  settingsActive?: boolean;
  /// 兼容旧 prop:项目 tab 已不在顶栏,总览打开与否不再影响顶栏内容。
  overviewActive?: boolean;
}) {
  const [creatingProject, setCreatingProject] = useState(false);
  const upsertProject = useStore((s) => s.upsertProject);
  const setActiveProjectId = useStore((s) => s.setActiveProjectId);
  const lockedProjectId = useStore((s) => s.lockedProjectId);
  const autoHideTopBar = useStore((s) => s.autoHideTopBar);
  const [revealed, setRevealed] = useState(false);
  const [peeking, setPeeking] = useState(false);
  const detached = lockedProjectId !== null;

  // Pointer-driven reveal for the auto-hide mode.
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
      const rect = headerRef.current?.getBoundingClientRect();
      setRevealed(
        !!rect &&
          e.clientY <= rect.bottom &&
          e.clientX >= rect.left &&
          e.clientX <= rect.right,
      );
    };
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

  // 键盘切项目后短暂探出,给个视觉反馈。
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

  const pinned = creatingProject;
  const hidden = autoHideTopBar && !revealed && !pinned && !peeking;

  // ⌘O 从 hotkeys 派发过来。
  useEffect(() => {
    const onNewProject = () => {
      if (!detached) void onAddProject();
    };
    window.addEventListener("ycode:new-project", onNewProject);
    return () => {
      window.removeEventListener("ycode:new-project", onNewProject);
    };
  }, [detached, creatingProject]);

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

  return (
    <header
      ref={headerRef}
      className={
        "topbar" +
        (autoHideTopBar ? " auto-hide" : "") +
        (hidden ? " hidden" : "")
      }
      aria-hidden={hidden || undefined}
      inert={hidden || undefined}
    >
      {!detached && (
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
      )}
      {!detached && (
        <button
          type="button"
          className="topbar-overview"
          onClick={() => window.dispatchEvent(new CustomEvent("ycode:open-overview"))}
          aria-label="全部项目总览 (⇧⌘P)"
          title="全部项目总览 (⇧⌘P)"
        >
          <GridIcon />
        </button>
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
    </header>
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
