// Cross-window coordination for the "Open project in new window" feature.
// Each detached window owns exactly one project; its label encodes the
// project id (`project-<uuid>`) so the main window can grey out tabs
// already owned by another window without any backend bookkeeping.
//
// Sync model:
//   - On startup, every window enumerates its peers via `getAllWebviewWindows`
//     and seeds `lockedByOtherWindows` from their labels.
//   - Spawning a window also broadcasts `ycode:project-locked`; closing it
//     broadcasts `ycode:project-unlocked`. Peers update their own store.
//   - When the OS kills a window without firing our close hook (panic, force
//     quit), the worst case is a stale lock survives until the next restart —
//     no persistent state, so a relaunch always reconciles.

import {
  WebviewWindow,
  getAllWebviewWindows,
  getCurrentWebviewWindow,
} from "@tauri-apps/api/webviewWindow";
import { emit, listen } from "@tauri-apps/api/event";

const LABEL_PREFIX = "project-";

const EVT_LOCKED = "ycode:project-locked";
const EVT_UNLOCKED = "ycode:project-unlocked";

interface LockPayload {
  projectId: string;
}

export function projectLabel(projectId: string): string {
  return `${LABEL_PREFIX}${projectId}`;
}

function parseLabel(label: string): string | null {
  return label.startsWith(LABEL_PREFIX) ? label.slice(LABEL_PREFIX.length) : null;
}

/// Locked project id encoded in this window's URL (`?project=…`). Null when
/// the current window is the main "all projects" window.
export function readLockedProjectIdFromUrl(): string | null {
  if (typeof window === "undefined") return null;
  try {
    return new URLSearchParams(window.location.search).get("project");
  } catch {
    return null;
  }
}

/// Opaque per-project UI snapshot (see `captureProjectUiSnapshot`) handed to
/// this window at spawn time via `?ui=…`. Null for the main window or any
/// detached window opened before this feature existed. Consumed once at
/// startup and never read again.
export function readUiStateFromUrl(): string | null {
  if (typeof window === "undefined") return null;
  try {
    return new URLSearchParams(window.location.search).get("ui");
  } catch {
    return null;
  }
}

/// Project ids currently owned by *other* live windows. The caller is
/// responsible for filtering out its own locked project id.
export async function snapshotPeerLockedProjects(): Promise<Set<string>> {
  const wins = await getAllWebviewWindows();
  const out = new Set<string>();
  const myLabel = getCurrentWebviewWindow().label;
  for (const w of wins) {
    if (w.label === myLabel) continue;
    const pid = parseLabel(w.label);
    if (pid) out.add(pid);
  }
  return out;
}

/// Spawn a detached window for `projectId`. If one already exists, focus it
/// instead of creating a duplicate (avoids `WebviewWindow` constructor
/// errors when the label collides).
export async function openProjectInNewWindow(
  projectId: string,
  title: string,
  uiState?: string,
): Promise<void> {
  const label = projectLabel(projectId);
  const existing = await getAllWebviewWindows();
  const found = existing.find((w) => w.label === label);
  if (found) {
    await found.setFocus();
    return;
  }
  // Relative URL — resolved against the frontend dist root, identical for
  // dev (vite) and prod (custom protocol). The optional `ui` payload carries
  // the source window's pane/editor layout so the new window opens looking
  // the same instead of dropping the user back at the session picker.
  const params = new URLSearchParams({ project: projectId });
  if (uiState) params.set("ui", uiState);
  new WebviewWindow(label, {
    url: `index.html?${params.toString()}`,
    title,
    width: 1100,
    height: 800,
  });
  await emit(EVT_LOCKED, { projectId } satisfies LockPayload);
}

/// Subscribe to lock/unlock broadcasts from peer windows.
export function listenPeerLockEvents(handlers: {
  onLocked: (projectId: string) => void;
  onUnlocked: (projectId: string) => void;
}): () => void {
  let lockedUnlisten: (() => void) | undefined;
  let unlockedUnlisten: (() => void) | undefined;
  let cancelled = false;

  Promise.all([
    listen<LockPayload>(EVT_LOCKED, (e) => handlers.onLocked(e.payload.projectId)),
    listen<LockPayload>(EVT_UNLOCKED, (e) => handlers.onUnlocked(e.payload.projectId)),
  ]).then(([u1, u2]) => {
    if (cancelled) {
      u1();
      u2();
      return;
    }
    lockedUnlisten = u1;
    unlockedUnlisten = u2;
  });

  return () => {
    cancelled = true;
    lockedUnlisten?.();
    unlockedUnlisten?.();
  };
}

/// Detached windows wire this up so closing the window releases the lock
/// back to the main window (and any other peers).
///
/// We `preventDefault` and then explicitly `destroy` because awaiting `emit`
/// directly inside the handler can hang the close (Tauri waits for the
/// promise) if the event bridge is slow/unavailable — the user would see
/// the traffic-light click as a no-op. A 500ms race ensures we never hold
/// the window hostage even when the broadcast goes nowhere; peers will
/// reconcile via `snapshotPeerLockedProjects` on next launch.
export async function bindUnlockOnClose(projectId: string): Promise<() => void> {
  const win = getCurrentWebviewWindow();
  let closing = false;
  const unlisten = await win.onCloseRequested(async (event) => {
    if (closing) return;
    closing = true;
    event.preventDefault();
    await Promise.race([
      emit(EVT_UNLOCKED, { projectId } satisfies LockPayload).catch(() => {}),
      new Promise<void>((resolve) => setTimeout(resolve, 500)),
    ]);
    await win.destroy();
  });
  return unlisten;
}
