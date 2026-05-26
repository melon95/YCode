//! Tauri shell library — `run()` is invoked from `main.rs`.

mod commands;
mod state;

use tauri::menu::{Menu, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{Emitter, Manager};
use tauri_plugin_deep_link::DeepLinkExt;
use tracing_subscriber::EnvFilter;

use crate::state::AppState;

/// Bundled macOS apps inherit a minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`)
/// when launched from Finder/Dock, so user-installed CLIs (claude, codex,
/// gemini, cursor-agent, …) come back as "not on PATH" and the new-session
/// picker ends up empty. Prepend the standard user/Homebrew bin dirs that
/// exist on this machine so agent discovery and PTY spawning both see them.
fn augment_path() {
    let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
    let mut candidates: Vec<std::path::PathBuf> = vec![
        "/opt/homebrew/bin".into(),
        "/opt/homebrew/sbin".into(),
        "/usr/local/bin".into(),
        "/usr/local/sbin".into(),
    ];
    if let Some(h) = home {
        for sub in [
            ".local/bin",
            ".cargo/bin",
            ".bun/bin",
            ".deno/bin",
            ".volta/bin",
            ".npm-global/bin",
        ] {
            candidates.push(h.join(sub));
        }
    }
    let existing: Vec<std::path::PathBuf> = std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).collect())
        .unwrap_or_default();
    let mut merged: Vec<std::path::PathBuf> = Vec::with_capacity(candidates.len() + existing.len());
    for dir in candidates {
        if dir.is_dir() && !merged.contains(&dir) && !existing.contains(&dir) {
            merged.push(dir);
        }
    }
    merged.extend(existing);
    if let Ok(joined) = std::env::join_paths(merged) {
        std::env::set_var("PATH", joined);
    }
}

pub fn run() {
    augment_path();

    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .with_writer(std::io::stderr)
        .try_init();

    tauri::Builder::default()
        // Per plan §8.22: single-instance must be the first plugin so a
        // second `ycode` launch (or a `ycode://` deep-link) just refocuses
        // the existing window instead of forking a second app process.
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            if let Some(win) = app.get_webview_window("main") {
                let _ = win.show();
                let _ = win.set_focus();
            }
        }))
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_window_state::Builder::default().build())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_os::init())
        .plugin(tauri_plugin_deep_link::init())
        .setup(|app| {
            // Per plan §8.22: register `ycode://` so the OS hands URL launches
            // back to this binary. On macOS Info.plist controls registration;
            // calling this is a no-op there but harmless. On Linux it writes
            // a `.desktop` file.
            #[cfg(any(target_os = "linux", all(debug_assertions, windows)))]
            {
                let _ = app.deep_link().register_all();
            }

            // Forward incoming `ycode://...` URLs to the frontend.
            let handle_for_links = app.handle().clone();
            app.deep_link().on_open_url(move |event| {
                for url in event.urls() {
                    let _ = handle_for_links.emit("ycode://deep-link", url.to_string());
                    if let Some(win) = handle_for_links.get_webview_window("main") {
                        let _ = win.show();
                        let _ = win.set_focus();
                    }
                }
            });

            let state = tauri::async_runtime::block_on(AppState::initialize())
                .expect("failed to initialize ycode backend");

            // Menu-bar tray icon. Per plan §8.22 shows a static label + a
            // "Show / Quit" menu — the live session count is updated via
            // `set_tray_tooltip` from the frontend (TODO once sessions
            // multi-window lands).
            let show_item = MenuItem::with_id(app, "tray-show", "Show YCode", true, None::<&str>)?;
            let quit_item = MenuItem::with_id(app, "tray-quit", "Quit", true, None::<&str>)?;
            let tray_menu = Menu::with_items(app, &[&show_item, &quit_item])?;
            let _ = TrayIconBuilder::with_id("ycode-tray")
                .tooltip("YCode")
                .menu(&tray_menu)
                .on_menu_event(|app, ev| match ev.id.as_ref() {
                    "tray-show" => {
                        if let Some(win) = app.get_webview_window("main") {
                            let _ = win.show();
                            let _ = win.set_focus();
                        }
                    }
                    "tray-quit" => {
                        app.exit(0);
                    }
                    _ => {}
                })
                .build(app);

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
            commands::get_config,
            commands::save_config,
            commands::reset_config,
            commands::probe_command,
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
            commands::rename_session,
            commands::list_files,
            commands::read_file,
            commands::write_file,
            commands::start_workspace_watch,
            commands::stop_workspace_watch,
            commands::scan_workspace_sessions,
            commands::load_session_history,
            commands::search_sessions,
            commands::fs_open_in_external_editor,
            commands::fs_reveal_in_finder,
            commands::spawn_pty_raw,
            commands::kill_pty_raw,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
