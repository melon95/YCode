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
import { gitBranch } from "../lib/ipc";
import { useStore } from "../lib/store";
import { sessionLight, type SessionLight } from "../lib/types";
import { statusFromLight, STATUS_LABEL, type StatusKind } from "../lib/sessionStatus";
import { ProjectPickerMenu } from "./ui/ProjectPickerMenu";
import { StatusDot } from "./ui/StatusDot";

/// Shown in the status bar; sourced from package.json at build time so it
/// can never drift from the shipped build.
const APP_VERSION = __APP_VERSION__;

/// 只显示需要注意的状态。「N 个已完成」「N 个空闲」不构成行动信号 ——
/// 91 个历史会话全是已完成时,那个数字只是噪音。
const SHOWN: StatusKind[] = ["blocked", "working", "error"];

export function StatusBar() {
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
      ? `主仓库/${mainBranch}`
      : "主仓库";

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
      if (s.worktree_path) worktrees += 1;
    }
    return { counts, worktrees, total };
  }, [sessions, activityBySession]);

  return (
    <footer className="status-bar" aria-label="Workspace status">
      {activeProject && (
        <span className="sb-group" title={activeProject.repo_path}>
          <ProjectPickerMenu>{activeProject.name}</ProjectPickerMenu>
          <span className="sb-dim">· {checkout}</span>
        </span>
      )}
      <span className="sb-group sb-dim">
        {worktrees > 0 ? `worktree ×${worktrees}` : "无 worktree"}
      </span>
      <span className="toolbar-spacer" />
      {total > 0 &&
        SHOWN.filter((k) => counts[k] > 0).map((k) => (
          <span className="sb-group" key={k}>
            <StatusDot status={k} size="sm" labelled={false} />
            {counts[k]} 个{STATUS_LABEL[k]}
          </span>
        ))}
      <span className="sb-group sb-dim sb-version">v{APP_VERSION}</span>
    </footer>
  );
}
