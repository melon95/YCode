// Single Zustand store backing the whole app. Components subscribe via
// selectors so they only re-render when the slice they care about moves.
//
// Data model is plain `Record<string, T>` rather than `Map`, because (a)
// Zustand's reference-equality change detection works naturally with
// spread/delete, and (b) selectors that derive arrays via `Object.values`
// stay one-liners.

import { create } from "zustand";
import type { AgentEvent, PermissionOption, SessionView } from "./types";

export type PermissionRequest = {
  sessionId: string;
  requestId: string;
  toolName: string;
  summary: string;
  options: PermissionOption[];
};

interface AppState {
  sessions: Record<string, SessionView>;
  events: Record<string, AgentEvent[]>;
  activeId: string | null;
  permissions: Record<string, PermissionRequest>;

  setSessions: (list: SessionView[]) => void;
  upsertSession: (s: SessionView) => void;
  removeSession: (id: string) => void;
  setActiveId: (id: string | null) => void;
  setEvents: (id: string, events: AgentEvent[]) => void;
  clearPermission: (id: string) => void;
  applyAgentEvent: (id: string, event: AgentEvent) => void;
}

export const useStore = create<AppState>((set) => ({
  sessions: {},
  events: {},
  activeId: null,
  permissions: {},

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
      const events = { ...state.events };
      delete events[id];
      const permissions = { ...state.permissions };
      delete permissions[id];
      return {
        sessions,
        events,
        permissions,
        activeId: state.activeId === id ? null : state.activeId,
      };
    }),

  setActiveId: (id) => set({ activeId: id }),

  setEvents: (id, events) =>
    set((state) => ({ events: { ...state.events, [id]: events } })),

  clearPermission: (id) =>
    set((state) => {
      const permissions = { ...state.permissions };
      delete permissions[id];
      return { permissions };
    }),

  applyAgentEvent: (id, event) =>
    set((state) => {
      const newEvents = {
        ...state.events,
        [id]: [...(state.events[id] ?? []), event],
      };
      let newSessions = state.sessions;
      let newPermissions = state.permissions;
      if (event.kind === "StateChanged" && state.sessions[id]) {
        newSessions = {
          ...state.sessions,
          [id]: { ...state.sessions[id], state: event.state },
        };
      } else if (event.kind === "RequestPermission") {
        newPermissions = {
          ...state.permissions,
          [id]: {
            sessionId: id,
            requestId: event.request_id,
            toolName: event.tool_name,
            summary: event.summary,
            options: event.options,
          },
        };
      }
      return {
        events: newEvents,
        sessions: newSessions,
        permissions: newPermissions,
      };
    }),
}));
