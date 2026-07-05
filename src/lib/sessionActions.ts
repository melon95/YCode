// Shared session-lifecycle actions used by more than one UI surface, so the
// pane close button (TerminalPane) and the ⌘W hotkey stay in lockstep instead
// of drifting into two subtly different "close" behaviours.

import { toast } from "@heroui/react";
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
    toast.danger(`Close failed: ${err}`);
    return;
  }

  if (state.uncommitted || state.unmerged_commits > 0) {
    const branch = sess.branch ?? "its branch";
    const base = sess.base_branch ?? "its base";
    const n = state.unmerged_commits;
    const commits = `${n} commit${n === 1 ? "" : "s"}`;
    let message: string;
    if (state.uncommitted && n > 0) {
      message =
        `The agent is stopped. Its worktree has uncommitted changes and ${commits} not merged into ${base}. ` +
        `Removing the worktree discards the uncommitted changes; the branch "${branch}" is kept but goes orphan ` +
        `(no worktree, hidden from the UI). Merge first to keep everything.`;
    } else if (state.uncommitted) {
      message =
        "The agent is stopped. Its worktree has uncommitted changes. Removing the worktree discards them — " +
        "commit or merge first to keep them.";
    } else {
      message =
        `The agent is stopped. Its branch "${branch}" has ${commits} not merged into ${base}. ` +
        `Removing the worktree keeps the branch but orphans it (hidden from the UI) — merge first to keep the work in view.`;
    }
    const ok = await confirmDialog({
      title: "Remove this agent's worktree?",
      message,
      confirmLabel: "Remove worktree",
      destructive: true,
    });
    // Agent's already stopped; cancelling just keeps the worktree.
    if (!ok) return;
  }

  try {
    await archiveSession(sessionId);
    useStore.getState().removeSession(sessionId);
  } catch (err) {
    toast.danger(`Close failed: ${err}`);
  }
}

/// Same as [`closeSessionNow`] but gated behind a confirm dialog. Used by the
/// ⌘W hotkey, where a stray keystroke shouldn't silently kill the agent.
export async function archiveSessionWithConfirm(sessionId: string): Promise<void> {
  const { sessions, liveTitles } = useStore.getState();
  const sess = sessions[sessionId];
  if (!sess) return;
  const label = displaySessionTitle(sess, liveTitles) || "this session";
  const ok = await confirmDialog({
    title: `Close "${label}"?`,
    message: "The agent's live process will be killed.",
    confirmLabel: "Close session",
    destructive: true,
  });
  if (!ok) return;
  await closeSessionNow(sessionId);
}
