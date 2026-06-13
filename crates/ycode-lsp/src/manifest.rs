//! Built-in registry of supported language servers.
//!
//! Adding a new server = add a `ServerManifest` to `builtin_manifests`. The
//! frontend renders one card per manifest entry on the Settings → Languages
//! page; the installer dispatches on `install` to actually fetch the binary.

use serde::{Deserialize, Serialize};
use ts_rs::TS;

/// A language server we know how to install and (in PR2) talk to.
///
/// The wire form is used both as the IPC list payload and as the data the
/// installer reads — keeping a single struct removes the need for a second
/// "config" type just to pass parameters between modules.
#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export, export_to = "../../ycode-ipc/bindings/")]
pub struct ServerManifest {
    /// Stable id, also used as the on-disk install directory name.
    pub id: String,
    /// Pretty name shown in the UI.
    pub display_name: String,
    /// Free-form description for the Settings card subtitle.
    pub description: String,
    /// `textDocument.languageId` values this server claims, e.g.
    /// `["typescript", "typescriptreact", "javascript", "javascriptreact"]`.
    pub language_ids: Vec<String>,
    /// Lower-case extensions (including the leading dot) the editor should
    /// route to this server. Used by PR2 to pick which server handles a file.
    pub file_extensions: Vec<String>,
    /// Optional homepage URL, surfaced as a "Learn more" link in the UI.
    pub homepage: Option<String>,
    pub install: InstallSpec,
    /// How to launch the installed server once present on disk. Paths inside
    /// `binary` and `args` may contain the literal token `${SERVER_DIR}`,
    /// expanded to the per-server install directory at spawn time.
    pub command: CommandSpec,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(tag = "type", rename_all = "snake_case")]
#[ts(export, export_to = "../../ycode-ipc/bindings/")]
pub enum InstallSpec {
    /// Download a `.gz`-compressed single binary from the latest GitHub
    /// release of `repo`. The asset name is picked from `assets` per OS+arch.
    GithubReleaseGzip {
        repo: String,
        assets: AssetPattern,
        /// Filename to write the gunzipped binary as, relative to the server
        /// install dir.
        binary_name: String,
    },
    /// Install one or more npm packages into the per-server install dir
    /// using a local `node_modules`. Requires `npm` on PATH.
    Npm { packages: Vec<String> },
}

/// Per-platform GitHub release asset names. `None` for a platform means we
/// can't auto-install there (the UI shows the card disabled).
#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export, export_to = "../../ycode-ipc/bindings/")]
pub struct AssetPattern {
    pub darwin_aarch64: Option<String>,
    pub darwin_x86_64: Option<String>,
    pub linux_x86_64: Option<String>,
    pub linux_aarch64: Option<String>,
    pub windows_x86_64: Option<String>,
}

impl AssetPattern {
    /// Pick the asset name for the current build's target triple, or `None`
    /// when this platform isn't supported by the manifest.
    pub fn for_current_platform(&self) -> Option<&str> {
        let key = current_platform_key()?;
        match key {
            "darwin-aarch64" => self.darwin_aarch64.as_deref(),
            "darwin-x86_64" => self.darwin_x86_64.as_deref(),
            "linux-x86_64" => self.linux_x86_64.as_deref(),
            "linux-aarch64" => self.linux_aarch64.as_deref(),
            "windows-x86_64" => self.windows_x86_64.as_deref(),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export, export_to = "../../ycode-ipc/bindings/")]
pub struct CommandSpec {
    /// Binary path, may include `${SERVER_DIR}`.
    pub binary: String,
    #[serde(default)]
    pub args: Vec<String>,
}

/// `<os>-<arch>` slug used by the asset matcher. Returns `None` for platforms
/// we don't compile for.
pub fn current_platform_key() -> Option<&'static str> {
    match (std::env::consts::OS, std::env::consts::ARCH) {
        ("macos", "aarch64") => Some("darwin-aarch64"),
        ("macos", "x86_64") => Some("darwin-x86_64"),
        ("linux", "x86_64") => Some("linux-x86_64"),
        ("linux", "aarch64") => Some("linux-aarch64"),
        ("windows", "x86_64") => Some("windows-x86_64"),
        _ => None,
    }
}

/// The hardcoded server registry. Order here is the order shown in the UI.
pub fn builtin_manifests() -> Vec<ServerManifest> {
    vec![
        ServerManifest {
            id: "rust-analyzer".into(),
            display_name: "rust-analyzer".into(),
            description:
                "Official Rust language server. Provides go-to-definition, hover, and semantic highlighting."
                    .into(),
            language_ids: vec!["rust".into()],
            file_extensions: vec![".rs".into()],
            homepage: Some("https://rust-analyzer.github.io/".into()),
            install: InstallSpec::GithubReleaseGzip {
                repo: "rust-lang/rust-analyzer".into(),
                assets: AssetPattern {
                    darwin_aarch64: Some("rust-analyzer-aarch64-apple-darwin.gz".into()),
                    darwin_x86_64: Some("rust-analyzer-x86_64-apple-darwin.gz".into()),
                    linux_x86_64: Some("rust-analyzer-x86_64-unknown-linux-gnu.gz".into()),
                    linux_aarch64: Some("rust-analyzer-aarch64-unknown-linux-gnu.gz".into()),
                    windows_x86_64: Some("rust-analyzer-x86_64-pc-windows-msvc.gz".into()),
                },
                binary_name: if cfg!(windows) {
                    "rust-analyzer.exe".into()
                } else {
                    "rust-analyzer".into()
                },
            },
            command: CommandSpec {
                binary: if cfg!(windows) {
                    "${SERVER_DIR}/rust-analyzer.exe".into()
                } else {
                    "${SERVER_DIR}/rust-analyzer".into()
                },
                args: vec![],
            },
        },
        ServerManifest {
            id: "typescript-language-server".into(),
            display_name: "TypeScript / JavaScript".into(),
            description:
                "TypeScript Language Server (typescript-language-server + typescript). Requires npm."
                    .into(),
            language_ids: vec![
                "typescript".into(),
                "typescriptreact".into(),
                "javascript".into(),
                "javascriptreact".into(),
            ],
            file_extensions: vec![
                ".ts".into(),
                ".tsx".into(),
                ".js".into(),
                ".jsx".into(),
                ".mjs".into(),
                ".cjs".into(),
            ],
            homepage: Some("https://github.com/typescript-language-server/typescript-language-server".into()),
            install: InstallSpec::Npm {
                packages: vec![
                    "typescript-language-server".into(),
                    "typescript".into(),
                ],
            },
            command: CommandSpec {
                binary: if cfg!(windows) {
                    "${SERVER_DIR}/node_modules/.bin/typescript-language-server.cmd".into()
                } else {
                    "${SERVER_DIR}/node_modules/.bin/typescript-language-server".into()
                },
                args: vec!["--stdio".into()],
            },
        },
    ]
}

pub fn manifest_by_id(id: &str) -> Option<ServerManifest> {
    builtin_manifests().into_iter().find(|m| m.id == id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn current_platform_recognised() {
        // The CI matrix should always cover at least one of the supported
        // slugs; on unsupported hosts the test just confirms the helper
        // returns `None` instead of panicking.
        let _ = current_platform_key();
    }

    #[test]
    fn rust_analyzer_has_some_asset_on_current_platform() {
        if current_platform_key().is_none() {
            return;
        }
        let manifest = manifest_by_id("rust-analyzer").unwrap();
        match manifest.install {
            InstallSpec::GithubReleaseGzip { assets, .. } => {
                assert!(assets.for_current_platform().is_some());
            }
            _ => panic!("expected GithubReleaseGzip"),
        }
    }

    #[test]
    fn typescript_uses_npm() {
        let manifest = manifest_by_id("typescript-language-server").unwrap();
        assert!(matches!(manifest.install, InstallSpec::Npm { .. }));
    }
}
