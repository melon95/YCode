//! `#[tauri::command]` wrappers around `Service`. Each command is a one-line
//! delegation — if anything heavier creeps in here, that's a sign the IPC
//! contract has drifted and should be moved back into `ycode-ipc`.

use tauri::State;
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
pub async fn fs_reveal_in_finder(
    state: State<'_, AppState>,
    path: String,
) -> Result<(), String> {
    state
        .service
        .reveal_in_finder(path)
        .await
        .map_err(|e| e.to_string())
}

