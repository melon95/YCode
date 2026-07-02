//! Tauri shell library — `run()` is invoked from `main.rs`.

mod commands;
mod state;

use tauri::menu::{Menu, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{Emitter, Manager};
use tauri_plugin_deep_link::DeepLinkExt;
use tauri_plugin_notification::NotificationExt;
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

/// Surface an OS notification for `AgentTurnComplete` according to the user's
/// `NotificationSettings`. Gating order:
///
/// 1. master `enabled` — off → silent.
/// 2. `only_when_unfocused` AND any ycode window is in front → silent. The
///    user is already in the app, where the per-session status light shows
///    exactly which pane finished, so an OS notification would just be noise
///    (regardless of which pane they happen to be looking at).
/// 3. If `only_when_unfocused` is off, always surface.
///
/// Body string distinguishes "done" from "needs attention" so the user can
/// tell at a glance whether to switch over right now.
fn maybe_show_agent_notification(
    handle: &tauri::AppHandle,
    settings: ycode_config::NotificationSettings,
    source: &str,
    event_kind: &str,
    body_preview: Option<&str>,
) {
    if !settings.enabled {
        return;
    }
    if settings.only_when_unfocused {
        let any_focused = handle
            .webview_windows()
            .values()
            .any(|w| w.is_focused().unwrap_or(false));
        if any_focused {
            return;
        }
    }

    // Prefer the assistant's actual last words — much more useful than
    // "claude finished its turn" once you have a few terminals running.
    // The title carries the routing info ("Claude · finished") so the
    // body stays free for content.
    let agent_label = match source {
        "claude" => "Claude",
        "codex" => "Codex",
        "gemini" => "Gemini",
        other => other,
    };
    let action_label = match event_kind {
        // Codex `PermissionRequest` hook fires when Codex is about to ask
        // for approval — we side-channel the alert here, the user still
        // answers in Codex's TUI. The wording mirrors the in-CLI prompt
        // so it's obvious what's being asked.
        "permission_request" => "needs your approval",
        "notification" => "needs your attention",
        _ => "finished",
    };
    let title = format!("{agent_label} · {action_label}");
    let body = body_preview
        .map(str::to_string)
        .unwrap_or_else(|| format!("{agent_label} {action_label}"));

    if let Err(e) = handle
        .notification()
        .builder()
        .title(title)
        .body(body)
        .show()
    {
        tracing::warn!(error = %e, "agent notification failed");
    }
}

/// Build the macOS menu bar with a custom **File → New Window (⌘N)** entry
/// alongside the system-default groups (Edit / View / Window / Help). The
/// `Submenu::*_with_id` constructors pull the standard Cocoa items for
/// those submenus so copy/paste/zoom keep working without us re-implementing
/// them. The ⌘N accelerator is the universal "open another window" gesture
/// — it's the discoverable escape hatch from a detached-only window state.
#[cfg(target_os = "macos")]
fn build_app_menu(app: &tauri::AppHandle) -> tauri::Result<Menu<tauri::Wry>> {
    use tauri::menu::{AboutMetadataBuilder, PredefinedMenuItem, Submenu};

    // New Window is intentionally accelerator-free: inside ycode the dominant
    // "new" verbs belong to sessions — ⌘N creates a session and ⇧⌘N opens the
    // agent picker (both handled in the webview, see lib/hotkeys.tsx). A menu
    // accelerator would be checked before the webview keydown and swallow
    // ⇧⌘N, so New Window stays click-only from the File menu.
    let new_window = MenuItem::with_id(app, "menu-new-window", "New Window", true, None::<&str>)?;

    let app_submenu = Submenu::with_items(
        app,
        "YCode",
        true,
        &[
            &PredefinedMenuItem::about(
                app,
                None,
                Some(AboutMetadataBuilder::new().name(Some("YCode")).build()),
            )?,
            &PredefinedMenuItem::separator(app)?,
            &PredefinedMenuItem::services(app, None)?,
            &PredefinedMenuItem::separator(app)?,
            &PredefinedMenuItem::hide(app, None)?,
            &PredefinedMenuItem::hide_others(app, None)?,
            &PredefinedMenuItem::show_all(app, None)?,
            &PredefinedMenuItem::separator(app)?,
            &PredefinedMenuItem::quit(app, None)?,
        ],
    )?;

    // Deliberately no `close_window` entry — its default ⌘W binding would
    // hijack the in-app "archive current session" shortcut. The title-bar
    // traffic-light buttons still close windows normally.
    let file_submenu = Submenu::with_items(app, "File", true, &[&new_window])?;

    let edit_submenu = Submenu::with_items(
        app,
        "Edit",
        true,
        &[
            &PredefinedMenuItem::undo(app, None)?,
            &PredefinedMenuItem::redo(app, None)?,
            &PredefinedMenuItem::separator(app)?,
            &PredefinedMenuItem::cut(app, None)?,
            &PredefinedMenuItem::copy(app, None)?,
            &PredefinedMenuItem::paste(app, None)?,
            &PredefinedMenuItem::select_all(app, None)?,
        ],
    )?;

    // Dev builds get a "Toggle Developer Tools" (⌥⌘I) entry so the WKWebView
    // inspector is reachable even when the UI white-screens. Release builds
    // ship without it (no devtools API compiled in).
    #[cfg(debug_assertions)]
    let view_submenu = {
        let fullscreen = PredefinedMenuItem::fullscreen(app, None)?;
        let separator = PredefinedMenuItem::separator(app)?;
        let reload = MenuItem::with_id(
            app,
            "menu-reload",
            "Reload",
            true,
            Some("CmdOrCtrl+R"),
        )?;
        let devtools = MenuItem::with_id(
            app,
            "menu-toggle-devtools",
            "Toggle Developer Tools",
            true,
            Some("CmdOrCtrl+Alt+I"),
        )?;
        Submenu::with_items(
            app,
            "View",
            true,
            &[&fullscreen, &separator, &reload, &devtools],
        )?
    };
    #[cfg(not(debug_assertions))]
    let view_submenu = Submenu::with_items(
        app,
        "View",
        true,
        &[&PredefinedMenuItem::fullscreen(app, None)?],
    )?;

    let window_submenu = Submenu::with_items(
        app,
        "Window",
        true,
        &[
            &PredefinedMenuItem::minimize(app, None)?,
            &PredefinedMenuItem::maximize(app, None)?,
        ],
    )?;

    Menu::with_items(
        app,
        &[
            &app_submenu,
            &file_submenu,
            &edit_submenu,
            &view_submenu,
            &window_submenu,
        ],
    )
}

/// Show the main "all projects" window, recreating it from scratch when the
/// user previously closed it. Without this, closing main while a detached
/// project window survives leaves the app with no way back to the picker —
/// the tray "Show YCode" entry and the dock-icon reopen both no-op'd before.
fn ensure_main_window(app: &tauri::AppHandle) {
    if let Some(win) = app.get_webview_window("main") {
        let _ = win.show();
        let _ = win.set_focus();
        return;
    }
    let build =
        tauri::WebviewWindowBuilder::new(app, "main", tauri::WebviewUrl::App("index.html".into()))
            .title("YCode")
            .inner_size(1100.0, 800.0)
            .resizable(true);
    if let Err(e) = build.build() {
        tracing::warn!(error = %e, "failed to recreate main window");
    }
}

/// The window the user is currently looking at, falling back to the main
/// window. Backs the dev-only View-menu actions below.
#[cfg(debug_assertions)]
fn focused_or_main(app: &tauri::AppHandle) -> Option<tauri::WebviewWindow> {
    app.webview_windows()
        .into_values()
        .find(|w| w.is_focused().unwrap_or(false))
        .or_else(|| app.get_webview_window("main"))
}

/// Dev-only: pop (or dismiss) WKWebView's inspector on whichever window has
/// focus. Gated to debug builds because `open_devtools`/`close_devtools`/
/// `is_devtools_open` only compile in debug or with the `devtools` feature —
/// matching the menu entry that drives it.
#[cfg(debug_assertions)]
fn toggle_devtools(app: &tauri::AppHandle) {
    if let Some(win) = focused_or_main(app) {
        if win.is_devtools_open() {
            win.close_devtools();
        } else {
            win.open_devtools();
        }
    }
}

/// Dev-only: hard-reload the focused window's webview. The native reload
/// context-menu entry is intentionally suppressed in the UI (it blows away
/// in-memory state), but during development a reload is the quickest way to
/// recover from a white-screen or pick up a frontend change, so we expose it
/// as an explicit, debug-only menu action.
#[cfg(debug_assertions)]
fn reload_focused(app: &tauri::AppHandle) {
    if let Some(win) = focused_or_main(app) {
        let _ = win.eval("window.location.reload()");
    }
}

/// Install a process-wide panic hook that records the panic message, location
/// and backtrace to stderr *and* to `<data_dir>/last-panic.log` before the
/// default hook runs.
///
/// Why this matters: Tauri turns a failed `setup` hook into
/// `panic!("Failed to setup app: …")` (see tauri `app.rs`), and that panic
/// fires inside AppKit's `applicationDidFinishLaunching` Objective-C callback.
/// Unwinding across that C frame is undefined, so the Rust runtime `abort()`s —
/// which is exactly the SIGABRT crash report users see, with no clue as to the
/// cause because release builds are stripped. Capturing the message here means
/// the next occurrence leaves a readable trail instead of an opaque crash dump.
fn install_panic_logger() {
    let prev = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        // `force_capture` ignores RUST_BACKTRACE so we always get frames, even
        // for a double-clicked .app launched with no environment.
        let bt = std::backtrace::Backtrace::force_capture();
        let msg = format!("YCode panic: {info}\n{bt}");
        eprintln!("{msg}");
        if let Some(dirs) = directories::ProjectDirs::from("dev", "ycode", "ycode") {
            let dir = dirs.data_dir();
            let _ = std::fs::create_dir_all(dir);
            if let Ok(mut f) = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(dir.join("last-panic.log"))
            {
                use std::io::Write;
                let _ = writeln!(f, "{msg}\n----");
            }
        }
        prev(info);
    }));
}

/// Render a string as an AppleScript string literal: wrap in quotes, escape
/// backslashes/quotes, and turn newlines into `return` so multi-line messages
/// display on separate lines.
#[cfg(target_os = "macos")]
fn applescript_string(s: &str) -> String {
    let mut out = String::from("\"");
    for ch in s.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\" & return & \""),
            _ => out.push(ch),
        }
    }
    out.push('"');
    out
}

/// Surface a fatal startup error to the user instead of aborting with a scary
/// OS crash report. Always logs to stderr; on macOS also shows a native modal
/// via `osascript` — a separate process, so it works before the Tauri event
/// loop is running and can't deadlock the main thread. Callers exit afterward.
fn show_fatal_dialog(msg: &str) {
    eprintln!("FATAL: {msg}");
    #[cfg(target_os = "macos")]
    {
        let script = format!(
            "display dialog {} with title \"YCode\" buttons {{\"OK\"}} default button \"OK\" with icon stop",
            applescript_string(msg)
        );
        let _ = std::process::Command::new("osascript")
            .arg("-e")
            .arg(&script)
            .status();
    }
}

pub fn run() {
    augment_path();
    install_panic_logger();

    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .with_writer(std::io::stderr)
        .try_init();

    tauri::Builder::default()
        // App-level menu event sink. Items on the macOS menu bar route their
        // clicks here; the tray menu items keep their own handler below.
        .on_menu_event(|app, ev| match ev.id().as_ref() {
            "menu-new-window" => ensure_main_window(app),
            #[cfg(debug_assertions)]
            "menu-reload" => reload_focused(app),
            #[cfg(debug_assertions)]
            "menu-toggle-devtools" => toggle_devtools(app),
            _ => {}
        })
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
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_process::init())
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

            // Install a macOS-style menu bar so File → New Window (⌘N) is
            // always available — that's the discoverable path back to a
            // main window after the user has closed it while a detached
            // project window still survives. On Windows/Linux the menu is
            // skipped to avoid drawing a chrome strip our UI doesn't expect.
            // Menu setup is best-effort: a `?` here would bubble up as a setup
            // error, which Tauri converts into `panic!("Failed to setup app")`
            // *inside* AppKit's didFinishLaunching callback — an unwind across
            // that Objective-C frame aborts the process (SIGABRT crash report)
            // rather than failing gracefully. The custom menu is a convenience
            // (File → New Window, dev devtools), so on the rare OS-side failure
            // we log and keep going with the system default menu.
            #[cfg(target_os = "macos")]
            {
                match build_app_menu(app.handle()) {
                    Ok(menu) => {
                        if let Err(e) = app.set_menu(menu) {
                            tracing::warn!(error = %e, "set_menu failed; using default menu");
                        }
                    }
                    Err(e) => {
                        tracing::warn!(error = %e, "build_app_menu failed; using default menu")
                    }
                }
            }

            // A failed backend init used to `.expect()` here, which aborts the
            // process and leaves the user staring at a macOS crash report. The
            // common triggers are recoverable-by-the-user: an older YCode build
            // opening a DB a newer build already migrated (migration mismatch),
            // or two instances racing the DB at first launch. Surface a readable
            // dialog and exit cleanly instead of crashing.
            // `catch_unwind` so an *internal* panic (e.g. a sqlite/sqlx
            // assertion, or a corrupt-DB edge case) lands in the same readable
            // dialog as a returned `Err` instead of unwinding out of this
            // didFinishLaunching callback and aborting with a crash report.
            let init = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                tauri::async_runtime::block_on(AppState::initialize())
            }));
            let state = match init {
                Ok(Ok(state)) => state,
                Ok(Err(e)) => {
                    tracing::error!(error = ?e, "backend init failed");
                    let detail = format!("{e:#}");
                    let mut msg = format!("YCode couldn't start its backend.\n\n{detail}");
                    if detail.contains("migration") {
                        msg.push_str(
                            "\n\nThe app database was likely created by a newer version of YCode. \
                             Please download and install the latest version, then try again.",
                        );
                    }
                    show_fatal_dialog(&msg);
                    std::process::exit(1);
                }
                Err(panic) => {
                    let detail = panic
                        .downcast_ref::<&str>()
                        .map(|s| s.to_string())
                        .or_else(|| panic.downcast_ref::<String>().cloned())
                        .unwrap_or_else(|| "unknown panic".to_string());
                    tracing::error!(detail, "backend init panicked");
                    show_fatal_dialog(&format!(
                        "YCode couldn't start its backend.\n\n{detail}\n\n\
                         See last-panic.log in the app data folder for details."
                    ));
                    std::process::exit(1);
                }
            };

            // One-time silent migration for users on older ycode builds whose
            // ~/.claude/settings.json still has `idle_prompt` in the
            // Notification matcher — that fires a misleading "needs your
            // attention" toast ~60s after Claude actually finished a turn.
            // `refresh_claude_hook_if_stale` is a no-op when nothing changed,
            // and any error is logged but never blocks startup (best-effort).
            if let Some(claude_path) = ycode_config::agent_patcher::claude_settings_path() {
                match commands::resolve_helper_bin(app.handle()) {
                    Ok(helper) => match ycode_config::agent_patcher::refresh_claude_hook_if_stale(
                        &claude_path,
                        &helper,
                    ) {
                        Ok(true) => tracing::info!(
                            "refreshed Claude Notification hook matcher to drop idle_prompt"
                        ),
                        Ok(false) => {}
                        Err(e) => tracing::warn!(error = %e, "claude hook refresh failed"),
                    },
                    Err(e) => tracing::warn!(error = %e, "skipping claude hook refresh: helper bin missing"),
                }
            }

            // Menu-bar tray icon. Per plan §8.22 shows a static label + a
            // "Show / Quit" menu — the live session count is updated via
            // `set_tray_tooltip` from the frontend (TODO once sessions
            // multi-window lands).
            //
            // Best-effort, for the same reason as the app menu above: a `?` on
            // any of these tray/menu builders would surface as a setup error
            // and abort the whole app inside didFinishLaunching. The tray is
            // non-essential, so we log and continue if the OS rejects it.
            let tray_result = (|| -> tauri::Result<()> {
                let show_item =
                    MenuItem::with_id(app, "tray-show", "Show YCode", true, None::<&str>)?;
                let quit_item = MenuItem::with_id(app, "tray-quit", "Quit", true, None::<&str>)?;
                let tray_menu = Menu::with_items(app, &[&show_item, &quit_item])?;
                TrayIconBuilder::with_id("ycode-tray")
                    .tooltip("YCode")
                    .menu(&tray_menu)
                    .on_menu_event(|app, ev| match ev.id.as_ref() {
                        "tray-show" => ensure_main_window(app),
                        "tray-quit" => {
                            app.exit(0);
                        }
                        _ => {}
                    })
                    .build(app)?;
                Ok(())
            })();
            if let Err(e) = tray_result {
                tracing::warn!(error = %e, "tray setup failed; continuing without tray icon");
            }


            // Bind the MCP control socket now that we have an `Arc<Service>`.
            // The sidecar (`ycode-mcp`) connects here for every todo tool
            // call. Bind failure is non-fatal — todo MCP tools just won't
            // work until the next launch. The path matches what `Service`
            // injects into PTY children as `YCODE_MCP_SOCK`.
            //
            // Must run inside a Tokio runtime context: `mcp_listener::start`
            // binds a `tokio::net::UnixListener` and `tokio::spawn`s the accept
            // loop, both of which panic outside a runtime. The Tauri `setup`
            // closure runs on the main thread in the AppKit `didFinishLaunching`
            // callback — NOT a Tokio context — so wrap the call in `block_on`
            // (which enters the global runtime). `start` returns immediately;
            // the spawned accept loop detaches and keeps running on the runtime.
            if let Some(mcp_sock) = state.service.mcp_sock_path() {
                let svc = state.service.clone();
                let token = state.service.shutdown_token();
                tauri::async_runtime::block_on(async move {
                    ycode_ipc::mcp_listener::start(svc, token, mcp_sock);
                });
            }

            let service = state.service.clone();
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                let mut rx = service.subscribe();
                loop {
                    match rx.recv().await {
                        Ok(event) => {
                            if let ycode_ipc::UiEventKind::AgentTurnComplete {
                                source,
                                event_kind,
                                body_preview,
                            } = &event.kind
                            {
                                let settings = service.notification_settings().await;
                                maybe_show_agent_notification(
                                    &handle,
                                    settings,
                                    source,
                                    event_kind,
                                    body_preview.as_deref(),
                                );
                            }
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
            commands::list_todos,
            commands::create_todo,
            commands::update_todo,
            commands::delete_todo,
            commands::create_session,
            commands::write_pty,
            commands::read_pty_backlog,
            commands::resize_pty,
            commands::kill_session,
            commands::archive_session,
            commands::restart_session,
            commands::rename_session,
            commands::list_files,
            commands::read_file,
            commands::read_file_data_url,
            commands::write_file,
            commands::delete_path,
            commands::rename_path,
            commands::create_path,
            commands::git_status,
            commands::git_branch,
            commands::git_diff_file,
            commands::git_commit,
            commands::start_workspace_watch,
            commands::stop_workspace_watch,
            commands::scan_workspace_sessions,
            commands::get_workspace_usage,
            commands::get_all_usage,
            commands::load_session_history,
            commands::search_sessions,
            commands::fs_open_in_external_editor,
            commands::fs_reveal_in_finder,
            commands::open_url,
            commands::resolve_terminal_path,
            commands::spawn_pty_raw,
            commands::kill_pty_raw,
            commands::agent_hook_status,
            commands::agent_install_hook,
            commands::agent_install_codex_chain,
            commands::agent_uninstall_hook,
            commands::mcp_status,
            commands::mcp_install,
            commands::mcp_uninstall,
            commands::test_notification,
            commands::lsp_list_manifests,
            commands::lsp_install,
            commands::lsp_uninstall,
            commands::lsp_did_open,
            commands::lsp_did_change,
            commands::lsp_did_close,
            commands::lsp_definition,
            commands::lsp_semantic_tokens_full,
        ])
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|_app_handle, _event| {
            // macOS dock-icon click. When there are no visible windows we
            // recreate the main one; the standard "focus existing windows"
            // path runs automatically when there are. Without this branch,
            // the dock icon is a dead-end once the user has closed main —
            // detached project windows alone leave no path back to the
            // picker. `RunEvent::Reopen` is macOS-only in Tauri, so the
            // whole arm is gated to avoid a "variant not found" on Linux
            // and Windows.
            #[cfg(target_os = "macos")]
            if let tauri::RunEvent::Reopen {
                has_visible_windows,
                ..
            } = _event
            {
                if !has_visible_windows {
                    ensure_main_window(_app_handle);
                }
            }
        });
}
