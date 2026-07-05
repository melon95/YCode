// Shared session-lifecycle actions used by more than one UI surface, so the
// pane close button (TerminalPane) and the ⌘W hotkey stay in lockstep instead
// of drifting into two subtly different "close" behaviours.

import { toast } from "@heroui/react";
import {
  archiveSession,
  sessionWorktreeDirty,
  sessionWorktreeUnmergedCommits,
} from "./ipc";
import { confirmDialog } from "./confirm";
import { displaySessionTitle, useStore } from "./store";

/// End a session immediately: kill its live process, archive the row, and drop
/// it from the store (which reflows the layout). One-click for the pane `×`,
/// EXCEPT when the session runs in an isolated worktree with uncommitted
/// changes — closing force-removes the worktree, so we confirm first to avoid
/// silently discarding the agent's work. No-op if the id isn't a known session.
export async function closeSessionNow(sessionId: string): Promise<void> {
  const sess = useStore.getState().sessions[sessionId];
  if (!sess) return;
  if (sess.worktree_path) {
    // Two independent ways closing can lose sight of an agent's work:
    //  - uncommitted changes: removed together with the worktree, gone.
    //  - committed-but-unmerged commits: the branch is kept, but goes orphan
    //    (no worktree, not surfaced anywhere in the UI) — a plain dirty check
    //    misses this entirely, which is how "where did my agent's work go?"
    //    happens. Check both and tailor the warning to what's actually at risk.
    let dirty = false;
    let unmerged = 0;
    try {
      [dirty, unmerged] = await Promise.all([
        sessionWorktreeDirty(sessionId),
        sessionWorktreeUnmergedCommits(sessionId),
      ]);
    } catch {
      // If we can't determine either, don't block the close.
    }
    if (dirty || unmerged > 0) {
      const branch = sess.branch ?? "its branch";
      const commits = `${unmerged} commit${unmerged === 1 ? "" : "s"}`;
      let message: string;
      if (dirty && unmerged > 0) {
        message =
          `This agent has uncommitted changes and ${commits} not merged into ${sess.base_branch ?? "its base"}. ` +
          `Closing removes the worktree: the uncommitted changes are discarded, and while the branch "${branch}" is kept, ` +
          `it goes orphan (no worktree, hidden from the UI). Commit and merge first to keep everything.`;
      } else if (dirty) {
        message =
          "This agent has uncommitted changes in its worktree. Closing removes the worktree and discards them — " +
          "commit or merge first to keep them.";
      } else {
        message =
          `This agent has ${commits} not yet merged into ${sess.base_branch ?? "its base"}. ` +
          `Closing removes the worktree; the branch "${branch}" is kept but goes orphan (hidden from the UI) — ` +
          "merge first to keep the work in view.";
      }
      const ok = await confirmDialog({
        title: "Close this agent's worktree?",
        message,
        confirmLabel: "Close anyway",
        destructive: true,
      });
      if (!ok) return;
    }
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
