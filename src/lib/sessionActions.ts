// Shared session-lifecycle actions used by more than one UI surface, so the
// pane close button (TerminalPane) and the ⌘W hotkey stay in lockstep instead
// of drifting into two subtly different "close" behaviours.

import { i18next } from "./i18n";
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
    toast.danger(i18next.t("session.closeFailed", { error: err }));
    return;
  }

  if (state.uncommitted || state.unmerged_commits > 0) {
    const branch = sess.branch ?? i18next.t("session.itsBranch");
    const base = sess.base_branch ?? i18next.t("session.baseBranch");
    const n = state.unmerged_commits;
    // 三种情形各有自己的整句词条,不是拼出来的:未提交的改动和未合并的
    // 提交是两件不同的损失,拼接的句子在只占其一时读着别扭,换语言之后
    // 语序还未必对得上。
    const message =
      state.uncommitted && n > 0
        ? i18next.t("session.dirtyAndUnmerged", { count: n, base, branch })
        : state.uncommitted
          ? i18next.t("session.dirtyOnly")
          : i18next.t("session.unmergedOnly", { count: n, branch, base });
    const ok = await confirmDialog({
      title: i18next.t("session.removeWorktreeTitle"),
      message,
      confirmLabel: i18next.t("session.removeWorktree"),
      destructive: true,
    });
    // Agent's already stopped; cancelling just keeps the worktree.
    if (!ok) return;
  }

  try {
    await archiveSession(sessionId);
    useStore.getState().removeSession(sessionId);
  } catch (err) {
    toast.danger(i18next.t("session.closeFailed", { error: err }));
  }
}

/// Same as [`closeSessionNow`] but gated behind a confirm dialog. Used by the
/// ⌘W hotkey, where a stray keystroke shouldn't silently kill the agent.
export async function archiveSessionWithConfirm(sessionId: string): Promise<void> {
  const { sessions, liveTitles } = useStore.getState();
  const sess = sessions[sessionId];
  if (!sess) return;
  const label =
    displaySessionTitle(sess, liveTitles) || i18next.t("session.thisSession");
  const ok = await confirmDialog({
    title: i18next.t("session.closeTitle", { label }),
    message: i18next.t("session.closeBody"),
    confirmLabel: i18next.t("pane.close"),
    destructive: true,
  });
  if (!ok) return;
  await closeSessionNow(sessionId);
}
