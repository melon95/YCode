//! Tauri shell library — `run()` is invoked from `main.rs` and (in the
//! future) from a mobile entrypoint.

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
        .setup(|app| {
            // Initialize backend synchronously inside the Tauri runtime.
            // `block_on` is fine here — setup runs on the main thread before
            // any commands are dispatched, so we're not blocking concurrent
            // work.
            let state = tauri::async_runtime::block_on(AppState::initialize())
                .expect("failed to initialize ycode backend");

            // Spawn the event-pump task BEFORE `manage` so we can keep the
            // service handle. The task runs forever; abort happens implicitly
            // when the Tauri runtime shuts down.
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
            commands::create_session,
            commands::send_prompt,
            commands::answer_permission,
            commands::cancel_session,
            commands::archive_session,
            commands::restart_session,
            commands::replay_events,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
