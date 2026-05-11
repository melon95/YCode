// Single Zustand store backing the whole app. Components subscribe via
// selectors so they only re-render when the slice they care about moves.

import { create } from "zustand";
import type { ProjectView, SessionView } from "./types";

export type SidebarTab = "sessions" | "files" | "diff";

interface AppState {
  projects: Record<string, ProjectView>;
  sessions: Record<string, SessionView>;
  activeId: string | null;
  /// The project currently scoped for new-session creation. Top-bar project
  /// tabs select this.
  activeProjectId: string | null;
  /// Which panel the left sidebar is showing under the active project.
  sidebarTab: SidebarTab;
  /// File picked from the Files tab — drives the Diff tab's content.
  /// Path is forward-slash, relative to the active project's repo root.
  selectedFilePath: string | null;

  setProjects: (list: ProjectView[]) => void;
  upsertProject: (p: ProjectView) => void;
  removeProject: (id: string) => void;
  setActiveProjectId: (id: string | null) => void;
  setSidebarTab: (tab: SidebarTab) => void;
  setSessions: (list: SessionView[]) => void;
  upsertSession: (s: SessionView) => void;
  removeSession: (id: string) => void;
  setActiveId: (id: string | null) => void;
  setSelectedFilePath: (path: string | null) => void;
}

export const useStore = create<AppState>((set) => ({
  projects: {},
  sessions: {},
  activeId: null,
  activeProjectId: null,
  sidebarTab: "sessions",
  selectedFilePath: null,

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
      return {
        projects,
        activeProjectId:
          state.activeProjectId === id ? null : state.activeProjectId,
      };
    }),

  setActiveProjectId: (id) =>
    set((state) => ({
      activeProjectId: id,
      // File selection is project-scoped — paths from project A don't make
      // sense in project B.
      selectedFilePath: state.activeProjectId === id ? state.selectedFilePath : null,
    })),

  setSidebarTab: (tab) => set({ sidebarTab: tab }),

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
      return {
        sessions,
        activeId: state.activeId === id ? null : state.activeId,
      };
    }),

  setActiveId: (id) => set({ activeId: id }),

  setSelectedFilePath: (path) => set({ selectedFilePath: path }),
}));
