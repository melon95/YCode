// Single Zustand store backing the whole app. Components subscribe via
// selectors so they only re-render when the slice they care about moves.

import { create } from "zustand";
import type { ProjectView, SessionView } from "./types";

export type RightTab = "files" | "editor" | "terminal";

interface AppState {
  projects: Record<string, ProjectView>;
  sessions: Record<string, SessionView>;
  /// Live CLI window titles harvested from OSC 0/1/2 — preferred over the
  /// persisted SessionView.title when present. Reset on session removal.
  /// Volatile (not persisted): app reload starts empty until the CLI re-emits.
  liveTitles: Record<string, string>;
  activeId: string | null;
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
  /// Open editor files with unsaved edits, keyed by relative path.
  dirtyFiles: Record<string, true>;

  setProjects: (list: ProjectView[]) => void;
  upsertProject: (p: ProjectView) => void;
  removeProject: (id: string) => void;
  setActiveProjectId: (id: string | null) => void;
  setRightTab: (tab: RightTab) => void;
  setSessions: (list: SessionView[]) => void;
  upsertSession: (s: SessionView) => void;
  removeSession: (id: string) => void;
  setActiveId: (id: string | null) => void;
  setSelectedFilePath: (path: string | null) => void;
  setFileDirty: (path: string, dirty: boolean) => void;
  /// Open a file in the editor tab strip (adds it if not present) and focus it.
  openFile: (path: string) => void;
  /// Close a tab; picks an adjacent neighbour as the new focus if the closed
  /// tab was selected.
  closeFile: (path: string) => void;
  setLiveTitle: (sessionId: string, title: string) => void;
}

export const useStore = create<AppState>((set) => ({
  projects: {},
  sessions: {},
  liveTitles: {},
  activeId: null,
  activeProjectId: null,
  rightTab: "files",
  openFiles: [],
  selectedFilePath: null,
  dirtyFiles: {},

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
      return {
        activeProjectId: id,
        activeId: nextActiveId,
        // File selection + open editor tabs are project-scoped — paths from
        // project A don't make sense in project B.
        selectedFilePath: same ? state.selectedFilePath : null,
        openFiles: same ? state.openFiles : [],
        dirtyFiles: same ? state.dirtyFiles : {},
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
      return {
        sessions,
        liveTitles,
        activeId: state.activeId === id ? null : state.activeId,
      };
    }),

  setActiveId: (id) => set({ activeId: id }),

  setSelectedFilePath: (path) => set({ selectedFilePath: path }),

  setFileDirty: (path, dirty) =>
    set((state) => {
      const dirtyFiles = { ...state.dirtyFiles };
      if (dirty) dirtyFiles[path] = true;
      else delete dirtyFiles[path];
      return { dirtyFiles };
    }),

  openFile: (path) =>
    set((state) => {
      const openFiles = state.openFiles.includes(path)
        ? state.openFiles
        : [...state.openFiles, path];
      return { openFiles, selectedFilePath: path };
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
      return { openFiles, selectedFilePath, dirtyFiles };
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
