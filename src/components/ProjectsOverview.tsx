// Projects overview — the one surface that answers "what is happening across
// everything I'm working on".
//
// The project tabs answer this per project and the status bar answers it as a
// single tally; neither shows you *which* project needs attention when you
// have eight of them. Cards, ordered attention-first, do.

import { useEffect, useMemo, useState } from "react";
import { open as openDialog } from "@tauri-apps/plugin-dialog";
import { toast } from "../lib/toast";
import { useStore } from "../lib/store";
import { createProject, gitBranch } from "../lib/ipc";
import {
  projectActivity,
  sessionLight,
  type ProjectActivity,
  type SessionView,
} from "../lib/types";
import { statusFromLight, STATUS_RANK, type StatusKind } from "../lib/sessionStatus";
import { StatusDot } from "./ui/StatusDot";
import { AgentIcon } from "./AgentIcon";
import { IconButton } from "./ui/IconButton";

interface Props {
  onClose: () => void;
}

/// 「x 前」相对时间。Sidebar 里有个同款私有函数,但它没导出、且该文件
/// 不在本次改动范围内,所以这里复制一份并导出供测试使用。
export function relativeTime(ms: number): string {
  const diff = Date.now() - ms;
  if (diff < 60_000) return "刚刚";
  if (diff < 3_600_000) return `${Math.floor(diff / 60_000)} 分钟前`;
  if (diff < 86_400_000) return `${Math.floor(diff / 3_600_000)} 小时前`;
  return `${Math.floor(diff / 86_400_000)} 天前`;
}

type Row = {
  id: string;
  name: string;
  repoPath: string;
  isolate: boolean;
  activity: ProjectActivity | null;
  status: StatusKind;
  /// Distinct agent profiles with a live session here — the card's "who is
  /// working on this" strip.
  agentProfiles: string[];
  /// One segment per live session, so the card carries the *shape* of the
  /// work (three running, one blocked) and not just a count.
  segments: StatusKind[];
  lastActivityMs: number;
  worktrees: number;
};

export function ProjectsOverview({ onClose }: Props) {
  const projects = useStore((s) => s.projects);
  const projectOrder = useStore((s) => s.projectOrder);
  const sessions = useStore((s) => s.sessions);
  const agents = useStore((s) => s.agents);
  const activityBySession = useStore((s) => s.activityBySession);
  const setActiveProjectId = useStore((s) => s.setActiveProjectId);
  const showNewSessionPicker = useStore((s) => s.showNewSessionPicker);
  const upsertProject = useStore((s) => s.upsertProject);

  const agentByProfileId = useMemo(() => {
    const out: Record<string, (typeof agents)[number]> = {};
    for (const a of agents) out[a.id] = a;
    return out;
  }, [agents]);

  // 各项目主仓库的当前分支。总览打开时一次性并发获取(而不是在渲染路径里
  // 逐卡片串行调用);单个失败静默跳过——分支名是锦上添花,不值得报错。
  const [branchById, setBranchById] = useState<Record<string, string>>({});
  const projectIdsKey = Object.keys(projects).sort().join("\n");
  useEffect(() => {
    let cancelled = false;
    const ids = projectIdsKey ? projectIdsKey.split("\n") : [];
    void Promise.allSettled(
      ids.map(async (id) => ({ id, info: await gitBranch(id) })),
    ).then((results) => {
      if (cancelled) return;
      const next: Record<string, string> = {};
      for (const r of results) {
        if (r.status === "fulfilled" && r.value.info.head) {
          next[r.value.id] = r.value.info.head;
        }
      }
      setBranchById(next);
    });
    return () => {
      cancelled = true;
    };
  }, [projectIdsKey]);

  const rows = useMemo<Row[]>(() => {
    const byProject: Record<string, SessionView[]> = {};
    for (const s of Object.values(sessions)) {
      if (s.archived_at_ms != null) continue;
      (byProject[s.project_id] ??= []).push(s);
    }
    const orderIdx = new Map(projectOrder.map((id, i) => [id, i]));

    const list: Row[] = Object.values(projects).map((p) => {
      const live = byProject[p.id] ?? [];
      const activity = projectActivity(live, activityBySession);
      const segments = live
        .map((s) => statusFromLight(sessionLight(s.status, activityBySession[s.id])))
        .sort((a, b) => STATUS_RANK[a] - STATUS_RANK[b]);
      const profiles: string[] = [];
      for (const s of live) {
        if (!profiles.includes(s.agent_profile)) profiles.push(s.agent_profile);
      }
      return {
        id: p.id,
        name: p.name,
        repoPath: p.repo_path,
        isolate: p.isolate_sessions,
        activity,
        status: statusFromLight(activity?.light),
        agentProfiles: profiles,
        segments,
        lastActivityMs: live.reduce((max, s) => Math.max(max, s.updated_at_ms), 0),
        worktrees: live.filter((s) => s.worktree_path).length,
      };
    });

    // Attention first, then most-recent activity, then the user's own tab
    // order — so a blocked background project surfaces without disturbing
    // the arrangement they chose for everything that's quiet.
    return list.sort(
      (a, b) =>
        STATUS_RANK[a.status] - STATUS_RANK[b.status] ||
        b.lastActivityMs - a.lastActivityMs ||
        (orderIdx.get(a.id) ?? 1e9) - (orderIdx.get(b.id) ?? 1e9),
    );
  }, [projects, projectOrder, sessions, activityBySession]);

  const totals = useMemo(() => {
    let blocked = 0;
    let working = 0;
    for (const r of rows) {
      blocked += r.activity?.counts.waiting ?? 0;
      working += r.activity?.counts.running ?? 0;
    }
    return { blocked, working };
  }, [rows]);

  // Sorting already floats the projects that want attention, but with more
  // than a screenful of cards "show me only the blocked ones" is a different
  // question from "show me everything, blocked first".
  const [filter, setFilter] = useState<Filter>("all");
  const shown = useMemo(() => {
    switch (filter) {
      case "blocked":
        return rows.filter((r) => (r.activity?.counts.waiting ?? 0) > 0);
      case "working":
        return rows.filter((r) => (r.activity?.counts.running ?? 0) > 0);
      case "recent":
        return rows.filter((r) => r.lastActivityMs > 0).slice(0, 12);
      default:
        return rows;
    }
  }, [rows, filter]);

  const blockedProjects = useMemo(
    () => rows.filter((r) => (r.activity?.counts.waiting ?? 0) > 0).length,
    [rows],
  );
  const workingProjects = useMemo(
    () => rows.filter((r) => (r.activity?.counts.running ?? 0) > 0).length,
    [rows],
  );

  function open(id: string) {
    setActiveProjectId(id);
    onClose();
  }

  // hover 快捷新建:切到该项目并直接打开新建会话选择器。与 Sidebar 底部
  // 「新建会话」按钮走同一条 store 路径(showNewSessionPicker)。
  function quickNew(id: string) {
    setActiveProjectId(id);
    showNewSessionPicker();
    onClose();
  }

  // 「＋ 打开项目…」:复用 TopBar onAddProject 的目录选择 + createProject
  // 流程(TopBar 那份耦合在组件内没导出,这里照搬同样的 ipc 调用)。
  const [creatingProject, setCreatingProject] = useState(false);
  async function onOpenProject() {
    if (creatingProject) return;
    setCreatingProject(true);
    try {
      const picked = await openDialog({
        directory: true,
        multiple: false,
        title: "选择项目仓库目录",
      });
      if (typeof picked !== "string") return; // 用户取消
      const name = picked.split("/").filter(Boolean).pop() ?? picked;
      const view = await createProject({ name, repo_path: picked });
      upsertProject(view);
      setActiveProjectId(view.id);
      onClose();
    } catch (err) {
      toast.danger(`创建项目失败:${err}`);
    } finally {
      setCreatingProject(false);
    }
  }

  return (
    <section className="projects-overview" aria-label="全部项目">
      <header className="po-head">
        <h1>项目</h1>
        <span className="po-summary">
          {totals.blocked > 0 && (
            <span className="po-hot">{totals.blocked} 个等你处理</span>
          )}
          {totals.blocked > 0 && totals.working > 0 && " · "}
          {totals.working > 0 && (
            <span className="po-warm">{totals.working} 个进行中</span>
          )}
          {totals.blocked === 0 && totals.working === 0 && "没有正在运行的 agent"}
          {" · "}
          共 {rows.length} 个项目
        </span>
        <span className="toolbar-spacer" />
        <div className="po-filter" role="tablist" aria-label="项目筛选">
          <FilterPill id="all" active={filter} onPick={setFilter}>
            全部
          </FilterPill>
          <FilterPill
            id="blocked"
            active={filter}
            onPick={setFilter}
            tone="hot"
            count={blockedProjects}
          >
            等你处理
          </FilterPill>
          <FilterPill
            id="working"
            active={filter}
            onPick={setFilter}
            count={workingProjects}
          >
            进行中
          </FilterPill>
          <FilterPill id="recent" active={filter} onPick={setFilter}>
            最近
          </FilterPill>
        </div>
        <IconButton onClick={onClose} title="返回工作区 (esc)" aria-label="返回工作区">
          <CloseIcon />
        </IconButton>
      </header>

      {shown.length === 0 && (
        <div className="po-empty">
          {filter === "blocked"
            ? "没有项目在等你处理。"
            : filter === "working"
              ? "没有项目正在运行 agent。"
              : "还没有项目。"}
        </div>
      )}

      <div className="po-grid">
        {shown.map((r) => (
          <button
            type="button"
            key={r.id}
            className={`po-card${r.status === "blocked" ? " is-attention" : ""}`}
            onClick={() => open(r.id)}
            title={r.repoPath}
          >
            <span className="po-card-top">
              <StatusDot status={r.status} labelled={false} />
              <span className="po-name">{r.name}</span>
              {branchById[r.id] && (
                <span className="po-branch">{branchById[r.id]}</span>
              )}
              <span className="po-agents">
                {r.agentProfiles.slice(0, 3).map((pid) => (
                  <AgentIcon
                    key={pid}
                    icon={agentByProfileId[pid]?.icon}
                    variant={agentByProfileId[pid]?.icon_variant}
                    fallbackChar={agentByProfileId[pid]?.display_name ?? "?"}
                    size={17}
                  />
                ))}
              </span>
              {/* hover 才出现的快捷新建。卡片本体已是 <button>,不能再嵌
                  button,所以用带键盘支持的 role="button" span。 */}
              <span
                role="button"
                tabIndex={0}
                className="po-quick-new"
                title="新建会话"
                aria-label="新建会话"
                onClick={(e) => {
                  e.stopPropagation(); // 别冒泡触发卡片本体的「进入项目」
                  quickNew(r.id);
                }}
                onKeyDown={(e) => {
                  if (e.key === "Enter" || e.key === " ") {
                    e.preventDefault();
                    e.stopPropagation();
                    quickNew(r.id);
                  }
                }}
              >
                <PlusIcon />
              </span>
            </span>

            {/* Session shape. Empty projects get a single flat rail so every
                card keeps the same height and the grid stays a grid. */}
            <span className="po-strip">
              {r.segments.length > 0 ? (
                r.segments
                  .slice(0, 12)
                  .map((seg, i) => (
                    <i key={i} className={`po-seg po-seg-${seg}`} />
                  ))
              ) : (
                <i className="po-seg po-seg-idle" />
              )}
            </span>

            {/* 预览稿的 .pcard-live:有活跃会话时显示状态汇总;空闲时显示
                「空闲 · 上次会话 x 前」。实时工具行需要 agent hook,不做。 */}
            <span className="po-live">
              {r.activity && r.activity.total > 0 ? (
                <span className="po-liverow">{activitySummary(r.activity)}</span>
              ) : (
                <span className="po-liverow is-empty">
                  空闲
                  {r.lastActivityMs > 0 &&
                    ` · 上次会话 ${relativeTime(r.lastActivityMs)}`}
                </span>
              )}
            </span>

            <span className="po-meta">
              {r.activity && r.activity.total > 0
                ? `${r.activity.total} 个会话`
                : "没有活跃会话"}
              {r.worktrees > 0 && ` · worktree ×${r.worktrees}`}
              {r.isolate && " · 默认隔离"}
            </span>
            <span className="po-path">{r.repoPath}</span>
          </button>
        ))}

        {/* 虚线「打开项目」卡,只在「全部」筛选下出现——过滤视图里它只会
            打断「哪些项目匹配」这个问题的答案。 */}
        {filter === "all" && (
          <button
            type="button"
            className="po-card-new"
            onClick={() => void onOpenProject()}
            disabled={creatingProject}
          >
            ＋ 打开项目… <kbd>⌘O</kbd>
          </button>
        )}
      </div>
    </section>
  );
}

/// 活跃项目的一行状态汇总,替代预览稿里需要 agent hook 才有的实时工具行。
function activitySummary(a: ProjectActivity): string {
  const parts: string[] = [];
  if (a.counts.waiting > 0) parts.push(`${a.counts.waiting} 个等你处理`);
  if (a.counts.running > 0) parts.push(`${a.counts.running} 个进行中`);
  if (a.counts.error > 0) parts.push(`${a.counts.error} 个出错`);
  if (parts.length === 0 && a.counts.done > 0) parts.push(`${a.counts.done} 个已完成`);
  return parts.join(" · ");
}

function PlusIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden>
      <path d="M12 5v14M5 12h14" />
    </svg>
  );
}

function CloseIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
      <path d="M18 6 6 18M6 6l12 12" />
    </svg>
  );
}

type Filter = "all" | "blocked" | "working" | "recent";

function FilterPill({
  id,
  active,
  onPick,
  count,
  tone,
  children,
}: {
  id: Filter;
  active: Filter;
  onPick: (f: Filter) => void;
  /// Rendered after the label. Omitted rather than shown as 0 — an empty
  /// filter advertises itself by being empty when you click it.
  count?: number;
  tone?: "hot";
  children: React.ReactNode;
}) {
  const on = active === id;
  return (
    <button
      type="button"
      role="tab"
      aria-selected={on}
      className={
        "po-fpill" +
        (on ? " is-active" : "") +
        (tone === "hot" && (count ?? 0) > 0 ? " is-hot" : "")
      }
      onClick={() => onPick(id)}
    >
      {children}
      {count != null && count > 0 && <span className="po-fpill-n">{count}</span>}
    </button>
  );
}
