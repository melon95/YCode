// Shared session-lifecycle actions used by more than one UI surface, so the
// pane close button (TerminalPane) and the ⌘W hotkey stay in lockstep instead
// of drifting into two subtly different "close" behaviours.

import { toast } from "@heroui/react";
import { archiveSession } from "./ipc";
import { confirmDialog } from "./confirm";
import { displaySessionTitle, useStore } from "./store";

/// End a session immediately: kill its live process, archive the row, and drop
/// it from the store (which reflows the layout). No confirm — the pane `×`
/// wires straight to this so closing a pane is a one-click action. No-op if the
/// id isn't a known session.
export async function closeSessionNow(sessionId: string): Promise<void> {
  if (!useStore.getState().sessions[sessionId]) return;
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
