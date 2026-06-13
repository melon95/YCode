//! Language Server Protocol support.
//!
//! Layered:
//! - `manifest` — built-in registry of supported language servers.
//! - `installer` — downloads + installs a server into the per-user data dir.
//!
//! The PR1 surface is install/uninstall + status queries. PR2 will add the
//! JSON-RPC client + per-project lifecycle on top.

pub mod client;
pub mod dirs;
pub mod error;
pub mod installer;
pub mod manager;
pub mod manifest;
pub mod protocol;

pub use client::{path_to_file_uri, LspSession, NotificationSink, ServerNotification, TOKEN_TYPES};
pub use error::LspError;
pub use installer::{install, uninstall, InstallProgress, InstallStage};
pub use manager::LspManager;
pub use manifest::{
    builtin_manifests, manifest_by_id, AssetPattern, CommandSpec, InstallSpec, ServerManifest,
};
