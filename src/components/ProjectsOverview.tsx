// Projects overview — the one surface that answers "what is happening across
// everything I'm working on".
//
// The project tabs answer this per project and the status bar answers it as a
// single tally; neither shows you *which* project needs attention when you
// have eight of them. Cards, ordered attention-first, do.

import { useEffect, useMemo, useState } from "react";
import { open as openDialog } from "@tauri-apps/plugin-dialog";
import { toast } from "../lib/toast";
import { OverflowMenu } from "./ui/OverflowMenu";
import { removeProjectWithConfirm } from "../lib/projectActions";
import { useStore } from "../lib/store";
import { createProject, gitBranch } from "../lib/ipc";
import {
  projectActivity,
  type ProjectActivity,
  type SessionView,
} from "../lib/types";
import { statusFromLight, STATUS_RANK, type StatusKind } from "../lib/sessionStatus";
import { StatusDot } from "./ui/StatusDot";
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
  lastActivityMs: number;
  worktrees: number;
};

export function ProjectsOverview({ onClose }: Props) {
  const projects = useStore((s) => s.projects);
  const projectOrder = useStore((s) => s.projectOrder);
  const sessions = useStore((s) => s.sessions);
  const activityBySession = useStore((s) => s.activityBySession);
  const setActiveProjectId = useStore((s) => s.setActiveProjectId);
  const upsertProject = useStore((s) => s.upsertProject);

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
    <section
      className="flex-1 min-h-0 flex flex-col bg-bg overflow-hidden animate-fade-in"
      aria-label="全部项目"
    >
      <header className="flex-none flex items-baseline gap-3.5 pt-[26px] px-8 pb-4">
        <h1 className="text-[22px] font-bold tracking-[-0.015em]">项目</h1>
        <span className="font-mono text-[11.5px] text-muted">
          {totals.blocked > 0 && (
            <span className="text-st-blocked">{totals.blocked} 个等你处理</span>
          )}
          {totals.blocked > 0 && totals.working > 0 && " · "}
          {totals.working > 0 && (
            <span className="text-st-working">{totals.working} 个进行中</span>
          )}
          {totals.blocked === 0 && totals.working === 0 && "没有正在运行的 agent"}
          {" · "}
          共 {rows.length} 个项目
        </span>
        <span className="toolbar-spacer" />
        <div
          className="self-center flex gap-1.5"
          role="tablist"
          aria-label="项目筛选"
        >
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
        <IconButton
          className="self-center"
          onClick={onClose}
          title="返回工作区 (esc)"
          aria-label="返回工作区"
        >
          <CloseIcon />
        </IconButton>
      </header>

      {shown.length === 0 && (
        <div className="pt-2 px-8 pb-5 text-[12.5px] text-subtle">
          {filter === "blocked"
            ? "没有项目在等你处理。"
            : filter === "working"
              ? "没有项目正在运行 agent。"
              : "还没有项目。"}
        </div>
      )}

      <div className="flex-1 min-h-0 overflow-y-auto grid grid-cols-[repeat(auto-fill,minmax(300px,1fr))] gap-3.5 pt-1 px-8 pb-8 content-start">
        {shown.map((r) => (
          <button
            type="button"
            key={r.id}
            // 三行(名字 / 标签 / 路径)之间用 6px —— 原来的 10px 是给
            // 「名字 + 色条 + 两行计数」那版排的,行数减半后同样的间距会
            // 把卡片撑空。
            //
            // agent 卡住的项目盖过你正在看的东西,所以卡片在你读到名字
            // 之前就该说出这件事。
            className={`group flex flex-col gap-1.5 pt-3.5 pr-[15px] pb-[13px] pl-[15px]
              border rounded-[14px] bg-panel text-[inherit] text-left cursor-pointer
              transition-[border-color,transform,box-shadow] duration-[var(--t-base)] ease-smooth
              hover:border-rule-strong hover:-translate-y-px hover:shadow-[0_6px_20px_rgba(var(--shadow-rgb),0.22)]
              active:scale-[0.995]
              ${r.status === "blocked" ? "border-st-blocked-card" : "border-rule"}`
              .replace(/\s+/g, " ")
              .trim()}
            onClick={() => open(r.id)}
            title={r.repoPath}
          >
            <span className="flex items-center gap-[9px]">
              <StatusDot status={r.status} labelled={false} />
              <span className="flex-1 min-w-0 text-[13.5px] font-semibold text-text whitespace-nowrap overflow-hidden text-ellipsis">
                {r.name}
              </span>
              <OverflowMenu
                label={`${r.name} 的更多操作`}
                asSpan
                actions={[
                  {
                    label: "删除",
                    destructive: true,
                    onClick: () => void removeProjectWithConfirm(r.id),
                  },
                ]}
              />
            </span>

            {/* 中间一行:分支 + worktree/隔离,即「这份 checkout 是什么
                形态」。单独成行而不是挤在项目名旁边 —— 项目名长短不一,
                挤一起会让标签在每张卡上都落在不同的横向位置,一排看过去
                对不齐。会话数不在这里报:左上角那颗状态点已经回答了
                「有没有事在发生」。 */}
            {(branchById[r.id] || r.worktrees > 0 || r.isolate) && (
              <span className="flex items-center gap-2 min-w-0 overflow-hidden">
                {/* 卡片名旁的当前分支名 —— 等宽小字、subtle。 */}
                {branchById[r.id] && (
                  <span className="flex-none font-mono text-[10px] text-subtle whitespace-nowrap overflow-hidden text-ellipsis">
                    {branchById[r.id]}
                  </span>
                )}
                {r.worktrees > 0 && (
                  <span className={PO_TAG}>worktree ×{r.worktrees}</span>
                )}
                {r.isolate && <span className={PO_TAG}>默认隔离</span>}
              </span>
            )}
            <span className="font-mono text-[10px] text-muted whitespace-nowrap overflow-hidden text-ellipsis">
              {r.repoPath}
            </span>
          </button>
        ))}

        {/* 虚线「打开项目」卡,只在「全部」筛选下出现——过滤视图里它只会
            打断「哪些项目匹配」这个问题的答案。 */}
        {filter === "all" && (
          <button
            type="button"
            // 不自己定高 —— 卡片内容精简过一轮,写死的 140px 会让这张虚线
            // 卡比旁边的项目卡高出一截。让网格行高来决定,它自然和同行对齐。
            className="border border-dashed border-rule-strong rounded-[14px] flex items-center justify-center gap-2
              text-muted bg-none text-[12.5px] cursor-pointer
              transition-[color,background-color] duration-[var(--t-base)] ease-smooth
              hover:text-text hover:border-solid hover:bg-panel
              disabled:opacity-60 disabled:cursor-default"
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

/// 中间一行:分支 + worktree/隔离。各卡片的这一行都从左边同一处起排,
/// 所以扫一列卡片时这些标签是对齐的。
const PO_TAG = "flex-none font-mono text-[10px] text-muted whitespace-nowrap";

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
  // 只有「等你处理」这一格有资格着色,而且只在它非空时 —— 一个永远红着
  // 的 pill 就不再意味着「看这里」了。
  const hot = tone === "hot" && (count ?? 0) > 0;
  return (
    <button
      type="button"
      role="tab"
      aria-selected={on}
      className={`group inline-flex items-center gap-1.5 h-control-sm px-2.5 border rounded-full text-[11.5px] cursor-pointer
        transition-[background-color,border-color,color] duration-[var(--t-fast)] ease-smooth
        ${
          on
            ? "bg-panel-raised border-rule-strong text-text"
            : `bg-transparent hover:border-rule-strong hover:text-muted ${
                hot ? "text-st-blocked border-st-blocked-pill" : "text-subtle border-rule"
              }`
        }`
        .replace(/\s+/g, " ")
        .trim()}
      onClick={() => onPick(id)}
    >
      {children}
      {count != null && count > 0 && (
        <span
          className={`font-mono text-[9.5px] font-bold ${
            on ? "text-text-soft" : hot ? "text-st-blocked" : "text-muted"
          }`}
        >
          {count}
        </span>
      )}
    </button>
  );
}
