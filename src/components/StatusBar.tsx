// The status bar — one line at the bottom of the workspace answering
// "what's the shape of my work right now" without opening anything:
// which checkout the tools point at, how many isolated worktrees exist,
// and the fleet-wide session tally.
//
// It is the only surface that counts across *all* projects. The project
// tabs answer the same question per project; this answers it globally, so
// a background project with a blocked agent still shows up while you're
// heads-down somewhere else.

import { useEffect, useMemo, useState } from "react";
import { useTranslation } from "react-i18next";
import { gitBranch } from "../lib/ipc";
import { useStore } from "../lib/store";
import { sessionLight, type SessionLight } from "../lib/types";
import {
  statusFromLight,
  STATUS_LABEL_KEY,
  type StatusKind,
} from "../lib/sessionStatus";
import { ProjectPickerMenu } from "./ui/ProjectPickerMenu";
import { StatusDot } from "./ui/StatusDot";

/// Shown in the status bar; sourced from package.json at build time so it
/// can never drift from the shipped build.
const APP_VERSION = __APP_VERSION__;

/// 只显示需要注意的状态。「N 个已完成」「N 个空闲」不构成行动信号 ——
/// 91 个历史会话全是已完成时,那个数字只是噪音。
const SHOWN: StatusKind[] = ["blocked", "working", "error"];

const SB_GROUP = "inline-flex items-center gap-1.5 whitespace-nowrap";

export function StatusBar() {
  const { t } = useTranslation();
  const sessions = useStore((s) => s.sessions);
  const projects = useStore((s) => s.projects);
  const activeProjectId = useStore((s) => s.activeProjectId);
  const activityBySession = useStore((s) => s.activityBySession);

  const activeProject = activeProjectId ? projects[activeProjectId] : null;
  const workspaceSessionId = useStore((s) =>
    activeProjectId ? (s.workspaceSessionByProject[activeProjectId] ?? null) : null,
  );
  const workspaceSession = workspaceSessionId ? sessions[workspaceSessionId] : null;
  // 主仓库的当前 git 分支。切项目 / 切回主仓库时取一次;失败(非 git 目录等)
  // 静默回落到「主仓库」。不做轮询 —— 状态栏不值得为一根分支名常驻开销,
  // checkout 切换本身就是这里唯一会让答案变化的入口。
  const [mainBranch, setMainBranch] = useState<string | null>(null);
  useEffect(() => {
    setMainBranch(null);
    if (!activeProjectId || workspaceSession?.worktree_path) return;
    let cancelled = false;
    gitBranch(activeProjectId)
      .then((info) => {
        if (!cancelled) setMainBranch(info.head);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [activeProjectId, workspaceSession?.worktree_path]);
  // Which checkout the tools are pointed at — the same answer the terminal
  // card's picker gives, repeated here because the status bar is the one
  // line that's visible no matter which panels are open.
  // worktree 会话显示 checked-out 的分支(branch),不是它分叉自的
  // base_branch —— 用户正在浏览的是前者,标成后者会让人以为在改主干。
  const checkout = workspaceSession?.worktree_path
    ? (workspaceSession.branch ?? workspaceSession.base_branch ?? "worktree")
    : mainBranch
      ? t("statusBar.mainRepoOn", { branch: mainBranch })
      : t("statusBar.mainRepo");

  // 状态点的统计是全局的(见文件头:后台项目里卡住的 agent 也该冒头),
  // 但 worktree 数不是 —— 它紧挨着「项目 · checkout」那一组显示,读起来
  // 就是「这个项目有几个 worktree」。跨项目求和会让每个项目都显示同一个
  // 数字,所以这一项按当前项目过滤。
  const { counts, worktrees, total } = useMemo(() => {
    const counts = { working: 0, blocked: 0, done: 0, error: 0, idle: 0 } as Record<
      StatusKind,
      number
    >;
    let worktrees = 0;
    let total = 0;
    for (const s of Object.values(sessions)) {
      if (s.archived_at_ms != null) continue;
      total += 1;
      const light: SessionLight = sessionLight(s.status, activityBySession[s.id]);
      counts[statusFromLight(light)] += 1;
      if (s.worktree_path && s.project_id === activeProjectId) worktrees += 1;
    }
    return { counts, worktrees, total };
  }, [sessions, activityBySession, activeProjectId]);

  return (
    <footer
      // `status-bar` 是选择器钩子:通铺时侧栏与画布同底色,这条横带的
      // `--bg` 覆盖写在 `.app-workspace .status-bar` 上 —— 状态栏在总览屏
      // (`.app-overview-host`)里也渲染一份,只有工作区里那份该跟着变。
      className="status-bar flex-none h-7 flex items-center gap-4 px-3.5 border-t border-rule bg-surface font-mono text-[10.5px] text-subtle"
      aria-label="Workspace status"
    >
      {activeProject && (
        <span className={SB_GROUP} title={activeProject.repo_path}>
          <ProjectPickerMenu>{activeProject.name}</ProjectPickerMenu>
          <span className="text-muted">· {checkout}</span>
        </span>
      )}
      <span className={`${SB_GROUP} text-muted`}>
        {worktrees > 0 ? `worktree ×${worktrees}` : t("statusBar.noWorktree")}
      </span>
      <span className="toolbar-spacer" />
      {total > 0 &&
        SHOWN.filter((k) => counts[k] > 0).map((k) => (
          <span className={SB_GROUP} key={k}>
            <StatusDot status={k} size="sm" labelled={false} />
            {t("statusBar.sessionCount", {
              count: counts[k],
              label: t(STATUS_LABEL_KEY[k]),
            })}
          </span>
        ))}
      <span className={`${SB_GROUP} text-muted ml-1`}>v{APP_VERSION}</span>
    </footer>
  );
}
