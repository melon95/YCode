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
  GitFileDiff,
  GitHunkAction,
  GitBranchInfo,
  GitBranchListView,
  ReviewCheckpointView,
  LspManifestView,
  OpenInExternalEditorRequest,
  UiEvent,
  WorkspaceUsageView,
  WorktreeCloseState,
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

// Persist a manual drag-reorder. `orderedIds` is the full new order of the
// project's todos; each row's sort_order becomes its position in the list.
export const reorderTodos = (
  projectId: string,
  orderedIds: string[],
): Promise<void> =>
  invoke("reorder_todos", { projectId, orderedIds });

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

export const mergeSessionWorktree = (sessionId: string): Promise<void> =>
  invoke("merge_session_worktree", { sessionId });

export const setProjectIsolateSessions = (
  projectId: string,
  isolate: boolean,
): Promise<void> =>
  invoke("set_project_isolate_sessions", { projectId, isolate });

export const stopSessionForClose = (
  sessionId: string,
): Promise<WorktreeCloseState> =>
  invoke("stop_session_for_close", { sessionId });

export const renameSession = (request: RenameSessionRequest): Promise<SessionView> =>
  invoke("rename_session", { request });

export const listFiles = (
  projectId: string,
  sessionId?: string,
): Promise<FileEntry[]> =>
  invoke("list_files", { projectId, sessionId: sessionId ?? null });

export const readFile = (
  projectId: string,
  filePath: string,
  sessionId?: string,
): Promise<FileContents> =>
  invoke("read_file", { projectId, sessionId: sessionId ?? null, filePath });

/**
 * Read a file as a base64 `data:` URL (MIME inferred from extension) so the
 * editor can render images/SVGs inline via an <img> tag.
 */
export const readFileDataUrl = (
  projectId: string,
  filePath: string,
  sessionId?: string,
): Promise<string> =>
  invoke("read_file_data_url", {
    projectId,
    sessionId: sessionId ?? null,
    filePath,
  });

export const writeFile = (
  request: WriteFileRequest,
  sessionId?: string,
): Promise<void> =>
  invoke("write_file", { request, sessionId: sessionId ?? null });

export const deletePath = (
  projectId: string,
  filePath: string,
  sessionId?: string,
): Promise<void> =>
  invoke("delete_path", { projectId, sessionId: sessionId ?? null, filePath });

export const renamePath = (
  projectId: string,
  fromPath: string,
  toPath: string,
  sessionId?: string,
): Promise<void> =>
  invoke("rename_path", {
    projectId,
    sessionId: sessionId ?? null,
    fromPath,
    toPath,
  });

export const createPath = (
  projectId: string,
  filePath: string,
  isDir: boolean,
  sessionId?: string,
): Promise<void> =>
  invoke("create_path", {
    projectId,
    sessionId: sessionId ?? null,
    filePath,
    isDir,
  });

// `sessionId` optionally targets a session's isolated worktree instead of the
// project's main working tree — the Changes panel passes it to view/stage/
// commit an agent's worktree.
export const gitStatus = (
  projectId: string,
  sessionId?: string,
): Promise<GitFileChange[]> =>
  invoke("git_status", { projectId, sessionId: sessionId ?? null });

export const gitBranch = (
  projectId: string,
  sessionId?: string,
): Promise<GitBranchInfo> =>
  invoke("git_branch", { projectId, sessionId: sessionId ?? null });

export const gitDiffFile = (
  projectId: string,
  filePath: string,
  sessionId?: string,
): Promise<GitFileDiff> =>
  invoke("git_diff_file", { projectId, sessionId: sessionId ?? null, filePath });

export const gitBranchStatus = (
  projectId: string,
  sessionId: string,
): Promise<GitFileChange[]> =>
  invoke("git_branch_status", { projectId, sessionId });

export const gitBranchDiffFile = (
  projectId: string,
  sessionId: string,
  filePath: string,
): Promise<GitFileDiff> =>
  invoke("git_branch_diff_file", { projectId, sessionId, filePath });

export const listReviewCheckpoints = (
  projectId: string,
): Promise<ReviewCheckpointView[]> =>
  invoke("list_review_checkpoints", { projectId });

export const gitCheckpointStatus = (
  projectId: string,
  checkpointId: string,
): Promise<GitFileChange[]> =>
  invoke("git_checkpoint_status", { projectId, checkpointId });

export const gitCheckpointDiffFile = (
  projectId: string,
  checkpointId: string,
  filePath: string,
): Promise<GitFileDiff> =>
  invoke("git_checkpoint_diff_file", { projectId, checkpointId, filePath });

export const gitApplyHunk = (
  projectId: string,
  filePath: string,
  patch: string,
  action: GitHunkAction,
  sessionId?: string,
): Promise<void> =>
  invoke("git_apply_hunk", {
    projectId,
    sessionId: sessionId ?? null,
    filePath,
    patch,
    action,
  });

export const gitCommit = (
  projectId: string,
  message: string,
  sessionId?: string,
): Promise<void> =>
  invoke("git_commit", { projectId, sessionId: sessionId ?? null, message });

export const gitStageFile = (
  projectId: string,
  filePath: string,
  sessionId?: string,
): Promise<void> =>
  invoke("git_stage_file", { projectId, sessionId: sessionId ?? null, filePath });

export const gitUnstageFile = (
  projectId: string,
  filePath: string,
  sessionId?: string,
): Promise<void> =>
  invoke("git_unstage_file", {
    projectId,
    sessionId: sessionId ?? null,
    filePath,
  });

export const gitDiscardFile = (
  projectId: string,
  filePath: string,
  sessionId?: string,
): Promise<void> =>
  invoke("git_discard_file", {
    projectId,
    sessionId: sessionId ?? null,
    filePath,
  });

export const gitFetch = (projectId: string, sessionId?: string): Promise<void> =>
  invoke("git_fetch", { projectId, sessionId: sessionId ?? null });

export const gitPull = (projectId: string, sessionId?: string): Promise<void> =>
  invoke("git_pull", { projectId, sessionId: sessionId ?? null });

export const gitPush = (projectId: string, sessionId?: string): Promise<void> =>
  invoke("git_push", { projectId, sessionId: sessionId ?? null });

export const gitListBranches = (
  projectId: string,
  sessionId?: string,
): Promise<GitBranchListView> =>
  invoke("git_list_branches", { projectId, sessionId: sessionId ?? null });

export const gitCheckoutBranch = (
  projectId: string,
  name: string,
  sessionId?: string,
): Promise<void> =>
  invoke("git_checkout_branch", { projectId, sessionId: sessionId ?? null, name });

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
  sessionId?: string,
): Promise<string | null> =>
  invoke("resolve_terminal_path", {
    projectId,
    sessionId: sessionId ?? null,
    candidate,
  });

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

// ── `ycode` shell command (symlink in /usr/local/bin) ──────────────────────

/**
 * State of `/usr/local/bin/ycode`. `stale` means our symlink is there but
 * points at a binary that has since moved (re-installing fixes it);
 * `conflict` means something we didn't create occupies the path and the user
 * has to clear it themselves.
 */
export type CliInstallStatus =
  | { kind: "not_installed" }
  | { kind: "installed"; path: string; target: string }
  | { kind: "stale"; path: string; target: string }
  | { kind: "conflict"; path: string; detail: string };

export const cliStatus = (): Promise<CliInstallStatus> => invoke("cli_status");

/**
 * Create the symlink. macOS/Linux prompt for administrator rights only when
 * `/usr/local/bin` isn't writable by the current user; a cancelled prompt
 * rejects with "authentication was cancelled".
 */
export const cliInstall = (): Promise<CliInstallStatus> => invoke("cli_install");

export const cliUninstall = (): Promise<CliInstallStatus> => invoke("cli_uninstall");

/**
 * Payload of the `ycode://cli-open` event: the shell command was run against
 * `repo_path`, which the backend resolved (or created) as `project_id`.
 * `file` is repo-relative when the user pointed at a file.
 */
export interface CliOpenPayload {
  project_id: string;
  repo_path: string;
  file: string | null;
}

/**
 * Subscribe to `ycode <path>` invocations routed to *this* window. The
 * backend picks the window (the project's detached window when one exists,
 * otherwise main) and emits only there, so no filtering is needed here.
 */
export const listenCliOpen = (
  handler: (payload: CliOpenPayload) => void,
): Promise<UnlistenFn> =>
  listen<CliOpenPayload>("ycode://cli-open", (msg) => handler(msg.payload));

/**
 * Pick up a `ycode <path>` request that arrived while this window's webview was
 * still booting — the cold-start case, where `ycode .` launched the app and the
 * backend answered seconds before React mounted, so the event above had no
 * listener yet. Call once on mount; resolves to `null` in the warm case.
 */
export const takePendingCliOpen = (): Promise<CliOpenPayload | null> =>
  invoke("take_pending_cli_open");

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
  sessionId?: string,
): Promise<boolean> =>
  invoke("lsp_did_open", {
    projectId,
    sessionId: sessionId ?? null,
    filePath,
    content,
    version,
  });

export const lspDidChange = (
  projectId: string,
  filePath: string,
  version: number,
  content: string,
  sessionId?: string,
): Promise<boolean> =>
  invoke("lsp_did_change", {
    projectId,
    sessionId: sessionId ?? null,
    filePath,
    version,
    content,
  });

export const lspDidClose = (
  projectId: string,
  filePath: string,
  sessionId?: string,
): Promise<void> =>
  invoke("lsp_did_close", {
    projectId,
    sessionId: sessionId ?? null,
    filePath,
  });

/** Raw LSP `textDocument/definition` payload. `null` when no server is wired. */
export const lspDefinition = (
  projectId: string,
  filePath: string,
  line: number,
  character: number,
  sessionId?: string,
): Promise<unknown> =>
  invoke("lsp_definition", {
    projectId,
    sessionId: sessionId ?? null,
    filePath,
    line,
    character,
  });

export const lspSemanticTokensFull = (
  projectId: string,
  filePath: string,
  sessionId?: string,
): Promise<unknown> =>
  invoke("lsp_semantic_tokens_full", {
    projectId,
    sessionId: sessionId ?? null,
    filePath,
  });

export const listenSessionEvents = (
  handler: (event: UiEvent) => void,
): Promise<UnlistenFn> =>
  listen<UiEvent>("ycode://session", (msg) => handler(msg.payload));
