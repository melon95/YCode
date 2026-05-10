// Thin wrapper around Tauri commands and events. Each export mirrors one
// #[tauri::command] in `src-tauri/src/commands.rs`; regenerate ts-rs
// bindings if the Rust signatures change.

import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import type {
  AgentProfileView,
  SessionView,
  ProjectView,
  CreateProjectRequest,
  CreateSessionRequest,
  WritePtyRequest,
  ResizePtyRequest,
  UiEvent,
} from "./types";

export const listAgents = (): Promise<AgentProfileView[]> => invoke("list_agents");

export const listSessions = (): Promise<SessionView[]> => invoke("list_sessions");

export const listProjects = (): Promise<ProjectView[]> => invoke("list_projects");

export const createProject = (request: CreateProjectRequest): Promise<ProjectView> =>
  invoke("create_project", { request });

export const deleteProject = (projectId: string): Promise<void> =>
  invoke("delete_project", { projectId });

export const createSession = (request: CreateSessionRequest): Promise<SessionView> =>
  invoke("create_session", { request });

export const writePty = (request: WritePtyRequest): Promise<void> =>
  invoke("write_pty", { request });

export const resizePty = (request: ResizePtyRequest): Promise<void> =>
  invoke("resize_pty", { request });

export const killSession = (sessionId: string): Promise<void> =>
  invoke("kill_session", { sessionId });

export const archiveSession = (sessionId: string): Promise<void> =>
  invoke("archive_session", { sessionId });

export const restartSession = (sessionId: string): Promise<SessionView> =>
  invoke("restart_session", { sessionId });

export const listenSessionEvents = (
  handler: (event: UiEvent) => void,
): Promise<UnlistenFn> =>
  listen<UiEvent>("ycode://session", (msg) => handler(msg.payload));
