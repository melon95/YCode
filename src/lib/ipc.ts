// Thin wrapper around Tauri commands and events. Every export here mirrors
// exactly one #[tauri::command] in `src-tauri/src/commands.rs`; if the Rust
// signature changes, regenerate the ts-rs bindings and update this file.

import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import type {
  AgentProfileView,
  SessionView,
  CreateSessionRequest,
  SendPromptRequest,
  AnswerPermissionRequest,
  ReplayRequest,
  ReplayEntry,
  UiEvent,
} from "./types";

export const listAgents = (): Promise<AgentProfileView[]> => invoke("list_agents");

export const listSessions = (): Promise<SessionView[]> => invoke("list_sessions");

export const createSession = (request: CreateSessionRequest): Promise<SessionView> =>
  invoke("create_session", { request });

export const sendPrompt = (request: SendPromptRequest): Promise<void> =>
  invoke("send_prompt", { request });

export const answerPermission = (request: AnswerPermissionRequest): Promise<void> =>
  invoke("answer_permission", { request });

export const cancelSession = (sessionId: string): Promise<void> =>
  invoke("cancel_session", { sessionId });

export const archiveSession = (sessionId: string, deleteBranch = false): Promise<void> =>
  invoke("archive_session", { sessionId, deleteBranch });

export const restartSession = (sessionId: string): Promise<SessionView> =>
  invoke("restart_session", { sessionId });

export const replayEvents = (request: ReplayRequest): Promise<ReplayEntry[]> =>
  invoke("replay_events", { request });

export const listenSessionEvents = (
  handler: (event: UiEvent) => void,
): Promise<UnlistenFn> =>
  listen<UiEvent>("ycode://session", (msg) => handler(msg.payload));
