//! ycode binary entrypoint. Delegates to the lib so the same code can be
//! reused for Tauri mobile-style entry points later if needed.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    ycode_tauri_lib::run();
}
