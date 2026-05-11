//! Tauri shell library — `run()` is invoked from `main.rs`.

mod commands;
mod state;

use tauri::{Emitter, Manager};
use tracing_subscriber::EnvFilter;

use crate::state::AppState;

pub fn run() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .with_writer(std::io::stderr)
        .try_init();

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            let state = tauri::async_runtime::block_on(AppState::initialize())
                .expect("failed to initialize ycode backend");

            let service = state.service.clone();
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                let mut rx = service.subscribe();
                loop {
                    match rx.recv().await {
                        Ok(event) => {
                            if let Err(e) = handle.emit("ycode://session", &event) {
                                tracing::warn!(error = %e, "emit failed");
                            }
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                            tracing::warn!(lagged = n, "event pump lagged");
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                    }
                }
            });

            app.manage(state);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::list_agents,
            commands::list_sessions,
            commands::list_projects,
            commands::create_project,
            commands::delete_project,
            commands::create_session,
            commands::write_pty,
            commands::resize_pty,
            commands::kill_session,
            commands::archive_session,
            commands::restart_session,
            commands::list_files,
            commands::get_file_diff,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
