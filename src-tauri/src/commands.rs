//! `#[tauri::command]` wrappers around `Service`. Each command is a one-line
//! delegation — if anything heavier creeps in here, that's a sign the IPC
//! contract has drifted and should be moved back into `ycode-ipc`.

use tauri::State;
use ycode_ipc::{
    AgentProfileView, CreateProjectRequest, CreateSessionRequest, FileContents, FileEntry,
    ProjectView, RenameSessionRequest, ResizePtyRequest, SessionView, SpawnPtyRequest,
    WriteFileRequest, WritePtyRequest,
};

use crate::state::AppState;

#[tauri::command]
pub async fn list_agents(state: State<'_, AppState>) -> Result<Vec<AgentProfileView>, String> {
    Ok(state.service.list_agents().await)
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
pub async fn delete_project(
    state: State<'_, AppState>,
    project_id: String,
) -> Result<(), String> {
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
pub async fn kill_pty_raw(
    state: State<'_, AppState>,
    pty_id: String,
) -> Result<(), String> {
    state
        .service
        .kill_pty_raw(pty_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn write_pty(
    state: State<'_, AppState>,
    request: WritePtyRequest,
) -> Result<(), String> {
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
pub async fn kill_session(
    state: State<'_, AppState>,
    session_id: String,
) -> Result<(), String> {
    state
        .service
        .kill_session(session_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn archive_session(
    state: State<'_, AppState>,
    session_id: String,
) -> Result<(), String> {
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

