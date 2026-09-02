// 侧边栏:项目为一级分组,组内是该项目的会话历史。
//
// 项目从顶栏 tab 迁到这里之后,顶栏只剩全局入口(搜索/收件箱/设置),
// 且不切换项目就能看任何项目的历史 —— 点别的项目下的会话行时,内部
// 自动切 activeProject 再打开/恢复,对用户是一个动作。
//
// 状态点/徽章/右键新窗口/拖拽排序/⇧⌘[] 均有意去掉(简化第一版);
// transcript 扫描按分组懒加载,见 SidebarProjectGroup。

import { useEffect, useMemo, useState } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import { toast } from "../lib/toast";
import { LAYOUT_CAP, useStore } from "../lib/store";
import { createProject, createSession } from "../lib/ipc";
import type {
  DiscoveredSessionView,
  ProjectView,
} from "../lib/types";
import { SidebarToggle } from "./ui/SidebarToggle";
import { AgentFilterMenu } from "./ui/AgentFilterMenu";
import type { MergedSession } from "../lib/sessionList";
import { SidebarProjectGroup } from "./SidebarProjectGroup";

interface SidebarProps {
  /// Hides the sidebar. Optional so the component still renders standalone
  /// in tests, where there is no surrounding column to collapse.
  onToggleSidebar?: () => void;
}

export function Sidebar({ onToggleSidebar }: SidebarProps) {
  const [creating, setCreating] = useState(false);
  const [creatingProject, setCreatingProject] = useState(false);
  const [showAllAgents, setShowAllAgents] = useState(true);
  const [userPickedAgent, setUserPickedAgent] = useState<string | null>(null);
  const upsertProject = useStore((s) => s.upsertProject);
  const upsertSession = useStore((s) => s.upsertSession);
  const openSessionInLayout = useStore((s) => s.openSessionInLayout);
  const showNewSessionPicker = useStore((s) => s.showNewSessionPicker);
  const projects = useStore((s) => s.projects);
  const projectOrder = useStore((s) => s.projectOrder);
  const activeProjectId = useStore((s) => s.activeProjectId);
  const setActiveProjectId = useStore((s) => s.setActiveProjectId);
  const lockedProjectId = useStore((s) => s.lockedProjectId);
  const lockedByOtherWindows = useStore((s) => s.lockedByOtherWindows);
  const agents = useStore((s) => s.agents);
  const agentTabs = useMemo(() => agents.filter((a) => a.available), [agents]);
  const visibleCount = useStore((s) => s.layout.visibleIds.length);
  const atCap = visibleCount >= LAYOUT_CAP;

  // 与顶栏原 projectList 同一套可见性规则:分离窗口只看锁定项目,
  // 主窗口隐藏被其他窗口占用的项目。排序沿用 projectOrder。
  const projectList = useMemo(() => {
    const orderById = new Map(projectOrder.map((id, index) => [id, index]));
    const all = Object.values(projects)
      .slice()
      .sort((a, b) => {
        const ao = orderById.get(a.id) ?? Number.MAX_SAFE_INTEGER;
        const bo = orderById.get(b.id) ?? Number.MAX_SAFE_INTEGER;
        return ao - bo || a.created_at_ms - b.created_at_ms;
      });
    if (lockedProjectId) return all.filter((p) => p.id === lockedProjectId);
    return all.filter((p) => !lockedByOtherWindows[p.id]);
  }, [projects, projectOrder, lockedProjectId, lockedByOtherWindows]);

  // 展开状态:活跃项目默认展开;其余手动。切活跃项目时把新的也展开
  // (用户点了它组里的会话行,自然还想看着这个组)。
  const [expandedIds, setExpandedIds] = useState<Set<string>>(new Set());
  useEffect(() => {
    if (!activeProjectId) return;
    setExpandedIds((prev) => {
      if (prev.has(activeProjectId)) return prev;
      const next = new Set(prev);
      next.add(activeProjectId);
      return next;
    });
  }, [activeProjectId]);
  const toggleExpanded = (id: string) =>
    setExpandedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });

  const activeAgent = showAllAgents ? null : userPickedAgent;

  // ⌘N 快捷路径读这个值来选 agent。
  const setActiveSidebarAgentId = useStore((s) => s.setActiveSidebarAgentId);
  useEffect(() => {
    setActiveSidebarAgentId(activeAgent ?? agentTabs[0]?.id ?? null);
    return () => setActiveSidebarAgentId(null);
  }, [activeAgent, agentTabs, setActiveSidebarAgentId]);

  async function onCreate(
    project: ProjectView,
    profileId: string | null,
    opts?: { resume?: string; title?: string },
  ) {
    if (creating) return;
    if (atCap) {
      toast.warning(`已达 ${LAYOUT_CAP} 个面板上限,先关一个。`);
      return;
    }
    if (!profileId) {
      toast.warning("还没有选中 agent。");
      return;
    }
    const profile = useStore.getState().agents.find((a) => a.id === profileId);
    if (!profile) {
      toast.danger(`没有 id 为「${profileId}」的 agent 配置`);
      return;
    }
    setCreating(true);
    try {
      const view = await createSession({
        agent_profile_id: profile.id,
        project_id: project.id,
        title: opts?.title ?? "",
        resume: opts?.resume,
      });
      upsertSession(view);
      openSessionInLayout(view.id);
    } catch (err) {
      toast.danger(`启动 ${profile.display_name} 会话失败:${err}`);
    } finally {
      setCreating(false);
    }
  }

  async function onResume(d: DiscoveredSessionView, project: ProjectView) {
    if (!d.session_id) {
      toast.warning("这份 transcript 还没有可恢复的会话 id。");
      return;
    }
    const existing = Object.values(useStore.getState().sessions).find(
      (s) =>
        s.agent_session_id === d.session_id &&
        s.status.type === "Running" &&
        s.project_id === project.id,
    );
    if (existing) {
      openSessionInLayout(existing.id);
      return;
    }
    const profile = agentTabs.find((a) => a.introspect === d.agent);
    if (!profile) {
      toast.danger(`没有能恢复「${d.agent}」会话的 agent 配置,请在设置里添加。`);
      return;
    }
    await onCreate(project, profile.id, {
      resume: d.session_id,
      title: d.title ?? "",
    });
  }

  // 打开项目(原顶栏 + 按钮)。⌘O 经 ycode:new-project 事件也走这里。
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
  useEffect(() => {
    const onNewProject = () => {
      if (!lockedProjectId) void onAddProject();
    };
    window.addEventListener("ycode:new-project", onNewProject);
    return () => window.removeEventListener("ycode:new-project", onNewProject);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [lockedProjectId, creatingProject]);

  /// 点任意项目组里的会话行:先切活跃项目(画布/右栏跟着换),再
  /// 打开已有 pane 或恢复 transcript —— 对用户是一步。
  function openRow(project: ProjectView, row: MergedSession) {
    if (project.id !== activeProjectId) setActiveProjectId(project.id);
    if (row.live) {
      openSessionInLayout(row.live.id);
      return;
    }
    if (row.discovered) void onResume(row.discovered, project);
  }

  return (
    <aside className="sidebar">
      <div className="sidebar-header">
        {onToggleSidebar && (
          <SidebarToggle collapsed={false} onToggle={onToggleSidebar} />
        )}
        {!lockedProjectId && (
          <>
            <button
              type="button"
              className="sidebar-top-btn"
              onClick={onAddProject}
              disabled={creatingProject}
              aria-label="打开项目"
              title="打开项目 (⌘O)"
            >
              <FolderPlusIcon />
            </button>
            <button
              type="button"
              className="sidebar-top-btn"
              onClick={() =>
                window.dispatchEvent(new CustomEvent("ycode:open-overview"))
              }
              aria-label="全部项目总览 (⇧⌘P)"
              title="全部项目总览 (⇧⌘P)"
            >
              <GridIcon />
            </button>
          </>
        )}
        <AgentFilterMenu
          agents={agentTabs}
          value={activeAgent}
          onChange={(id) => {
            setShowAllAgents(id === null);
            setUserPickedAgent(id);
          }}
        />
      </div>

      {/* 项目分组列表:一根滚动列,组内不再各自滚。 */}
      <div className="sidebar-scroll">
        {projectList.map((p) => (
          <SidebarProjectGroup
            key={p.id}
            project={p}
            expanded={expandedIds.has(p.id)}
            onToggle={() => {
              // 点组头同时把这个项目设为活跃 —— 否则切项目只剩「点一个
              // 已有会话行」这一条路,而空项目根本没有行可点,底部的
              // 「新建会话」也就一直建在上一个项目里。
              if (p.id !== activeProjectId) setActiveProjectId(p.id);
              toggleExpanded(p.id);
            }}
            onOpenRow={openRow}
            agentFilter={activeAgent}
          />
        ))}
        {projectList.length === 0 && (
          <div className="sidebar-live-empty">
            还没有项目。用顶栏的「打开项目」添加一个。
          </div>
        )}
      </div>

      <div className="sidebar-footer">
        <button
          type="button"
          className="new-session-btn"
          onClick={showNewSessionPicker}
          disabled={!activeProjectId || creating || atCap}
          aria-label={
            atCap ? `已达 ${LAYOUT_CAP} 个面板上限,先关一个` : "新建会话"
          }
          title={
            atCap
              ? `已达 ${LAYOUT_CAP} 个面板上限,先关一个`
              : "新建会话 —— 打开 agent 选择器"
          }
        >
          <span className="nsb-plus" aria-hidden>
            <PlusIcon />
          </span>
          <span className="nsb-label">{creating ? "启动中…" : "新建会话"}</span>
          <kbd aria-hidden>⇧⌘N</kbd>
        </button>
      </div>
    </aside>
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

function FolderPlusIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" aria-hidden>
      <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" />
      <path d="M12 11v5M9.5 13.5h5" />
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
