//! `#[tauri::command]` wrappers around `Service`. Each command is a one-line
//! delegation — if anything heavier creeps in here, that's a sign the IPC
//! contract has drifted and should be moved back into `ycode-ipc`.

use std::path::PathBuf;

use tauri::{Manager, State};
use tauri_plugin_notification::NotificationExt;
use ycode_config::agent_patcher::{
    self, claude_settings_path, codex_config_path, HookStatus, NotifyStatus,
};
use ycode_ipc::{
    AgentProfileView, ConfigView, CreateProjectRequest, CreateSessionRequest,
    DiscoveredSessionView, FileContents, FileEntry, GitFileChange, OpenInExternalEditorRequest,
    ProjectView, RenameSessionRequest, ResizePtyRequest, SearchHit, SessionView, SpawnPtyRequest,
    UnifiedEvent, WriteFileRequest, WritePtyRequest,
};

use crate::state::AppState;

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
pub async fn list_files(
    state: State<'_, AppState>,
    project_id: String,
) -> Result<Vec<FileEntry>, String> {
    state
        .service
        .list_files(project_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn read_file(
    state: State<'_, AppState>,
    project_id: String,
    file_path: String,
) -> Result<FileContents, String> {
    state
        .service
        .read_file(project_id, file_path)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn write_file(
    state: State<'_, AppState>,
    request: WriteFileRequest,
) -> Result<(), String> {
    state
        .service
        .write_file(request)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn delete_path(
    state: State<'_, AppState>,
    project_id: String,
    file_path: String,
) -> Result<(), String> {
    state
        .service
        .delete_path(project_id, file_path)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn rename_path(
    state: State<'_, AppState>,
    project_id: String,
    from_path: String,
    to_path: String,
) -> Result<(), String> {
    state
        .service
        .rename_path(project_id, from_path, to_path)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn create_path(
    state: State<'_, AppState>,
    project_id: String,
    file_path: String,
    is_dir: bool,
) -> Result<(), String> {
    state
        .service
        .create_path(project_id, file_path, is_dir)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn git_status(
    state: State<'_, AppState>,
    project_id: String,
) -> Result<Vec<GitFileChange>, String> {
    state
        .service
        .git_status(project_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn git_diff_file(
    state: State<'_, AppState>,
    project_id: String,
    file_path: String,
) -> Result<String, String> {
    state
        .service
        .git_diff_file(project_id, file_path)
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
    candidate: String,
) -> Result<Option<String>, String> {
    state
        .service
        .resolve_terminal_path(project_id, candidate)
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

/// Frontend tells us which PTY pane is currently focused so the
/// `AgentTurnComplete` notification path can suppress redundant alerts (the
/// user is already watching this pane). Pass `None` to clear (e.g. when the
/// layout collapses to zero panes or the user switches away to a non-terminal
/// column entirely).
///
/// Always succeeds — a poisoned mutex (impossible in practice, the
/// only writer is this command) just silently no-ops.
#[tauri::command]
pub fn set_active_terminal(state: State<'_, AppState>, session_id: Option<String>) {
    if let Ok(mut guard) = state.active_terminal.lock() {
        *guard = session_id;
    }
}

/// Fire a one-off OS notification so the user can confirm the system
/// notification channel works (and, on macOS, get the first-launch permission
/// prompt out of the way before relying on real agent events).
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
