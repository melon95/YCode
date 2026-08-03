//! `#[tauri::command]` wrappers around `Service`. Each command is a one-line
//! delegation — if anything heavier creeps in here, that's a sign the IPC
//! contract has drifted and should be moved back into `ycode-ipc`.

use std::path::PathBuf;

use tauri::{Manager, State};
use tauri_plugin_notification::NotificationExt;
use ycode_config::agent_patcher::{
    self, claude_json_path, claude_settings_path, codex_config_path, HookStatus, McpStatus,
    NotifyStatus,
};
use ycode_config::cli_installer::{self, CliInstallStatus};
use ycode_ipc::{
    AgentProfileView, ConfigView, CreateProjectRequest, CreateSessionRequest,
    DiscoveredSessionView, FileContents, FileEntry, GitBranchInfo, GitBranchListView,
    GitFileChange, GitFileDiff, GitHunkAction, LspManifestView, OpenInExternalEditorRequest,
    ProjectView, RenameSessionRequest, ResizePtyRequest, ReviewCheckpointView, SearchHit,
    SessionView, SpawnPtyRequest, TodoView, UnifiedEvent, WorkspaceUsageView, WorktreeCloseState,
    WriteFileRequest, WritePtyRequest,
};

use crate::state::{AppState, PendingCliOpen};

#[tauri::command]
pub async fn list_agents(state: State<'_, AppState>) -> Result<Vec<AgentProfileView>, String> {
    Ok(state.service.list_agents().await)
}

#[tauri::command]
pub async fn get_config(state: State<'_, AppState>) -> Result<ConfigView, String> {
    Ok(state.service.get_config().await)
}

#[tauri::command]
pub async fn save_config(
    state: State<'_, AppState>,
    config: ConfigView,
) -> Result<Vec<AgentProfileView>, String> {
    state
        .service
        .save_config(config)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn reset_config(state: State<'_, AppState>) -> Result<Vec<AgentProfileView>, String> {
    state
        .service
        .reset_config()
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub fn probe_command(state: State<'_, AppState>, command: String) -> bool {
    state.service.probe_command(&command)
}

#[tauri::command]
pub async fn list_sessions(state: State<'_, AppState>) -> Result<Vec<SessionView>, String> {
    state
        .service
        .list_sessions()
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn create_session(
    state: State<'_, AppState>,
    request: CreateSessionRequest,
) -> Result<SessionView, String> {
    state
        .service
        .create_session(request)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn list_projects(state: State<'_, AppState>) -> Result<Vec<ProjectView>, String> {
    state
        .service
        .list_projects()
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn create_project(
    state: State<'_, AppState>,
    request: CreateProjectRequest,
) -> Result<ProjectView, String> {
    state
        .service
        .create_project(request)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn delete_project(state: State<'_, AppState>, project_id: String) -> Result<(), String> {
    state
        .service
        .delete_project(project_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn list_todos(
    state: State<'_, AppState>,
    project_id: String,
) -> Result<Vec<TodoView>, String> {
    state
        .service
        .list_todos(project_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn create_todo(
    state: State<'_, AppState>,
    project_id: String,
    title: String,
) -> Result<TodoView, String> {
    state
        .service
        .create_todo(project_id, title)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn update_todo(
    state: State<'_, AppState>,
    id: String,
    title: Option<String>,
    status: Option<String>,
) -> Result<TodoView, String> {
    state
        .service
        .update_todo(id, title, status)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn delete_todo(state: State<'_, AppState>, id: String) -> Result<(), String> {
    state
        .service
        .delete_todo(id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn reorder_todos(
    state: State<'_, AppState>,
    project_id: String,
    ordered_ids: Vec<String>,
) -> Result<(), String> {
    state
        .service
        .reorder_todos(project_id, ordered_ids)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn spawn_pty_raw(
    state: State<'_, AppState>,
    request: SpawnPtyRequest,
) -> Result<String, String> {
    state
        .service
        .spawn_pty_raw(request)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn kill_pty_raw(state: State<'_, AppState>, pty_id: String) -> Result<(), String> {
    state
        .service
        .kill_pty_raw(pty_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn write_pty(state: State<'_, AppState>, request: WritePtyRequest) -> Result<(), String> {
    state
        .service
        .write_pty(request)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn read_pty_backlog(
    state: State<'_, AppState>,
    session_id: String,
) -> Result<String, String> {
    state
        .service
        .read_pty_backlog(session_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn resize_pty(
    state: State<'_, AppState>,
    request: ResizePtyRequest,
) -> Result<(), String> {
    state
        .service
        .resize_pty(request)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn kill_session(state: State<'_, AppState>, session_id: String) -> Result<(), String> {
    state
        .service
        .kill_session(session_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn archive_session(state: State<'_, AppState>, session_id: String) -> Result<(), String> {
    state
        .service
        .archive_session(session_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn rename_session(
    state: State<'_, AppState>,
    request: RenameSessionRequest,
) -> Result<SessionView, String> {
    state
        .service
        .rename_session(request)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn restart_session(
    state: State<'_, AppState>,
    session_id: String,
) -> Result<SessionView, String> {
    state
        .service
        .restart_session(session_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn merge_session_worktree(
    state: State<'_, AppState>,
    session_id: String,
) -> Result<(), String> {
    state
        .service
        .merge_session_worktree(session_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn set_project_isolate_sessions(
    state: State<'_, AppState>,
    project_id: String,
    isolate: bool,
) -> Result<(), String> {
    state
        .service
        .set_project_isolate_sessions(project_id, isolate)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn stop_session_for_close(
    state: State<'_, AppState>,
    session_id: String,
) -> Result<WorktreeCloseState, String> {
    state
        .service
        .stop_session_for_close(session_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn list_files(
    state: State<'_, AppState>,
    project_id: String,
    session_id: Option<String>,
) -> Result<Vec<FileEntry>, String> {
    state
        .service
        .list_files(project_id, session_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn read_file(
    state: State<'_, AppState>,
    project_id: String,
    session_id: Option<String>,
    file_path: String,
) -> Result<FileContents, String> {
    state
        .service
        .read_file(project_id, session_id, file_path)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn read_file_data_url(
    state: State<'_, AppState>,
    project_id: String,
    session_id: Option<String>,
    file_path: String,
) -> Result<String, String> {
    state
        .service
        .read_file_data_url(project_id, session_id, file_path)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn write_file(
    state: State<'_, AppState>,
    request: WriteFileRequest,
    session_id: Option<String>,
) -> Result<(), String> {
    state
        .service
        .write_file(request, session_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn delete_path(
    state: State<'_, AppState>,
    project_id: String,
    session_id: Option<String>,
    file_path: String,
) -> Result<(), String> {
    state
        .service
        .delete_path(project_id, session_id, file_path)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn rename_path(
    state: State<'_, AppState>,
    project_id: String,
    session_id: Option<String>,
    from_path: String,
    to_path: String,
) -> Result<(), String> {
    state
        .service
        .rename_path(project_id, session_id, from_path, to_path)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn create_path(
    state: State<'_, AppState>,
    project_id: String,
    session_id: Option<String>,
    file_path: String,
    is_dir: bool,
) -> Result<(), String> {
    state
        .service
        .create_path(project_id, session_id, file_path, is_dir)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn git_status(
    state: State<'_, AppState>,
    project_id: String,
    session_id: Option<String>,
) -> Result<Vec<GitFileChange>, String> {
    state
        .service
        .git_status(project_id, session_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn git_branch(
    state: State<'_, AppState>,
    project_id: String,
    session_id: Option<String>,
) -> Result<GitBranchInfo, String> {
    state
        .service
        .git_branch(project_id, session_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn git_diff_file(
    state: State<'_, AppState>,
    project_id: String,
    session_id: Option<String>,
    file_path: String,
) -> Result<GitFileDiff, String> {
    state
        .service
        .git_diff_file(project_id, session_id, file_path)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn git_branch_status(
    state: State<'_, AppState>,
    project_id: String,
    session_id: String,
) -> Result<Vec<GitFileChange>, String> {
    state
        .service
        .git_branch_status(project_id, session_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn git_branch_diff_file(
    state: State<'_, AppState>,
    project_id: String,
    session_id: String,
    file_path: String,
) -> Result<GitFileDiff, String> {
    state
        .service
        .git_branch_diff_file(project_id, session_id, file_path)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn list_review_checkpoints(
    state: State<'_, AppState>,
    project_id: String,
) -> Result<Vec<ReviewCheckpointView>, String> {
    state
        .service
        .list_review_checkpoints(project_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn git_checkpoint_status(
    state: State<'_, AppState>,
    project_id: String,
    checkpoint_id: String,
) -> Result<Vec<GitFileChange>, String> {
    state
        .service
        .git_checkpoint_status(project_id, checkpoint_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn git_checkpoint_diff_file(
    state: State<'_, AppState>,
    project_id: String,
    checkpoint_id: String,
    file_path: String,
) -> Result<GitFileDiff, String> {
    state
        .service
        .git_checkpoint_diff_file(project_id, checkpoint_id, file_path)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn git_apply_hunk(
    state: State<'_, AppState>,
    project_id: String,
    session_id: Option<String>,
    file_path: String,
    patch: String,
    action: GitHunkAction,
) -> Result<(), String> {
    state
        .service
        .git_apply_hunk(project_id, session_id, file_path, patch, action)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn git_commit(
    state: State<'_, AppState>,
    project_id: String,
    session_id: Option<String>,
    message: String,
) -> Result<(), String> {
    state
        .service
        .git_commit(project_id, session_id, message)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn git_stage_file(
    state: State<'_, AppState>,
    project_id: String,
    session_id: Option<String>,
    file_path: String,
) -> Result<(), String> {
    state
        .service
        .git_stage_file(project_id, session_id, file_path)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn git_unstage_file(
    state: State<'_, AppState>,
    project_id: String,
    session_id: Option<String>,
    file_path: String,
) -> Result<(), String> {
    state
        .service
        .git_unstage_file(project_id, session_id, file_path)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn git_discard_file(
    state: State<'_, AppState>,
    project_id: String,
    session_id: Option<String>,
    file_path: String,
) -> Result<(), String> {
    state
        .service
        .git_discard_file(project_id, session_id, file_path)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn git_fetch(
    state: State<'_, AppState>,
    project_id: String,
    session_id: Option<String>,
) -> Result<(), String> {
    state
        .service
        .git_fetch(project_id, session_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn git_pull(
    state: State<'_, AppState>,
    project_id: String,
    session_id: Option<String>,
) -> Result<(), String> {
    state
        .service
        .git_pull(project_id, session_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn git_push(
    state: State<'_, AppState>,
    project_id: String,
    session_id: Option<String>,
) -> Result<(), String> {
    state
        .service
        .git_push(project_id, session_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn git_list_branches(
    state: State<'_, AppState>,
    project_id: String,
    session_id: Option<String>,
) -> Result<GitBranchListView, String> {
    state
        .service
        .git_list_branches(project_id, session_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn git_checkout_branch(
    state: State<'_, AppState>,
    project_id: String,
    session_id: Option<String>,
    name: String,
) -> Result<(), String> {
    state
        .service
        .git_checkout_branch(project_id, session_id, name)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn start_workspace_watch(
    state: State<'_, AppState>,
    project_id: String,
) -> Result<(), String> {
    state
        .service
        .start_workspace_watch(project_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn stop_workspace_watch(
    state: State<'_, AppState>,
    project_id: String,
) -> Result<(), String> {
    state
        .service
        .stop_workspace_watch(project_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn scan_workspace_sessions(
    state: State<'_, AppState>,
    project_id: String,
) -> Result<Vec<DiscoveredSessionView>, String> {
    state
        .service
        .scan_workspace_sessions(project_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn get_workspace_usage(
    state: State<'_, AppState>,
    project_id: String,
) -> Result<WorkspaceUsageView, String> {
    state
        .service
        .get_workspace_usage(project_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn get_all_usage(state: State<'_, AppState>) -> Result<WorkspaceUsageView, String> {
    state
        .service
        .get_all_usage()
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn load_session_history(
    state: State<'_, AppState>,
    agent: String,
    session_id: String,
    jsonl_path: String,
    max_events: usize,
) -> Result<Vec<UnifiedEvent>, String> {
    state
        .service
        .load_session_history(agent, session_id, jsonl_path, max_events)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn search_sessions(
    state: State<'_, AppState>,
    project_id: String,
    query: String,
    limit: usize,
) -> Result<Vec<SearchHit>, String> {
    state
        .service
        .search_sessions(project_id, query, limit)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn fs_open_in_external_editor(
    state: State<'_, AppState>,
    request: OpenInExternalEditorRequest,
) -> Result<(), String> {
    state
        .service
        .open_in_external_editor(request)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn fs_reveal_in_finder(state: State<'_, AppState>, path: String) -> Result<(), String> {
    state
        .service
        .reveal_in_finder(path)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn open_url(state: State<'_, AppState>, url: String) -> Result<(), String> {
    state.service.open_url(url).await.map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn resolve_terminal_path(
    state: State<'_, AppState>,
    project_id: String,
    session_id: Option<String>,
    candidate: String,
) -> Result<Option<String>, String> {
    state
        .service
        .resolve_terminal_path(project_id, session_id, candidate)
        .await
        .map_err(|e| e.to_string())
}

/// Status payload returned to the webview for the agent-hook commands.
///
/// One variant per supported agent so the frontend can pattern-match instead
/// of doing string-typing on a generic `enabled: bool`. Gemini isn't here on
/// purpose — v1 doesn't ship hook integration for it (decided 2026-05-29).
#[derive(serde::Serialize)]
#[serde(tag = "agent", rename_all = "snake_case")]
pub enum AgentPatchStatus {
    Claude(HookStatus),
    Codex(NotifyStatus),
}

/// Locate the `ycode-notify` helper binary.
///
/// In dev (`cargo run`) it lives next to the YCode binary in `target/<profile>/`.
/// In a bundled app it ships as a Tauri sidecar resolved via
/// `BaseDirectory::Resource → binaries/`. We check both so the same code path
/// works in `cargo tauri dev`, a release `.app`, and a debug `.app`.
pub(crate) fn resolve_helper_bin(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    let bin_name = if cfg!(windows) {
        "ycode-notify.exe"
    } else {
        "ycode-notify"
    };

    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let adjacent = dir.join(bin_name);
            if adjacent.exists() {
                return Ok(adjacent);
            }
        }
    }

    if let Ok(p) = app.path().resolve(
        format!("binaries/{bin_name}"),
        tauri::path::BaseDirectory::Resource,
    ) {
        if p.exists() {
            return Ok(p);
        }
    }

    Err("ycode-notify binary not found — looked next to YCode and in bundled resources".into())
}

/// Locate the `ycode-mcp` sidecar binary. Same resolution strategy as
/// [`resolve_helper_bin`]: adjacent to the running exe in dev, bundled
/// resources in a packaged app.
pub(crate) fn resolve_mcp_bin(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    let bin_name = if cfg!(windows) {
        "ycode-mcp.exe"
    } else {
        "ycode-mcp"
    };

    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let adjacent = dir.join(bin_name);
            if adjacent.exists() {
                return Ok(adjacent);
            }
        }
    }

    if let Ok(p) = app.path().resolve(
        format!("binaries/{bin_name}"),
        tauri::path::BaseDirectory::Resource,
    ) {
        if p.exists() {
            return Ok(p);
        }
    }

    Err("ycode-mcp binary not found — looked next to YCode and in bundled resources".into())
}

/// Inspect whether the ycode-todos MCP server is registered for `agent`
/// (`"claude"` or `"codex"`).
#[tauri::command]
pub fn mcp_status(agent: String) -> Result<McpStatus, String> {
    match agent.as_str() {
        "claude" => {
            let path = claude_json_path().ok_or("HOME unset")?;
            agent_patcher::claude_mcp_status(&path).map_err(|e| e.to_string())
        }
        "codex" => {
            let path = codex_config_path().ok_or("HOME unset")?;
            agent_patcher::codex_mcp_status(&path).map_err(|e| e.to_string())
        }
        other => Err(format!("unsupported agent: {other}")),
    }
}

/// Register the ycode-todos MCP server for `agent`. Idempotent.
#[tauri::command]
pub fn mcp_install(app: tauri::AppHandle, agent: String) -> Result<McpStatus, String> {
    let mcp_bin = resolve_mcp_bin(&app)?;
    match agent.as_str() {
        "claude" => {
            let path = claude_json_path().ok_or("HOME unset")?;
            agent_patcher::install_claude_mcp(&path, &mcp_bin).map_err(|e| e.to_string())
        }
        "codex" => {
            let path = codex_config_path().ok_or("HOME unset")?;
            agent_patcher::install_codex_mcp(&path, &mcp_bin).map_err(|e| e.to_string())
        }
        other => Err(format!("unsupported agent: {other}")),
    }
}

/// Unregister the ycode-todos MCP server for `agent`. No-op when absent.
#[tauri::command]
pub fn mcp_uninstall(agent: String) -> Result<McpStatus, String> {
    match agent.as_str() {
        "claude" => {
            let path = claude_json_path().ok_or("HOME unset")?;
            agent_patcher::uninstall_claude_mcp(&path).map_err(|e| e.to_string())?;
            Ok(McpStatus::NotInstalled)
        }
        "codex" => {
            let path = codex_config_path().ok_or("HOME unset")?;
            agent_patcher::uninstall_codex_mcp(&path).map_err(|e| e.to_string())?;
            Ok(McpStatus::NotInstalled)
        }
        other => Err(format!("unsupported agent: {other}")),
    }
}

/// Locate the `ycode-cli` binary — the one `/usr/local/bin/ycode` points at.
///
/// Resolution order is deliberately the *reverse* of [`resolve_helper_bin`]:
/// bundled resources first, adjacent-to-exe second. The helper binaries are
/// only ever spawned by the running app, so a dev-tree path is fine for them.
/// This path, by contrast, gets baked into a symlink that outlives the process
/// — and in `tauri dev` the exe lives in `target/debug`, so preferring the
/// adjacent copy would point `/usr/local/bin/ycode` at a build artifact that
/// the next `cargo clean` deletes, leaving the user a dangling command.
///
/// The adjacent lookup is kept as a fallback for portable/unbundled layouts
/// where the CLI really does sit beside the app binary.
pub(crate) fn resolve_cli_bin(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    let bin_name = if cfg!(windows) {
        "ycode-cli.exe"
    } else {
        "ycode-cli"
    };

    if let Ok(p) = app.path().resolve(
        format!("binaries/{bin_name}"),
        tauri::path::BaseDirectory::Resource,
    ) {
        if p.exists() {
            return Ok(p);
        }
    }

    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let adjacent = dir.join(bin_name);
            if adjacent.exists() {
                return Ok(adjacent);
            }
        }
    }

    Err("ycode-cli binary not found — looked next to YCode and in bundled resources".into())
}

/// Drain the `ycode <path>` request parked for the calling window, if any.
///
/// Covers the cold-start race: `ycode .` with the app closed launches YCode and
/// its request lands while the webview is still booting, so the
/// `ycode://cli-open` event has no listener. The frontend calls this once on
/// mount to pick up what it missed. Returns `None` in the common warm case.
#[tauri::command]
pub fn take_pending_cli_open(
    window: tauri::Window,
    pending: State<'_, PendingCliOpen>,
) -> Option<serde_json::Value> {
    pending.take_for(window.label())
}

/// Whether `/usr/local/bin/ycode` currently points at this build's CLI.
#[tauri::command]
pub fn cli_status(app: tauri::AppHandle) -> Result<CliInstallStatus, String> {
    // A missing binary is not an error for *status*: the UI should still be
    // able to render "not installed" (and explain why installing will fail)
    // rather than showing a fetch error. An unresolvable path can never equal
    // an existing link target, so it reads as NotInstalled / Stale correctly.
    let bin = resolve_cli_bin(&app).unwrap_or_else(|_| PathBuf::from("/nonexistent/ycode-cli"));
    Ok(cli_installer::status(&bin))
}

/// Symlink `/usr/local/bin/ycode` at the bundled CLI, prompting for
/// administrator rights only if that directory isn't user-writable.
///
/// `async` on purpose, unlike its `mcp_install` sibling: Tauri runs sync
/// commands on the main thread, and the elevation path blocks on an
/// `osascript` password dialog until the user answers — or wanders off. That
/// would freeze the whole UI. `spawn_blocking` keeps the prompt off the event
/// loop.
#[tauri::command]
pub async fn cli_install(app: tauri::AppHandle) -> Result<CliInstallStatus, String> {
    let bin = resolve_cli_bin(&app)?;
    tauri::async_runtime::spawn_blocking(move || cli_installer::install(&bin))
        .await
        .map_err(|e| format!("install task: {e}"))?
        .map_err(|e| e.to_string())
}

/// Remove the symlink. No-op when it isn't there. `async` for the same reason
/// as [`cli_install`] — removal needs the same elevation.
#[tauri::command]
pub async fn cli_uninstall(app: tauri::AppHandle) -> Result<CliInstallStatus, String> {
    let bin = resolve_cli_bin(&app).unwrap_or_else(|_| PathBuf::from("/nonexistent/ycode-cli"));
    tauri::async_runtime::spawn_blocking(move || cli_installer::uninstall(&bin))
        .await
        .map_err(|e| format!("uninstall task: {e}"))?
        .map_err(|e| e.to_string())
}

/// Inspect the current state of the per-agent hook config without modifying
/// anything on disk. `agent` accepts `"claude"` or `"codex"`.
#[tauri::command]
pub fn agent_hook_status(agent: String) -> Result<AgentPatchStatus, String> {
    match agent.as_str() {
        "claude" => {
            let path = claude_settings_path().ok_or("HOME unset")?;
            agent_patcher::claude_hook_status(&path)
                .map(AgentPatchStatus::Claude)
                .map_err(|e| e.to_string())
        }
        "codex" => {
            let path = codex_config_path().ok_or("HOME unset")?;
            agent_patcher::codex_notify_status(&path)
                .map(AgentPatchStatus::Codex)
                .map_err(|e| e.to_string())
        }
        other => Err(format!("unsupported agent: {other}")),
    }
}

/// Install the hook for `agent`. For Claude this always succeeds (additive).
/// For Codex this returns `ConflictUserSet` if the user already set `notify`
/// — we deliberately do NOT overwrite, the UI shows the conflict instead.
#[tauri::command]
pub fn agent_install_hook(
    app: tauri::AppHandle,
    agent: String,
) -> Result<AgentPatchStatus, String> {
    let helper = resolve_helper_bin(&app)?;
    match agent.as_str() {
        "claude" => {
            let path = claude_settings_path().ok_or("HOME unset")?;
            agent_patcher::install_claude_hook(&path, &helper).map_err(|e| e.to_string())?;
            Ok(AgentPatchStatus::Claude(HookStatus::Installed))
        }
        "codex" => {
            let path = codex_config_path().ok_or("HOME unset")?;
            let status =
                agent_patcher::install_codex_notify(&path, &helper).map_err(|e| e.to_string())?;
            Ok(AgentPatchStatus::Codex(status))
        }
        other => Err(format!("unsupported agent: {other}")),
    }
}

/// Fire a one-off OS notification so the user can confirm the system
/// notification channel works (and, on macOS, get the first-launch permission
/// prompt out of the way before relying on real agent events).
// ── Language server install / uninstall ────────────────────────────────────

#[tauri::command]
pub async fn lsp_list_manifests(
    state: State<'_, AppState>,
) -> Result<Vec<LspManifestView>, String> {
    state
        .service
        .lsp_list_manifests()
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn lsp_install(state: State<'_, AppState>, server_id: String) -> Result<(), String> {
    state
        .service
        .lsp_install(server_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn lsp_uninstall(state: State<'_, AppState>, server_id: String) -> Result<(), String> {
    state
        .service
        .lsp_uninstall(server_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn lsp_did_open(
    state: State<'_, AppState>,
    project_id: String,
    session_id: Option<String>,
    file_path: String,
    content: String,
    version: i64,
) -> Result<bool, String> {
    state
        .service
        .lsp_did_open(project_id, session_id, file_path, content, version)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn lsp_did_change(
    state: State<'_, AppState>,
    project_id: String,
    session_id: Option<String>,
    file_path: String,
    version: i64,
    content: String,
) -> Result<bool, String> {
    state
        .service
        .lsp_did_change(project_id, session_id, file_path, version, content)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn lsp_did_close(
    state: State<'_, AppState>,
    project_id: String,
    session_id: Option<String>,
    file_path: String,
) -> Result<(), String> {
    state
        .service
        .lsp_did_close(project_id, session_id, file_path)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn lsp_definition(
    state: State<'_, AppState>,
    project_id: String,
    session_id: Option<String>,
    file_path: String,
    line: u32,
    character: u32,
) -> Result<serde_json::Value, String> {
    state
        .service
        .lsp_definition(project_id, session_id, file_path, line, character)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn lsp_semantic_tokens_full(
    state: State<'_, AppState>,
    project_id: String,
    session_id: Option<String>,
    file_path: String,
) -> Result<serde_json::Value, String> {
    state
        .service
        .lsp_semantic_tokens_full(project_id, session_id, file_path)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub fn test_notification(app: tauri::AppHandle) -> Result<(), String> {
    app.notification()
        .builder()
        .title("YCode")
        .body("Test notification — your notifications work.")
        .show()
        .map_err(|e| e.to_string())
}

/// Wrap the user's existing Codex `notify` so YCode fires first and their
/// pre-existing tool still runs (via `ycode-notify --next ARGV_JSON`). The
/// caller passes the argv it just observed via `agent_hook_status` so we
/// don't re-read the file and risk a TOCTOU mismatch.
#[tauri::command]
pub fn agent_install_codex_chain(
    app: tauri::AppHandle,
    existing: Vec<String>,
) -> Result<AgentPatchStatus, String> {
    let helper = resolve_helper_bin(&app)?;
    let path = codex_config_path().ok_or("HOME unset")?;
    let status = agent_patcher::install_codex_notify_chain(&path, &helper, &existing)
        .map_err(|e| e.to_string())?;
    Ok(AgentPatchStatus::Codex(status))
}

#[tauri::command]
pub fn agent_uninstall_hook(agent: String) -> Result<AgentPatchStatus, String> {
    match agent.as_str() {
        "claude" => {
            let path = claude_settings_path().ok_or("HOME unset")?;
            agent_patcher::uninstall_claude_hook(&path).map_err(|e| e.to_string())?;
            Ok(AgentPatchStatus::Claude(HookStatus::NotInstalled))
        }
        "codex" => {
            let path = codex_config_path().ok_or("HOME unset")?;
            agent_patcher::uninstall_codex_notify(&path).map_err(|e| e.to_string())?;
            Ok(AgentPatchStatus::Codex(NotifyStatus::NotInstalled))
        }
        other => Err(format!("unsupported agent: {other}")),
    }
}
