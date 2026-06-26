// Single Zustand store backing the whole app. Components subscribe via
// selectors so they only re-render when the slice they care about moves.

import { useMemo } from "react";
import { create } from "zustand";
import type {
  AgentProfileView,
  FontSizesView,
  ProjectView,
  SessionActivity,
  SessionView,
  TodoView,
} from "./types";
import { DEFAULT_THEME_ID } from "./themes";

export const DEFAULT_FONT_SIZES: FontSizesView = {
  ui: 13,
  editor: 13,
  terminal: 13,
};
/// Hard floor/ceiling so a typo (or a stale config file from a future
/// version) can't make the app unusable.
export const FONT_SIZE_MIN = 8;
export const FONT_SIZE_MAX = 32;

export type RightTab = "files" | "editor" | "terminal" | "changes" | "todos";

// Middle-pane layout. `visibleIds` is the ordered slot list (0..N-1 where
// N = visibleIds.length); `focusSlot` indexes which one owns keyboard
// focus. `mode` decides how slots are positioned in CSS grid. `activeId`
// (kept in top-level state for back-compat with readers like RightPane and
// the hotkey cycler) is always synced to `visibleIds[focusSlot]`.
export type LayoutMode =
  | "single"
  | "stack"
  | "columns"
  | "grid2x2"
  | "main-side";
export interface Layout {
  mode: LayoutMode;
  visibleIds: string[];
  focusSlot: number;
}
export const LAYOUT_CAP = 4;

// What modes are visually defined for N visible panes. Used by the layout
// switcher to grey out invalid choices and by reducers to fall back when
// the user shrinks the pane count below the current mode's minimum.
export function validLayoutModes(count: number): LayoutMode[] {
  if (count <= 1) return ["single"];
  if (count === 2) return ["stack", "columns"];
  if (count === 3) return ["stack", "columns", "main-side"];
  return ["stack", "columns", "grid2x2", "main-side"];
}

// Auto-pick when the count changes (push/close) and the current mode is
// no longer valid. The choices mirror the sketches: 1 pane = single,
// 2 = stack (vertical), 3 = main+side, 4 = 2×2 grid.
export function defaultLayoutMode(count: number): LayoutMode {
  if (count <= 1) return "single";
  if (count === 2) return "stack";
  if (count === 3) return "main-side";
  return "grid2x2";
}

function reflowMode(current: LayoutMode, newCount: number): LayoutMode {
  if (validLayoutModes(newCount).includes(current)) return current;
  return defaultLayoutMode(newCount);
}

const EMPTY_LAYOUT: Layout = { mode: "single", visibleIds: [], focusSlot: 0 };

function latestSessionIdForProject(
  sessions: Record<string, SessionView>,
  projectId: string | null,
): string | null {
  if (!projectId) return null;
  return (
    Object.values(sessions)
      .filter((s) => s.project_id === projectId)
      .sort((a, b) => b.updated_at_ms - a.updated_at_ms)[0]?.id ?? null
  );
}

function layoutForProject(
  sessions: Record<string, SessionView>,
  projectId: string | null,
  cached: Layout | undefined,
): Layout {
  if (!projectId) return EMPTY_LAYOUT;

  if (cached) {
    const visibleIds = cached.visibleIds.filter(
      (id) => sessions[id]?.project_id === projectId,
    );
    if (visibleIds.length > 0) {
      const focusSlot = Math.min(cached.focusSlot, visibleIds.length - 1);
      return {
        mode: reflowMode(cached.mode, visibleIds.length),
        visibleIds,
        focusSlot,
      };
    }
  }

  const nextActiveId = latestSessionIdForProject(sessions, projectId);
  return nextActiveId
    ? { mode: "single", visibleIds: [nextActiveId], focusSlot: 0 }
    : EMPTY_LAYOUT;
}

function activeIdFromLayout(layout: Layout): string | null {
  return layout.visibleIds[layout.focusSlot] ?? null;
}

// Persist the active project so reopening the app restores the user's last
// pick instead of jumping to whichever project happens to be first in the
// backend list (currently the newest by `created_at`).
const ACTIVE_PROJECT_STORAGE_KEY = "ycode-active-project";

function readStoredActiveProjectId(): string | null {
  if (typeof window === "undefined") return null;
  try {
    return window.localStorage.getItem(ACTIVE_PROJECT_STORAGE_KEY);
  } catch {
    return null;
  }
}

function writeStoredActiveProjectId(id: string | null) {
  if (typeof window === "undefined") return;
  try {
    if (id === null) {
      window.localStorage.removeItem(ACTIVE_PROJECT_STORAGE_KEY);
    } else {
      window.localStorage.setItem(ACTIVE_PROJECT_STORAGE_KEY, id);
    }
  } catch {
    /* quota / privacy mode — best effort */
  }
}

interface AppState {
  projects: Record<string, ProjectView>;
  /// When non-null, this window is a detached "single project" window —
  /// only this project's tab is rendered, the new-project "+" is hidden,
  /// and the user can't switch away. Seeded once from the URL at startup.
  lockedProjectId: string | null;
  /// Project ids currently owned by other live windows. Removed from this
  /// window's project tab strip so the same project never appears twice.
  /// Pure UI state — not persisted (a relaunch always reconciles via
  /// `getAllWebviewWindows`).
  lockedByOtherWindows: Record<string, true>;
  /// Configured agent launch profiles (from `~/.config/ycode/config.json`
  /// + the shipped defaults). Loaded once at startup. Drives both the new-
  /// session picker and icon resolution everywhere.
  agents: AgentProfileView[];
  sessions: Record<string, SessionView>;
  /// Live CLI window titles harvested from OSC 0/1/2 — preferred over the
  /// persisted SessionView.title when present. Reset on session removal.
  /// Volatile (not persisted): app reload starts empty until the CLI re-emits.
  liveTitles: Record<string, string>;
  /// Derived from `layout.visibleIds[layout.focusSlot]`. Kept as top-level
  /// state so readers (RightPane terminal label, ⌘W archive, etc.) don't all
  /// have to reach into layout. Layout reducers are the only writers; never
  /// call `setActiveId` from new code — use the layout actions instead.
  activeId: string | null;
  /// Middle-pane layout: which sessions are visible, in what arrangement,
  /// and which one has keyboard focus. Hidden sessions stay alive in
  /// `sessions{}` — closing a slot does NOT kill the PTY.
  layout: Layout;
  /// Last visible terminal layout per project tab. Switching projects restores
  /// the project's prior panes instead of collapsing to one session.
  layoutsByProject: Record<string, Layout>;
  /// The project currently scoped for new-session creation. Top-bar project
  /// tabs select this.
  activeProjectId: string | null;
  /// Which panel the right column is showing.
  rightTab: RightTab;
  /// Editor tab strip — paths of all open files, in tab order. The currently
  /// focused file is `selectedFilePath`; tabs persist across right-tab
  /// switches but are cleared when the active project changes.
  openFiles: string[];
  /// File picked from the Files tab — drives which Editor tab is focused.
  /// Path is forward-slash, relative to the active project's repo root.
  selectedFilePath: string | null;
  /// Paths with unsaved edits. Drives the "M" badge on editor tabs and the
  /// "discard changes?" confirm on close. Cleared on successful save.
  dirtyFiles: Record<string, true>;
  /// VS Code-style "preview" tab — at most one. Opened by single-click in
  /// the file tree; single-clicking another file replaces it instead of
  /// appending a new tab. Promoted to a permanent tab on double-click,
  /// first edit, or any tab interaction.
  previewFilePath: string | null;
  /// Per-layer font sizes, mirroring the backend config. UI maps to a CSS
  /// variable that the chrome panels consume; editor flows into the
  /// CodeMirror inline style; terminal feeds xterm options. Defaults until
  /// the initial `getConfig` IPC returns.
  fontSizes: FontSizesView;
  /// Active theme id (Foundry / Midnight / Forest / Parchment / Daylight).
  /// Looked up in `lib/themes.ts` — unknown ids gracefully fall back to the
  /// default at render time so a stale config file can't softlock the UI.
  /// `App.tsx` writes the resolved theme's CSS variable map to `:root` on
  /// change; TerminalPane / ManualTerminal re-skin live xterm instances.
  theme: string;
  /// Sessions that fired an `AgentTurnComplete` (turn ended / needs input)
  /// while the user wasn't looking at them. Drives the dot badge on visible
  /// pane headers and cleared when the session becomes the active pane.
  /// In-memory only — re-emitted by the CLI on the next event after a
  /// reload.
  attentionBySession: Record<string, true>;
  /// Focus-independent per-session activity backing the status light. Unlike
  /// `attentionBySession` (an unread badge that clears on focus), this stays
  /// "waiting" until the agent actually resumes — `AgentTurnComplete` sets
  /// "waiting", the next `PtyOutput` flips it back to "running". A session
  /// with no entry yet is rendered as "running" by `sessionLight`. In-memory
  /// only; reconstructed from live events after a reload.
  activityBySession: Record<string, SessionActivity>;
  /// Per-project todo lists, keyed by project id. Fetched lazily when the
  /// Todo tab is opened and refreshed on every `TodosChanged` event (which
  /// fires for both UI edits and MCP-driven changes from an AI agent).
  todos: Record<string, TodoView[]>;

  setAgents: (list: AgentProfileView[]) => void;
  setProjects: (list: ProjectView[]) => void;
  upsertProject: (p: ProjectView) => void;
  removeProject: (id: string) => void;
  setActiveProjectId: (id: string | null) => void;
  /// One-shot at startup. Locks this window to a single project and forces
  /// the active selection to it.
  setLockedProjectId: (id: string | null) => void;
  /// Seed the peer-owned set from a snapshot.
  setLockedByOtherWindows: (ids: string[]) => void;
  /// Mark a project as taken by a peer window. Auto-switches the active
  /// project away when we were currently looking at it.
  addLockedByOther: (id: string) => void;
  /// Release a project that a peer window just closed.
  removeLockedByOther: (id: string) => void;
  setRightTab: (tab: RightTab) => void;
  setTodos: (projectId: string, list: TodoView[]) => void;
  setSessions: (list: SessionView[]) => void;
  upsertSession: (s: SessionView) => void;
  removeSession: (id: string) => void;
  /// Legacy entry point. Routes to `replaceFocusedSlot` (id) or clears the
  /// layout (null). Prefer the explicit layout actions in new code.
  setActiveId: (id: string | null) => void;
  /// New-session path: focus if already visible, push a new slot if under
  /// the cap, replace the focused slot if at cap.
  openSessionInLayout: (id: string) => void;
  /// Stronger split-on-create variant used by the ⌘N hotkey: never reuses
  /// the focused slot even when its session is dead. Always grows the pane
  /// count unless we're already at [`LAYOUT_CAP`].
  appendSessionToLayout: (id: string) => void;
  /// Show the new-session picker by hiding visible panes without killing
  /// their PTYs. The sessions stay in `sessions{}` and can be reopened.
  showNewSessionPicker: () => void;
  /// Sidebar/hotkey-driven swap: replace the currently focused slot with
  /// this session (or just focus it if it's already visible). Never grows
  /// the pane count.
  replaceFocusedSlot: (id: string) => void;
  /// Hide a pane (no PTY kill). Reflows the layout for the new count and
  /// jumps focus to a neighbour.
  closeLayoutSlot: (slotIdx: number) => void;
  /// Move keyboard focus between visible panes.
  focusLayoutSlot: (slotIdx: number) => void;
  /// User-driven layout choice from the layout switcher. Silently ignored
  /// when the requested mode isn't valid for the current pane count.
  setLayoutMode: (mode: LayoutMode) => void;
  setSelectedFilePath: (path: string | null) => void;
  setFileDirty: (path: string, dirty: boolean) => void;
  /// Open a file in the editor tab strip and focus it. `preview: true`
  /// reuses the existing preview tab (single-click in file tree);
  /// `preview: false` pins the file (double-click, programmatic open).
  /// When omitted the file is opened permanently.
  openFile: (path: string, opts?: { preview?: boolean }) => void;
  /// Close a tab; picks an adjacent neighbour as the new focus if the closed
  /// tab was selected.
  closeFile: (path: string) => void;
  setLiveTitle: (sessionId: string, title: string) => void;
  setFontSizes: (f: FontSizesView) => void;
  setTheme: (id: string) => void;
  /// Sidebar publishes the id of the agent profile currently highlighted
  /// in the agent-tab strip — the same one the "+" button creates against.
  /// Used by the ⌘N hotkey, which builds the createSession call itself
  /// rather than firing a Sidebar-owned thunk (function values living in
  /// the store turned out to capture stale React closures on dependency
  /// changes; a plain string id steers clear of that whole class of bug).
  activeSidebarAgentId: string | null;
  setActiveSidebarAgentId: (id: string | null) => void;
  /// Mark a session as needing attention (caller filters by focus state to
  /// avoid badging the pane the user is already watching).
  markAttention: (sessionId: string) => void;
  /// Clear the attention badge for a session. Called when the session becomes
  /// active or when the user otherwise acknowledges the event.
  clearAttention: (sessionId: string) => void;
  /// Set a session's activity for the status light. No-op when unchanged so
  /// the high-frequency `PtyOutput` stream doesn't thrash subscribers.
  setActivity: (sessionId: string, activity: SessionActivity) => void;
}

export const useStore = create<AppState>((set) => ({
  projects: {},
  lockedProjectId: null,
  lockedByOtherWindows: {},
  agents: [],
  sessions: {},
  liveTitles: {},
  activeId: null,
  layout: EMPTY_LAYOUT,
  layoutsByProject: {},
  activeProjectId: null,
  rightTab: "files",
  openFiles: [],
  selectedFilePath: null,
  dirtyFiles: {},
  previewFilePath: null,
  fontSizes: DEFAULT_FONT_SIZES,
  theme: DEFAULT_THEME_ID,
  activeSidebarAgentId: null,
  attentionBySession: {},
  activityBySession: {},
  todos: {},

  setTodos: (projectId, list) =>
    set((state) => ({ todos: { ...state.todos, [projectId]: list } })),

  markAttention: (sessionId) =>
    set((state) => {
      if (state.attentionBySession[sessionId]) return state;
      return {
        attentionBySession: {
          ...state.attentionBySession,
          [sessionId]: true as const,
        },
      };
    }),

  clearAttention: (sessionId) =>
    set((state) => {
      if (!state.attentionBySession[sessionId]) return state;
      const next = { ...state.attentionBySession };
      delete next[sessionId];
      return { attentionBySession: next };
    }),

  setActivity: (sessionId, activity) =>
    set((state) => {
      if (state.activityBySession[sessionId] === activity) return state;
      return {
        activityBySession: {
          ...state.activityBySession,
          [sessionId]: activity,
        },
      };
    }),

  setAgents: (list) => set({ agents: list }),

  setProjects: (list) =>
    set((state) => {
      const projects = Object.fromEntries(list.map((p) => [p.id, p]));
      // A detached single-project window forces its lock no matter what
      // localStorage thinks — that URL is the source of truth.
      if (state.lockedProjectId && projects[state.lockedProjectId]) {
        return { projects, activeProjectId: state.lockedProjectId };
      }
      // Preference order: current selection (still valid) → last-selected from
      // localStorage (survives reloads) → newest project as a final fallback.
      // Skip projects already owned by a peer window so the main window never
      // auto-selects a tab it's about to hide.
      const stored = readStoredActiveProjectId();
      const isFree = (id: string | null) =>
        !!id && !!projects[id] && !state.lockedByOtherWindows[id];
      const fallback = list.find((p) => !state.lockedByOtherWindows[p.id])?.id ?? null;
      const activeProjectId = isFree(state.activeProjectId)
        ? state.activeProjectId
        : isFree(stored)
          ? stored
          : fallback;
      writeStoredActiveProjectId(activeProjectId);
      return { projects, activeProjectId };
    }),

  upsertProject: (p) =>
    set((state) => {
      const activeProjectId = state.activeProjectId ?? p.id;
      if (activeProjectId !== state.activeProjectId) {
        writeStoredActiveProjectId(activeProjectId);
      }
      return {
        projects: { ...state.projects, [p.id]: p },
        activeProjectId,
      };
    }),

  removeProject: (id) =>
    set((state) => {
      const projects = { ...state.projects };
      delete projects[id];
      const wasActive = state.activeProjectId === id;
      if (wasActive) writeStoredActiveProjectId(null);
      const layoutsByProject = { ...state.layoutsByProject };
      delete layoutsByProject[id];
      return {
        projects,
        layoutsByProject,
        activeProjectId: wasActive ? null : state.activeProjectId,
        // The terminal id would point at a now-orphaned session if its project
        // was the one we just removed.
        activeId: wasActive ? null : state.activeId,
        layout: wasActive ? EMPTY_LAYOUT : state.layout,
      };
    }),

  setActiveProjectId: (id) =>
    set((state) => {
      const same = state.activeProjectId === id;
      if (!same) writeStoredActiveProjectId(id);
      const layoutsByProject =
        !same && state.activeProjectId
          ? { ...state.layoutsByProject, [state.activeProjectId]: state.layout }
          : state.layoutsByProject;
      const layout = same
        ? state.layout
        : layoutForProject(state.sessions, id, layoutsByProject[id ?? ""]);
      return {
        activeProjectId: id,
        activeId: activeIdFromLayout(layout),
        layout,
        layoutsByProject,
        // File selection + open editor tabs are project-scoped — paths from
        // project A don't make sense in project B.
        selectedFilePath: same ? state.selectedFilePath : null,
        openFiles: same ? state.openFiles : [],
        dirtyFiles: same ? state.dirtyFiles : {},
        previewFilePath: same ? state.previewFilePath : null,
      };
    }),

  setLockedProjectId: (id) => set({ lockedProjectId: id }),

  setLockedByOtherWindows: (ids) =>
    set(() => ({
      lockedByOtherWindows: Object.fromEntries(ids.map((id) => [id, true])),
    })),

  addLockedByOther: (id) =>
    set((state) => {
      const lockedByOtherWindows = { ...state.lockedByOtherWindows, [id]: true as const };
      // If the user happened to be looking at the project that just got
      // detached, jump to any remaining visible project so the middle pane
      // doesn't keep rendering data from a now-hidden tab.
      if (state.activeProjectId === id && state.lockedProjectId === null) {
        const nextActive =
          Object.values(state.projects)
            .map((p) => p.id)
            .find((pid) => pid !== id && !lockedByOtherWindows[pid]) ?? null;
        writeStoredActiveProjectId(nextActive);
        const layout = layoutForProject(
          state.sessions,
          nextActive,
          state.layoutsByProject[nextActive ?? ""],
        );
        return {
          lockedByOtherWindows,
          activeProjectId: nextActive,
          activeId: activeIdFromLayout(layout),
          layout,
          selectedFilePath: null,
          openFiles: [],
          dirtyFiles: {},
          previewFilePath: null,
        };
      }
      return { lockedByOtherWindows };
    }),

  removeLockedByOther: (id) =>
    set((state) => {
      if (!state.lockedByOtherWindows[id]) return state;
      const lockedByOtherWindows = { ...state.lockedByOtherWindows };
      delete lockedByOtherWindows[id];
      return { lockedByOtherWindows };
    }),

  setRightTab: (tab) => set({ rightTab: tab }),

  setSessions: (list) =>
    set(() => ({
      sessions: Object.fromEntries(list.map((s) => [s.id, s])),
    })),

  upsertSession: (s) =>
    set((state) => ({ sessions: { ...state.sessions, [s.id]: s } })),

  removeSession: (id) =>
    set((state) => {
      const sessions = { ...state.sessions };
      delete sessions[id];
      const liveTitles = { ...state.liveTitles };
      delete liveTitles[id];
      const attentionBySession = state.attentionBySession[id]
        ? (() => {
            const next = { ...state.attentionBySession };
            delete next[id];
            return next;
          })()
        : state.attentionBySession;
      const activityBySession = state.activityBySession[id]
        ? (() => {
            const next = { ...state.activityBySession };
            delete next[id];
            return next;
          })()
        : state.activityBySession;
      // Drop from the layout too — a slot pointing at a removed session
      // would render a blank pane. Reflow mode if the new count needs it.
      const idx = state.layout.visibleIds.indexOf(id);
      let layout = state.layout;
      let activeId = state.activeId === id ? null : state.activeId;
      if (idx >= 0) {
        const visibleIds = state.layout.visibleIds.slice();
        visibleIds.splice(idx, 1);
        if (visibleIds.length === 0) {
          layout = EMPTY_LAYOUT;
          activeId = null;
        } else {
          const focusSlot = Math.min(state.layout.focusSlot, visibleIds.length - 1);
          layout = {
            mode: reflowMode(state.layout.mode, visibleIds.length),
            visibleIds,
            focusSlot,
          };
          activeId = visibleIds[focusSlot];
        }
      }
      return {
        sessions,
        liveTitles,
        layout,
        activeId,
        attentionBySession,
        activityBySession,
      };
    }),

  // Legacy alias. `null` clears the layout; a string id swaps the session
  // into the focused slot (or focuses it if already visible).
  setActiveId: (id) =>
    set((state) => {
      if (id === null) {
        return { activeId: null, layout: EMPTY_LAYOUT };
      }
      const layout = state.layout;
      const existingIdx = layout.visibleIds.indexOf(id);
      if (existingIdx >= 0) {
        return {
          activeId: id,
          layout: { ...layout, focusSlot: existingIdx },
        };
      }
      if (layout.visibleIds.length === 0) {
        return {
          activeId: id,
          layout: { mode: "single", visibleIds: [id], focusSlot: 0 },
        };
      }
      const visibleIds = layout.visibleIds.slice();
      visibleIds[layout.focusSlot] = id;
      return { activeId: id, layout: { ...layout, visibleIds } };
    }),

  appendSessionToLayout: (id) =>
    set((state) => {
      const layout = state.layout;
      const existingIdx = layout.visibleIds.indexOf(id);
      if (existingIdx >= 0) {
        return {
          activeId: id,
          layout: { ...layout, focusSlot: existingIdx },
        };
      }
      if (layout.visibleIds.length < LAYOUT_CAP) {
        const visibleIds = [...layout.visibleIds, id];
        const focusSlot = visibleIds.length - 1;
        return {
          activeId: id,
          layout: {
            mode: reflowMode(layout.mode, visibleIds.length),
            visibleIds,
            focusSlot,
          },
        };
      }
      // At cap — replace the focused slot. Callers should guard against this
      // with their own "at cap" check before invoking; this is just the
      // safety fallback.
      const visibleIds = layout.visibleIds.slice();
      visibleIds[layout.focusSlot] = id;
      return { activeId: id, layout: { ...layout, visibleIds } };
    }),

  showNewSessionPicker: () =>
    set((state) => {
      if (state.layout.visibleIds.length === 0) return state;
      return { activeId: null, layout: EMPTY_LAYOUT };
    }),

  openSessionInLayout: (id) =>
    set((state) => {
      const layout = state.layout;
      const existingIdx = layout.visibleIds.indexOf(id);
      if (existingIdx >= 0) {
        return {
          activeId: id,
          layout: { ...layout, focusSlot: existingIdx },
        };
      }
      // If the focused slot already holds an ended session, reuse that slot.
      // TerminalPane swaps the dead pane out for the NewSessionPicker, so
      // appending here would leave the user staring at two panes (the dead
      // one plus the new one) when they only ever saw the picker.
      const focusedId = layout.visibleIds[layout.focusSlot];
      const focusedSession = focusedId ? state.sessions[focusedId] : undefined;
      if (focusedSession && focusedSession.status.type !== "Running") {
        const visibleIds = layout.visibleIds.slice();
        visibleIds[layout.focusSlot] = id;
        return { activeId: id, layout: { ...layout, visibleIds } };
      }
      if (layout.visibleIds.length < LAYOUT_CAP) {
        const visibleIds = [...layout.visibleIds, id];
        const focusSlot = visibleIds.length - 1;
        return {
          activeId: id,
          layout: {
            mode: reflowMode(layout.mode, visibleIds.length),
            visibleIds,
            focusSlot,
          },
        };
      }
      // At cap — fall back to replace-focused (callers should disable their
      // "+" button before we hit this, but the fallback keeps behavior sane).
      const visibleIds = layout.visibleIds.slice();
      visibleIds[layout.focusSlot] = id;
      return { activeId: id, layout: { ...layout, visibleIds } };
    }),

  replaceFocusedSlot: (id) =>
    set((state) => {
      const layout = state.layout;
      const existingIdx = layout.visibleIds.indexOf(id);
      if (existingIdx >= 0) {
        return {
          activeId: id,
          layout: { ...layout, focusSlot: existingIdx },
        };
      }
      if (layout.visibleIds.length === 0) {
        return {
          activeId: id,
          layout: { mode: "single", visibleIds: [id], focusSlot: 0 },
        };
      }
      const visibleIds = layout.visibleIds.slice();
      visibleIds[layout.focusSlot] = id;
      return { activeId: id, layout: { ...layout, visibleIds } };
    }),

  closeLayoutSlot: (slotIdx) =>
    set((state) => {
      const layout = state.layout;
      if (slotIdx < 0 || slotIdx >= layout.visibleIds.length) return state;
      const visibleIds = layout.visibleIds.slice();
      visibleIds.splice(slotIdx, 1);
      if (visibleIds.length === 0) {
        return { activeId: null, layout: EMPTY_LAYOUT };
      }
      const focusSlot = Math.min(slotIdx, visibleIds.length - 1);
      return {
        activeId: visibleIds[focusSlot],
        layout: {
          mode: reflowMode(layout.mode, visibleIds.length),
          visibleIds,
          focusSlot,
        },
      };
    }),

  focusLayoutSlot: (slotIdx) =>
    set((state) => {
      const layout = state.layout;
      if (slotIdx < 0 || slotIdx >= layout.visibleIds.length) return state;
      return {
        activeId: layout.visibleIds[slotIdx],
        layout: { ...layout, focusSlot: slotIdx },
      };
    }),

  setLayoutMode: (mode) =>
    set((state) => {
      const valid = validLayoutModes(state.layout.visibleIds.length);
      if (!valid.includes(mode)) return state;
      return { layout: { ...state.layout, mode } };
    }),

  setSelectedFilePath: (path) => set({ selectedFilePath: path }),

  setFileDirty: (path, dirty) =>
    set((state) => {
      const dirtyFiles = { ...state.dirtyFiles };
      if (dirty) dirtyFiles[path] = true;
      else delete dirtyFiles[path];
      // First edit promotes the preview tab to permanent (VS Code rule).
      const previewFilePath =
        dirty && state.previewFilePath === path ? null : state.previewFilePath;
      return { dirtyFiles, previewFilePath };
    }),

  openFile: (path, opts) =>
    set((state) => {
      const preview = opts?.preview ?? false;
      const existingIdx = state.openFiles.indexOf(path);

      // Already open — focus only. A permanent open of the current preview
      // path pins it; otherwise the preview slot stays as-is.
      if (existingIdx >= 0) {
        const previewFilePath =
          !preview && state.previewFilePath === path ? null : state.previewFilePath;
        return { selectedFilePath: path, previewFilePath };
      }

      // New file. Preview mode + existing preview slot → reuse that tab's
      // position so we don't pile up half-skimmed previews.
      if (preview && state.previewFilePath) {
        const prevIdx = state.openFiles.indexOf(state.previewFilePath);
        if (prevIdx >= 0) {
          const openFiles = state.openFiles.slice();
          openFiles[prevIdx] = path;
          const dirtyFiles = { ...state.dirtyFiles };
          delete dirtyFiles[state.previewFilePath];
          return {
            openFiles,
            selectedFilePath: path,
            previewFilePath: path,
            dirtyFiles,
          };
        }
      }

      return {
        openFiles: [...state.openFiles, path],
        selectedFilePath: path,
        previewFilePath: preview ? path : state.previewFilePath,
      };
    }),

  closeFile: (path) =>
    set((state) => {
      const idx = state.openFiles.indexOf(path);
      if (idx < 0) return state;
      const openFiles = state.openFiles.filter((p) => p !== path);
      const dirtyFiles = { ...state.dirtyFiles };
      delete dirtyFiles[path];
      let selectedFilePath = state.selectedFilePath;
      if (state.selectedFilePath === path) {
        // Prefer the right neighbour (now at index `idx` after removal),
        // fall back to the left, then null when the strip is empty.
        selectedFilePath = openFiles[idx] ?? openFiles[idx - 1] ?? null;
      }
      const previewFilePath =
        state.previewFilePath === path ? null : state.previewFilePath;
      return { openFiles, selectedFilePath, dirtyFiles, previewFilePath };
    }),

  setLiveTitle: (sessionId, title) =>
    set((state) => ({ liveTitles: { ...state.liveTitles, [sessionId]: title } })),

  setFontSizes: (f) =>
    set(() => ({
      fontSizes: {
        ui: clampFontSize(f.ui),
        editor: clampFontSize(f.editor),
        terminal: clampFontSize(f.terminal),
      },
    })),

  setTheme: (id) =>
    set((state) => (state.theme === id ? state : { theme: id })),

  setActiveSidebarAgentId: (id) => set({ activeSidebarAgentId: id }),
}));

function clampFontSize(n: number): number {
  if (!Number.isFinite(n)) return 13;
  const i = Math.round(n);
  return Math.min(FONT_SIZE_MAX, Math.max(FONT_SIZE_MIN, i));
}

/// Display rule for a session label: the persisted user title wins (their
/// explicit rename should never be silently overridden by the CLI), then the
/// latest CLI-emitted OSC title, then the default "New session".
export function displaySessionTitle(
  session: SessionView,
  liveTitles: Record<string, string>,
): string {
  if (session.title && session.title.trim()) return session.title;
  const live = liveTitles[session.id];
  if (live && live.trim()) return live;
  return "New session";
}

/// Index `agents` by launch-profile id (e.g. "claude-code").
export function useAgentByProfileId(
  id: string | null | undefined,
): AgentProfileView | null {
  const agents = useStore((s) => s.agents);
  const map = useMemo(() => {
    const out: Record<string, AgentProfileView> = {};
    for (const a of agents) out[a.id] = a;
    return out;
  }, [agents]);
  if (!id) return null;
  return map[id] ?? null;
}

/// Index `agents` by introspect parser id (e.g. "claude"). When several
/// profiles bind to the same parser the first wins — that's the entry
/// callers should resume against when the user clicks a discovered jsonl.
export function useAgentByIntrospect(
  introspect: string | null | undefined,
): AgentProfileView | null {
  const agents = useStore((s) => s.agents);
  const map = useMemo(() => {
    const out: Record<string, AgentProfileView> = {};
    for (const a of agents) {
      if (a.introspect && !(a.introspect in out)) out[a.introspect] = a;
    }
    return out;
  }, [agents]);
  if (!introspect) return null;
  return map[introspect] ?? null;
}
