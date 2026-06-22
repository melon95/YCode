// Thin wrapper around Tauri commands and events. Each export mirrors one
// #[tauri::command] in `src-tauri/src/commands.rs`; regenerate ts-rs
// bindings if the Rust signatures change.

import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import type {
  AgentProfileView,
  ConfigView,
  DiscoveredSessionView,
  SearchHit,
  SessionView,
  ProjectView,
  TodoView,
  UnifiedEvent,
  WriteFileRequest,
  CreateProjectRequest,
  CreateSessionRequest,
  RenameSessionRequest,
  WritePtyRequest,
  ResizePtyRequest,
  SpawnPtyRequest,
  FileEntry,
  FileContents,
  GitFileChange,
  LspManifestView,
  OpenInExternalEditorRequest,
  UiEvent,
  WorkspaceUsageView,
} from "./types";

export const listAgents = (): Promise<AgentProfileView[]> => invoke("list_agents");

export const getConfig = (): Promise<ConfigView> => invoke("get_config");

export const saveConfig = (config: ConfigView): Promise<AgentProfileView[]> =>
  invoke("save_config", { config });

export const resetConfig = (): Promise<AgentProfileView[]> => invoke("reset_config");

export const probeCommand = (command: string): Promise<boolean> =>
  invoke("probe_command", { command });

export const listSessions = (): Promise<SessionView[]> => invoke("list_sessions");

export const listProjects = (): Promise<ProjectView[]> => invoke("list_projects");

export const createProject = (request: CreateProjectRequest): Promise<ProjectView> =>
  invoke("create_project", { request });

export const deleteProject = (projectId: string): Promise<void> =>
  invoke("delete_project", { projectId });

export const listTodos = (projectId: string): Promise<TodoView[]> =>
  invoke("list_todos", { projectId });

export const createTodo = (projectId: string, title: string): Promise<TodoView> =>
  invoke("create_todo", { projectId, title });

export const updateTodo = (
  id: string,
  patch: { title?: string | null; status?: string | null },
): Promise<TodoView> =>
  invoke("update_todo", {
    id,
    title: patch.title ?? null,
    status: patch.status ?? null,
  });

export const deleteTodo = (id: string): Promise<void> =>
  invoke("delete_todo", { id });

export const createSession = (
  request: Omit<CreateSessionRequest, "resume"> & { resume?: string | null },
): Promise<SessionView> =>
  invoke("create_session", {
    request: { resume: null, ...request },
  });

export const writePty = (request: WritePtyRequest): Promise<void> =>
  invoke("write_pty", { request });

/**
 * Pull the backend's rolling PTY scrollback (base64-encoded raw bytes) so a
 * freshly mounted xterm can replay what already happened in the session
 * before it attached. Returns "" when the backlog is empty (or "" base64).
 */
export const readPtyBacklog = (sessionId: string): Promise<string> =>
  invoke("read_pty_backlog", { sessionId });

export const resizePty = (request: ResizePtyRequest): Promise<void> =>
  invoke("resize_pty", { request });

export const killSession = (sessionId: string): Promise<void> =>
  invoke("kill_session", { sessionId });

export const archiveSession = (sessionId: string): Promise<void> =>
  invoke("archive_session", { sessionId });

export const restartSession = (sessionId: string): Promise<SessionView> =>
  invoke("restart_session", { sessionId });

export const renameSession = (request: RenameSessionRequest): Promise<SessionView> =>
  invoke("rename_session", { request });

export const listFiles = (projectId: string): Promise<FileEntry[]> =>
  invoke("list_files", { projectId });

export const readFile = (
  projectId: string,
  filePath: string,
): Promise<FileContents> =>
  invoke("read_file", { projectId, filePath });

/**
 * Read a file as a base64 `data:` URL (MIME inferred from extension) so the
 * editor can render images/SVGs inline via an <img> tag.
 */
export const readFileDataUrl = (
  projectId: string,
  filePath: string,
): Promise<string> =>
  invoke("read_file_data_url", { projectId, filePath });

export const writeFile = (request: WriteFileRequest): Promise<void> =>
  invoke("write_file", { request });

export const deletePath = (projectId: string, filePath: string): Promise<void> =>
  invoke("delete_path", { projectId, filePath });

export const renamePath = (
  projectId: string,
  fromPath: string,
  toPath: string,
): Promise<void> => invoke("rename_path", { projectId, fromPath, toPath });

export const createPath = (
  projectId: string,
  filePath: string,
  isDir: boolean,
): Promise<void> => invoke("create_path", { projectId, filePath, isDir });

export const gitStatus = (projectId: string): Promise<GitFileChange[]> =>
  invoke("git_status", { projectId });

export const gitDiffFile = (projectId: string, filePath: string): Promise<string> =>
  invoke("git_diff_file", { projectId, filePath });

export const scanWorkspaceSessions = (
  projectId: string,
): Promise<DiscoveredSessionView[]> =>
  invoke("scan_workspace_sessions", { projectId });

export const getWorkspaceUsage = (
  projectId: string,
): Promise<WorkspaceUsageView> =>
  invoke("get_workspace_usage", { projectId });

export const getAllUsage = (): Promise<WorkspaceUsageView> =>
  invoke("get_all_usage");

export const loadSessionHistory = (
  agent: string,
  sessionId: string,
  jsonlPath: string,
  maxEvents: number,
): Promise<UnifiedEvent[]> =>
  invoke("load_session_history", { agent, sessionId, jsonlPath, maxEvents });

export const searchSessions = (
  projectId: string,
  query: string,
  limit: number,
): Promise<SearchHit[]> =>
  invoke("search_sessions", { projectId, query, limit });

export const startWorkspaceWatch = (projectId: string): Promise<void> =>
  invoke("start_workspace_watch", { projectId });

export const stopWorkspaceWatch = (projectId: string): Promise<void> =>
  invoke("stop_workspace_watch", { projectId });

export const openInExternalEditor = (
  request: OpenInExternalEditorRequest,
): Promise<void> => invoke("fs_open_in_external_editor", { request });

export const revealInFinder = (path: string): Promise<void> =>
  invoke("fs_reveal_in_finder", { path });

/**
 * Open a URL in the system default browser. xterm.js' WebLinksAddon defaults
 * to `window.open(uri)`, which is a no-op in Tauri's WKWebView — so terminals
 * pass this as their custom handler.
 */
export const openUrl = (url: string): Promise<void> =>
  invoke("open_url", { url });

/**
 * Resolve a candidate path scraped from terminal output (absolute, relative,
 * or bare like `src/foo.ts`) to a project-relative path the editor can open.
 * Returns null when the candidate isn't a regular file inside the project —
 * the terminal link provider matches optimistically and uses this to filter.
 */
export const resolveTerminalPath = (
  projectId: string,
  candidate: string,
): Promise<string | null> =>
  invoke("resolve_terminal_path", { projectId, candidate });

export const spawnPtyRaw = (request: SpawnPtyRequest): Promise<string> =>
  invoke("spawn_pty_raw", { request });

export const killPtyRaw = (ptyId: string): Promise<void> =>
  invoke("kill_pty_raw", { ptyId });

// ── Agent hook config (per-agent CLI patches for completion notifications) ──

/**
 * Status returned by the `agent_hook_status` / `agent_install_hook` commands.
 * Discriminated by `agent`; the inner `kind` enum mirrors `HookStatus` (Claude)
 * or `NotifyStatus` (Codex) from the Rust side.
 */
export type AgentPatchStatus =
  | { agent: "claude"; kind: "not_installed" | "installed" }
  | {
      agent: "codex";
      kind: "not_installed" | "installed" | "conflict_user_set";
      existing?: string[];
    };

export const agentHookStatus = (agent: "claude" | "codex"): Promise<AgentPatchStatus> =>
  invoke("agent_hook_status", { agent });

export const agentInstallHook = (agent: "claude" | "codex"): Promise<AgentPatchStatus> =>
  invoke("agent_install_hook", { agent });

export const agentUninstallHook = (agent: "claude" | "codex"): Promise<AgentPatchStatus> =>
  invoke("agent_uninstall_hook", { agent });

/**
 * Wrap an existing user-set Codex notify so YCode fires first and the user's
 * existing tool still runs. Pass the argv we just observed via
 * `agentHookStatus` to avoid a TOCTOU mismatch on the backend.
 */
export const agentInstallCodexChain = (existing: string[]): Promise<AgentPatchStatus> =>
  invoke("agent_install_codex_chain", { existing });

export const testNotification = (): Promise<void> => invoke("test_notification");

// ── ycode-todos MCP server registration (opt-in per agent) ──

export type McpStatus = "not_installed" | "installed";

const unwrapMcpStatus = (s: { kind: McpStatus }): McpStatus => s.kind;

export const mcpStatus = (agent: "claude" | "codex"): Promise<McpStatus> =>
  invoke<{ kind: McpStatus }>("mcp_status", { agent }).then(unwrapMcpStatus);

export const mcpInstall = (agent: "claude" | "codex"): Promise<McpStatus> =>
  invoke<{ kind: McpStatus }>("mcp_install", { agent }).then(unwrapMcpStatus);

export const mcpUninstall = (agent: "claude" | "codex"): Promise<McpStatus> =>
  invoke<{ kind: McpStatus }>("mcp_uninstall", { agent }).then(unwrapMcpStatus);

// ── Language servers ───────────────────────────────────────────────────────

/**
 * Snapshot every built-in LSP manifest merged with the user's local install
 * status. Re-fetch after `LspInstallFinished` or `LspUninstalled` events to
 * pick up the latest install state.
 */
export const lspListManifests = (): Promise<LspManifestView[]> =>
  invoke("lsp_list_manifests");

/**
 * Kick off an install for a given manifest id. Resolves as soon as the
 * background task is spawned; watch the session-event stream for
 * `LspInstallProgress` / `LspInstallFinished` payloads to track progress.
 */
export const lspInstall = (serverId: string): Promise<void> =>
  invoke("lsp_install", { serverId });

export const lspUninstall = (serverId: string): Promise<void> =>
  invoke("lsp_uninstall", { serverId });

/**
 * Tell the matching language server (if any) the user opened a document.
 * Resolves `true` iff a server actually picked it up — `false` means no
 * manifest matched the extension or the matching server isn't installed.
 * The editor should treat `false` as "no LSP features for this file" and
 * skip future `didChange` / definition / semantic-tokens calls for it.
 */
export const lspDidOpen = (
  projectId: string,
  filePath: string,
  content: string,
  version: number,
): Promise<boolean> =>
  invoke("lsp_did_open", { projectId, filePath, content, version });

export const lspDidChange = (
  projectId: string,
  filePath: string,
  version: number,
  content: string,
): Promise<boolean> =>
  invoke("lsp_did_change", { projectId, filePath, version, content });

export const lspDidClose = (projectId: string, filePath: string): Promise<void> =>
  invoke("lsp_did_close", { projectId, filePath });

/** Raw LSP `textDocument/definition` payload. `null` when no server is wired. */
export const lspDefinition = (
  projectId: string,
  filePath: string,
  line: number,
  character: number,
): Promise<unknown> =>
  invoke("lsp_definition", { projectId, filePath, line, character });

export const lspSemanticTokensFull = (
  projectId: string,
  filePath: string,
): Promise<unknown> =>
  invoke("lsp_semantic_tokens_full", { projectId, filePath });

/**
 * Tell the backend which PTY pane is currently focused. The agent-event pump
 * uses this to suppress redundant OS notifications when the user is literally
 * watching the pane that just fired. Pass `null` when no pane is focused
 * (e.g. the user is in Settings or the layout is empty).
 */
export const setActiveTerminal = (sessionId: string | null): Promise<void> =>
  invoke("set_active_terminal", { sessionId });

export const listenSessionEvents = (
  handler: (event: UiEvent) => void,
): Promise<UnlistenFn> =>
  listen<UiEvent>("ycode://session", (msg) => handler(msg.payload));
