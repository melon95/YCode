// Shared session-lifecycle actions used by more than one UI surface, so the
// pane close button (TerminalPane) and the ⌘W hotkey stay in lockstep instead
// of drifting into two subtly different "close" behaviours.

import { toast } from "./toast";
import { archiveSession, stopSessionForClose } from "./ipc";
import type { WorktreeCloseState } from "./types";
import { confirmDialog } from "./confirm";
import { displaySessionTitle, useStore } from "./store";

/// End a session immediately: kill its live process, archive the row, and drop
/// it from the store (which reflows the layout). One-click for the pane `×`.
///
/// For an isolated worktree we stop the agent FIRST (backend kills the PTY
/// before it inspects), then confirm removal based on that final state — never
/// while the agent is still running. Otherwise the check would be racy: the
/// agent could commit or edit during the confirm, and archival force-removes
/// the worktree, silently dropping the post-check work. If the user cancels the
/// removal, the agent stays stopped and the worktree is kept (the session
/// lingers as an exited pane they can merge or reopen). No-op for unknown ids.
export async function closeSessionNow(sessionId: string): Promise<void> {
  const sess = useStore.getState().sessions[sessionId];
  if (!sess) return;

  // Shared-mode session (no worktree): nothing to lose, archive straight away.
  if (!sess.worktree_path) {
    try {
      await archiveSession(sessionId);
      useStore.getState().removeSession(sessionId);
    } catch (err) {
      toast.danger(`Close failed: ${err}`);
    }
    return;
  }

  // Stop the agent and take a final snapshot of what removal would risk.
  let state: WorktreeCloseState;
  try {
    state = await stopSessionForClose(sessionId);
  } catch (err) {
    toast.danger(`关闭失败:${err}`);
    return;
  }

  if (state.uncommitted || state.unmerged_commits > 0) {
    const branch = sess.branch ?? "它的分支";
    const base = sess.base_branch ?? "基准分支";
    const n = state.unmerged_commits;
    let message: string;
    if (state.uncommitted && n > 0) {
      message =
        `agent 已停止。它的 worktree 有未提交的改动,另有 ${n} 个提交尚未合并到 ${base}。` +
        `移除 worktree 会丢弃未提交的改动;分支「${branch}」会保留但成为孤儿分支` +
        `(没有 worktree,不再显示在界面里)。想全部保留请先合并。`;
    } else if (state.uncommitted) {
      message =
        "agent 已停止。它的 worktree 有未提交的改动,移除 worktree 会把它们丢弃 —— " +
        "想保留请先提交或合并。";
    } else {
      message =
        `agent 已停止。分支「${branch}」有 ${n} 个提交尚未合并到 ${base}。` +
        `移除 worktree 会保留分支但使其成为孤儿(不再显示在界面里)—— 想让工作可见请先合并。`;
    }
    const ok = await confirmDialog({
      title: "移除这个 agent 的 worktree?",
      message,
      confirmLabel: "移除 worktree",
      destructive: true,
    });
    // Agent's already stopped; cancelling just keeps the worktree.
    if (!ok) return;
  }

  try {
    await archiveSession(sessionId);
    useStore.getState().removeSession(sessionId);
  } catch (err) {
    toast.danger(`关闭失败:${err}`);
  }
}

/// Same as [`closeSessionNow`] but gated behind a confirm dialog. Used by the
/// ⌘W hotkey, where a stray keystroke shouldn't silently kill the agent.
export async function archiveSessionWithConfirm(sessionId: string): Promise<void> {
  const { sessions, liveTitles } = useStore.getState();
  const sess = sessions[sessionId];
  if (!sess) return;
  const label = displaySessionTitle(sess, liveTitles) || "这个会话";
  const ok = await confirmDialog({
    title: `关闭「${label}」?`,
    message: "agent 的运行进程会被结束。",
    confirmLabel: "关闭会话",
    destructive: true,
  });
  if (!ok) return;
  await closeSessionNow(sessionId);
}
