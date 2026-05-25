// Single Zustand store backing the whole app. Components subscribe via
// selectors so they only re-render when the slice they care about moves.

import { useMemo } from "react";
import { create } from "zustand";
import type { AgentProfileView, ProjectView, SessionView } from "./types";

export type RightTab = "files" | "editor" | "terminal";

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

interface AppState {
  projects: Record<string, ProjectView>;
  /// Configured agent launch profiles (from `~/.config/ycode/config.toml`
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

  setAgents: (list: AgentProfileView[]) => void;
  setProjects: (list: ProjectView[]) => void;
  upsertProject: (p: ProjectView) => void;
  removeProject: (id: string) => void;
  setActiveProjectId: (id: string | null) => void;
  setRightTab: (tab: RightTab) => void;
  setSessions: (list: SessionView[]) => void;
  upsertSession: (s: SessionView) => void;
  removeSession: (id: string) => void;
  /// Legacy entry point. Routes to `replaceFocusedSlot` (id) or clears the
  /// layout (null). Prefer the explicit layout actions in new code.
  setActiveId: (id: string | null) => void;
  /// New-session path: focus if already visible, push a new slot if under
  /// the cap, replace the focused slot if at cap.
  openSessionInLayout: (id: string) => void;
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
}

export const useStore = create<AppState>((set) => ({
  projects: {},
  agents: [],
  sessions: {},
  liveTitles: {},
  activeId: null,
  layout: EMPTY_LAYOUT,
  activeProjectId: null,
  rightTab: "files",
  openFiles: [],
  selectedFilePath: null,
  dirtyFiles: {},
  previewFilePath: null,

  setAgents: (list) => set({ agents: list }),

  setProjects: (list) =>
    set((state) => {
      const projects = Object.fromEntries(list.map((p) => [p.id, p]));
      const activeProjectId =
        state.activeProjectId && projects[state.activeProjectId]
          ? state.activeProjectId
          : (list[0]?.id ?? null);
      return { projects, activeProjectId };
    }),

  upsertProject: (p) =>
    set((state) => ({
      projects: { ...state.projects, [p.id]: p },
      activeProjectId: state.activeProjectId ?? p.id,
    })),

  removeProject: (id) =>
    set((state) => {
      const projects = { ...state.projects };
      delete projects[id];
      const wasActive = state.activeProjectId === id;
      return {
        projects,
        activeProjectId: wasActive ? null : state.activeProjectId,
        // The terminal id would point at a now-orphaned session if its project
        // was the one we just removed.
        activeId: wasActive ? null : state.activeId,
        layout: wasActive ? EMPTY_LAYOUT : state.layout,
      };
    }),

  setActiveProjectId: (id) =>
    set((state) => {
      // Pick the new project's most-recent session as the active terminal so
      // switching projects actually moves the middle pane (otherwise it keeps
      // showing the previous project's CLI). Null when there are no sessions
      // yet — TerminalPane falls back to the new-session picker.
      const nextActiveId = id
        ? (Object.values(state.sessions)
            .filter((s) => s.project_id === id)
            .sort((a, b) => b.updated_at_ms - a.updated_at_ms)[0]?.id ?? null)
        : null;
      const same = state.activeProjectId === id;
      // Project switch resets the layout: previous panes were scoped to the
      // old project's sessions, which the user probably no longer wants to
      // see. The most-recent session of the new project (if any) seeds a
      // fresh single-pane layout.
      const layout: Layout = nextActiveId
        ? { mode: "single", visibleIds: [nextActiveId], focusSlot: 0 }
        : EMPTY_LAYOUT;
      return {
        activeProjectId: id,
        activeId: nextActiveId,
        layout: same ? state.layout : layout,
        // File selection + open editor tabs are project-scoped — paths from
        // project A don't make sense in project B.
        selectedFilePath: same ? state.selectedFilePath : null,
        openFiles: same ? state.openFiles : [],
        dirtyFiles: same ? state.dirtyFiles : {},
        previewFilePath: same ? state.previewFilePath : null,
      };
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
      return { sessions, liveTitles, layout, activeId };
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
}));

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
