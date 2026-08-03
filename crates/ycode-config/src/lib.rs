//! User configuration for ycode.
//!
//! Single JSON file at `~/.config/ycode/config.json` (or platform equivalent
//! via `directories::ProjectDirs`). Holds the list of registered
//! [`AgentLaunchProfile`]s — these are what the user picks from when starting
//! a new session.
//!
//! ## Schema
//!
//! ```json
//! {
//!   "agents": [
//!     {
//!       "id": "claude-code",
//!       "display_name": "Claude Code",
//!       "command": "claude",
//!       "args": [],
//!       "icon": "ClaudeCode",
//!       "icon_variant": "color",
//!       "color": "#d97757",
//!       "introspect": "claude"
//!     },
//!     {
//!       "id": "codex",
//!       "display_name": "Codex",
//!       "command": "codex",
//!       "icon": "Codex",
//!       "introspect": "codex"
//!     }
//!   ]
//! }
//! ```
//!
//! Under the terminal-first architecture every agent is just a process to
//! launch under a PTY — there is no notion of an "adapter kind". Whatever
//! the user puts in `command` runs as-is; we forward bytes both ways.
//!
//! Values inside `env` of the form `$VAR_NAME` (and only that exact form, no
//! shell escapes) are expanded from the host environment at load time.
//! Missing variables are kept as the literal `$VAR_NAME` string and a warning
//! is logged.

use camino::Utf8PathBuf;
use directories::ProjectDirs;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::PathBuf;
use thiserror::Error;

pub mod agent_patcher;
pub mod cli_installer;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Config {
    #[serde(default)]
    pub agents: Vec<AgentLaunchProfile>,
    #[serde(default)]
    pub font_sizes: FontSizes,
    #[serde(default)]
    pub notifications: NotificationSettings,
    /// Active theme id from the frontend theme registry (see
    /// `src/lib/themes.ts`). Unknown ids fall back to the default at render
    /// time, so a future-version config file can't softlock the UI.
    #[serde(default = "default_theme")]
    pub theme: String,
}

fn default_theme() -> String {
    "foundry".into()
}

/// Global on/off + focus-gating switches for the agent-turn-complete OS
/// notification. The actual per-agent install state lives on disk inside
/// `~/.claude/settings.json` and `~/.codex/config.toml` (see
/// [`agent_patcher`]) — we don't shadow it here to avoid two sources of
/// truth that can drift.
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
pub struct NotificationSettings {
    /// Master switch. When false the Tauri event pump skips the system
    /// toast entirely, even if the agent's CLI hook fired.
    pub enabled: bool,
    /// Only fire the toast when no ycode window is focused. Lets users who
    /// keep ycode in the foreground avoid double-signalling.
    pub only_when_unfocused: bool,
}

impl Default for NotificationSettings {
    fn default() -> Self {
        Self {
            enabled: true,
            only_when_unfocused: true,
        }
    }
}

/// Font sizes for the three layers users actually look at, mirroring the
/// VS Code split (UI chrome / editor / terminal). All in CSS px. The
/// frontend clamps to a sane range before sending to keep weird values
/// from making the app unusable, but we re-clamp on load for safety.
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
pub struct FontSizes {
    pub ui: u16,
    pub editor: u16,
    pub terminal: u16,
}

impl Default for FontSizes {
    fn default() -> Self {
        Self {
            ui: 13,
            editor: 13,
            terminal: 13,
        }
    }
}

impl Default for Config {
    /// Ship-with-the-app defaults so a user with no config file still sees
    /// the primary supported CLIs. Agent discovery (which of these are actually on
    /// PATH) happens at startup. `icon` values must match a key in the
    /// frontend's `AgentIcon` whitelist registry; unknown names render
    /// the generic placeholder.
    fn default() -> Self {
        Self {
            agents: vec![
                AgentLaunchProfile {
                    id: "claude-code".into(),
                    display_name: Some("Claude Code".into()),
                    command: "claude".into(),
                    args: vec![],
                    env: BTreeMap::new(),
                    icon: Some("ClaudeCode".into()),
                    icon_variant: None,
                    color: None,
                    introspect: Some("claude".into()),
                },
                AgentLaunchProfile {
                    id: "codex".into(),
                    display_name: Some("Codex".into()),
                    command: "codex".into(),
                    args: vec![],
                    env: BTreeMap::new(),
                    icon: Some("Codex".into()),
                    icon_variant: None,
                    color: None,
                    introspect: Some("codex".into()),
                },
                // Note: bash, aider, gemini, and cursor deliberately omitted
                // from defaults. Bash: the right-pane ManualTerminal already
                // covers ad-hoc shell use, and shell isn't really an AI agent
                // CLI. Aider: no lobehub brand icon yet, so it fell back to a
                // letter placeholder that looked out of place. Gemini and
                // Cursor can be added via Settings by users who want them.
            ],
            font_sizes: FontSizes::default(),
            notifications: NotificationSettings::default(),
            theme: default_theme(),
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AgentLaunchProfile {
    /// Stable identifier used in URLs, DB rows, and the agent picker. Lower
    /// kebab-case by convention.
    pub id: String,

    /// Pretty name shown in the UI. Falls back to `id` when absent.
    #[serde(default)]
    pub display_name: Option<String>,

    pub command: String,

    #[serde(default)]
    pub args: Vec<String>,

    /// Environment variables to set for the spawned process. `$VAR` references
    /// are expanded against the host environment by [`Config::load`].
    #[serde(default)]
    pub env: BTreeMap<String, String>,

    /// Frontend `AgentIcon` whitelist key (e.g. "ClaudeCode", "Codex"). The
    /// renderer falls back to a generic placeholder when the name isn't in
    /// the whitelist or this field is `None`.
    #[serde(default)]
    pub icon: Option<String>,

    /// Either "color" (default — brand-tinted) or "mono" (currentColor).
    /// Other strings are treated as "color".
    #[serde(default)]
    pub icon_variant: Option<String>,

    /// Brand color hint, currently advisory — the icon library carries its
    /// own color. Useful later for accenting pane borders, etc.
    #[serde(default)]
    pub color: Option<String>,

    /// Which built-in jsonl parser scans this agent's sessions. "claude" or
    /// "codex" today; `None` means the agent runs PTY-only and won't appear
    /// in the sidebar's history/discovered list. Adding new parser kinds
    /// requires Rust code in `ycode-introspect`.
    #[serde(default)]
    pub introspect: Option<String>,
}

impl AgentLaunchProfile {
    pub fn display_name(&self) -> &str {
        self.display_name.as_deref().unwrap_or(&self.id)
    }
}

#[derive(Error, Debug)]
pub enum ConfigError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),

    #[error("parse: {0}")]
    Parse(#[from] serde_json::Error),

    #[error("could not determine config directory for the current user")]
    NoConfigDir,

    #[error("duplicate agent id `{0}`")]
    DuplicateAgentId(String),
}

impl Config {
    /// Load from the platform-default location, applying $VAR expansion. If
    /// the file is missing, write the shipped defaults to disk and return
    /// them — that way a fresh install ends up with a real `config.json` the
    /// user can edit, instead of an invisible in-memory copy.
    pub fn load() -> Result<Self, ConfigError> {
        let path = default_path()?;
        if !path.as_std_path().exists() {
            tracing::info!(
                "no config at {path}; writing defaults",
                path = path
            );
            let cfg = Self::default();
            // Best-effort: if we can't write defaults to disk (e.g. read-only
            // home), still hand back the in-memory copy so the app boots.
            if let Err(e) = cfg.save_to(&path) {
                tracing::warn!(error = %e, "failed to persist default config");
            }
            return Ok(cfg);
        }
        Self::load_from(&path)
    }

    /// Load from an explicit path.
    pub fn load_from(path: &Utf8PathBuf) -> Result<Self, ConfigError> {
        let raw = std::fs::read_to_string(path)?;
        let mut cfg: Self = serde_json::from_str(&raw)?;
        cfg.expand_env_vars();
        cfg.validate()?;
        Ok(cfg)
    }

    /// Expand `$VAR` patterns inside `env` values. Anything not matching the
    /// strict `$VAR` form is left untouched.
    pub fn expand_env_vars(&mut self) {
        for agent in &mut self.agents {
            for value in agent.env.values_mut() {
                if let Some(name) = value.strip_prefix('$') {
                    match std::env::var(name) {
                        Ok(resolved) => *value = resolved,
                        Err(_) => {
                            tracing::warn!(
                                agent = %agent.id,
                                var = %name,
                                "env var not set; leaving placeholder",
                            );
                        }
                    }
                }
            }
        }
    }

    fn validate(&self) -> Result<(), ConfigError> {
        let mut seen = std::collections::HashSet::new();
        for agent in &self.agents {
            if !seen.insert(agent.id.as_str()) {
                return Err(ConfigError::DuplicateAgentId(agent.id.clone()));
            }
        }
        Ok(())
    }

    pub fn find(&self, id: &str) -> Option<&AgentLaunchProfile> {
        self.agents.iter().find(|a| a.id == id)
    }

    /// Serialize to pretty JSON and write to disk. Creates the parent
    /// directory if needed. Re-runs validation first so a duplicate id can't
    /// reach disk.
    pub fn save_to(&self, path: &Utf8PathBuf) -> Result<(), ConfigError> {
        self.validate()?;
        let body = serde_json::to_string_pretty(self)?;
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(path, body)?;
        Ok(())
    }

    /// Save to the platform-default path (creates `~/.config/ycode/`).
    pub fn save(&self) -> Result<Utf8PathBuf, ConfigError> {
        let path = default_path()?;
        self.save_to(&path)?;
        Ok(path)
    }
}

/// Default config path: `<user-config>/ycode/config.json`.
pub fn default_path() -> Result<Utf8PathBuf, ConfigError> {
    let dirs = ProjectDirs::from("dev", "ycode", "ycode").ok_or(ConfigError::NoConfigDir)?;
    let path: PathBuf = dirs.config_dir().join("config.json");
    Utf8PathBuf::from_path_buf(path).map_err(|p| {
        ConfigError::Io(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("config path is not valid UTF-8: {}", p.display()),
        ))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_includes_common_agents() {
        let cfg = Config::default();
        assert!(cfg.find("claude-code").is_some());
        assert!(cfg.find("codex").is_some());
        assert!(cfg.find("gemini-cli").is_none());
    }

    #[test]
    fn parses_minimal_json() {
        let json_src = r#"{
            "agents": [
                { "id": "test", "command": "echo" }
            ]
        }"#;
        let cfg: Config = serde_json::from_str(json_src).unwrap();
        assert_eq!(cfg.agents.len(), 1);
        assert_eq!(cfg.agents[0].id, "test");
        assert!(cfg.agents[0].args.is_empty());
    }

    #[test]
    fn duplicate_id_fails_validation() {
        let json_src = r#"{
            "agents": [
                { "id": "dup", "command": "a" },
                { "id": "dup", "command": "b" }
            ]
        }"#;
        let cfg: Config = serde_json::from_str(json_src).unwrap();
        let err = cfg.validate().unwrap_err();
        assert!(matches!(err, ConfigError::DuplicateAgentId(_)));
    }

    #[test]
    fn env_var_expansion() {
        std::env::set_var("YCODE_TEST_VAR_42", "hello");
        let json_src = r#"{
            "agents": [
                {
                    "id": "x",
                    "command": "c",
                    "env": { "FOO": "$YCODE_TEST_VAR_42", "LITERAL": "plain" }
                }
            ]
        }"#;
        let mut cfg: Config = serde_json::from_str(json_src).unwrap();
        cfg.expand_env_vars();
        assert_eq!(cfg.agents[0].env.get("FOO").unwrap(), "hello");
        assert_eq!(cfg.agents[0].env.get("LITERAL").unwrap(), "plain");
        std::env::remove_var("YCODE_TEST_VAR_42");
    }
}
