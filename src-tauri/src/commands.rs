//! `#[tauri::command]` wrappers around `Service`. Every command is a one-line
//! delegation — if anything heavier than `state.service.<method>(req).await`
//! creeps in here, that's a sign the IPC contract has drifted from
//! `ycode-ipc` and should be moved back.

use tauri::State;
use ycode_ipc::{
    AgentProfileView, AnswerPermissionRequest, CreateSessionRequest, ReplayEntry, ReplayRequest,
    SendPromptRequest, SessionView,
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
pub async fn send_prompt(
    state: State<'_, AppState>,
    request: SendPromptRequest,
) -> Result<(), String> {
    state
        .service
        .send_prompt(request)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn answer_permission(
    state: State<'_, AppState>,
    request: AnswerPermissionRequest,
) -> Result<(), String> {
    state
        .service
        .answer_permission(request)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn cancel_session(
    state: State<'_, AppState>,
    session_id: String,
) -> Result<(), String> {
    state
        .service
        .cancel_session(session_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn archive_session(
    state: State<'_, AppState>,
    session_id: String,
    delete_branch: bool,
) -> Result<(), String> {
    state
        .service
        .archive_session(session_id, delete_branch)
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
pub async fn replay_events(
    state: State<'_, AppState>,
    request: ReplayRequest,
) -> Result<Vec<ReplayEntry>, String> {
    state
        .service
        .replay_events(request)
        .await
        .map_err(|e| e.to_string())
}
