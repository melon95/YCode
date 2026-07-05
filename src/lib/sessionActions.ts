// Shared session-lifecycle actions used by more than one UI surface, so the
// pane close button (TerminalPane) and the ⌘W hotkey stay in lockstep instead
// of drifting into two subtly different "close" behaviours.

import { toast } from "@heroui/react";
import { archiveSession, sessionWorktreeDirty } from "./ipc";
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
    let dirty = false;
    try {
      dirty = await sessionWorktreeDirty(sessionId);
    } catch {
      // If we can't determine dirtiness, don't block the close.
    }
    if (dirty) {
      const ok = await confirmDialog({
        title: "Discard uncommitted changes?",
        message:
          "This agent has uncommitted changes in its worktree. Closing removes the worktree and discards them — commit or merge first to keep them.",
        confirmLabel: "Close & discard",
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
