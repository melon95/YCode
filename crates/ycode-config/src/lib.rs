//! User configuration for ycode.
//!
//! Single TOML file at `~/.config/ycode/config.toml` (or platform equivalent
//! via `directories::ProjectDirs`). Holds the list of registered
//! [`AgentLaunchProfile`]s — these are what the user picks from when starting
//! a new session.
//!
//! ## Schema
//!
//! ```toml
//! [[agents]]
//! id = "claude-code"
//! kind = "acp"
//! command = "claude-code-acp"
//! args = []
//! env = { ANTHROPIC_API_KEY = "$ANTHROPIC_API_KEY" }
//!
//! [[agents]]
//! id = "gemini-cli"
//! kind = "acp"
//! command = "gemini"
//! args = ["--experimental-acp"]
//!
//! [[agents]]
//! id = "codex"
//! kind = "pty"
//! command = "codex"
//! args = []
//! heuristic_profile = "codex"   # optional; PTY-only
//! ```
//!
//! Values inside `env` of the form `$VAR_NAME` (and only that exact form, no
//! shell escapes) are expanded from the host environment at load time.
//! Missing variables are kept as the literal `$VAR_NAME` string and a warning
//! is logged — adapters can choose to fail loudly when they spawn.

use camino::Utf8PathBuf;
use directories::ProjectDirs;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::PathBuf;
use thiserror::Error;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Config {
    #[serde(default)]
    pub agents: Vec<AgentLaunchProfile>,
}

impl Default for Config {
    /// Ship-with-the-app defaults so a user with no config file still sees the
    /// two flagship ACP agents.
    fn default() -> Self {
        Self {
            agents: vec![
                AgentLaunchProfile {
                    id: "claude-code".into(),
                    display_name: Some("Claude Code".into()),
                    kind: AdapterKind::Acp,
                    command: "claude-code-acp".into(),
                    args: vec![],
                    env: BTreeMap::from([(
                        "ANTHROPIC_API_KEY".into(),
                        "$ANTHROPIC_API_KEY".into(),
                    )]),
                    heuristic_profile: None,
                },
                AgentLaunchProfile {
                    id: "gemini-cli".into(),
                    display_name: Some("Gemini CLI".into()),
                    kind: AdapterKind::Acp,
                    command: "gemini".into(),
                    args: vec!["--experimental-acp".into()],
                    env: BTreeMap::new(),
                    heuristic_profile: None,
                },
            ],
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AgentLaunchProfile {
    /// Stable identifier used in URLs, DB rows, and the agent picker. Lower
    /// kebab-case by convention.
    pub id: String,

    /// Optional pretty name shown in the UI. Falls back to `id`.
    #[serde(default)]
    pub display_name: Option<String>,

    pub kind: AdapterKind,

    pub command: String,

    #[serde(default)]
    pub args: Vec<String>,

    /// Environment variables to set for the spawned process. `$VAR` references
    /// are expanded against the host environment by [`Config::load`].
    #[serde(default)]
    pub env: BTreeMap<String, String>,

    /// Identifier of a heuristic profile registered in `ycode-pty-adapter`.
    /// Required for `kind = "pty"`, ignored otherwise.
    #[serde(default)]
    pub heuristic_profile: Option<String>,
}

impl AgentLaunchProfile {
    pub fn display_name(&self) -> &str {
        self.display_name.as_deref().unwrap_or(&self.id)
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum AdapterKind {
    Acp,
    Pty,
    /// In-process test adapter. Not for end-user configs — exists so the
    /// SessionManager's factory registry has something deterministic to
    /// drive in smoke tests and CI.
    Echo,
}

#[derive(Error, Debug)]
pub enum ConfigError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),

    #[error("parse: {0}")]
    Parse(#[from] toml::de::Error),

    #[error("could not determine config directory for the current user")]
    NoConfigDir,

    #[error("duplicate agent id `{0}`")]
    DuplicateAgentId(String),

    #[error("agent `{0}` has kind=pty but no heuristic_profile set")]
    PtyMissingHeuristic(String),
}

impl Config {
    /// Load from the platform-default location, applying $VAR expansion. If
    /// the file is missing, return [`Config::default`].
    pub fn load() -> Result<Self, ConfigError> {
        let path = default_path()?;
        if !path.as_std_path().exists() {
            tracing::info!(
                "no config at {path}; using defaults (Claude Code + Gemini CLI)",
                path = path
            );
            return Ok(Self::default());
        }
        Self::load_from(&path)
    }

    /// Load from an explicit path. Used by tests and the CLI's `--config` flag.
    pub fn load_from(path: &Utf8PathBuf) -> Result<Self, ConfigError> {
        let raw = std::fs::read_to_string(path)?;
        let mut cfg: Self = toml::from_str(&raw)?;
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
                                "env var not set; leaving placeholder for adapter to handle",
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
            if agent.kind == AdapterKind::Pty && agent.heuristic_profile.is_none() {
                return Err(ConfigError::PtyMissingHeuristic(agent.id.clone()));
            }
        }
        Ok(())
    }

    pub fn find(&self, id: &str) -> Option<&AgentLaunchProfile> {
        self.agents.iter().find(|a| a.id == id)
    }
}

/// Default config path: `<user-config>/ycode/config.toml`.
pub fn default_path() -> Result<Utf8PathBuf, ConfigError> {
    let dirs = ProjectDirs::from("dev", "ycode", "ycode").ok_or(ConfigError::NoConfigDir)?;
    let path: PathBuf = dirs.config_dir().join("config.toml");
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
    fn default_includes_acp_agents() {
        let cfg = Config::default();
        assert!(cfg.find("claude-code").is_some());
        assert!(cfg.find("gemini-cli").is_some());
        assert_eq!(cfg.find("claude-code").unwrap().kind, AdapterKind::Acp);
    }

    #[test]
    fn parses_minimal_toml() {
        let toml_src = r#"
            [[agents]]
            id = "test"
            kind = "acp"
            command = "echo"
        "#;
        let cfg: Config = toml::from_str(toml_src).unwrap();
        assert_eq!(cfg.agents.len(), 1);
        assert_eq!(cfg.agents[0].id, "test");
        assert!(cfg.agents[0].args.is_empty());
    }

    #[test]
    fn pty_without_heuristic_fails_validation() {
        let toml_src = r#"
            [[agents]]
            id = "bad-pty"
            kind = "pty"
            command = "codex"
        "#;
        let cfg: Config = toml::from_str(toml_src).unwrap();
        let err = cfg.validate().unwrap_err();
        assert!(matches!(err, ConfigError::PtyMissingHeuristic(_)));
    }

    #[test]
    fn duplicate_id_fails_validation() {
        let toml_src = r#"
            [[agents]]
            id = "dup"
            kind = "acp"
            command = "a"
            [[agents]]
            id = "dup"
            kind = "acp"
            command = "b"
        "#;
        let cfg: Config = toml::from_str(toml_src).unwrap();
        let err = cfg.validate().unwrap_err();
        assert!(matches!(err, ConfigError::DuplicateAgentId(_)));
    }

    #[test]
    fn env_var_expansion() {
        // Use a name unlikely to collide with anything in the test env.
        std::env::set_var("YCODE_TEST_VAR_42", "hello");
        let toml_src = r#"
            [[agents]]
            id = "x"
            kind = "acp"
            command = "c"
            env = { FOO = "$YCODE_TEST_VAR_42", LITERAL = "plain" }
        "#;
        let mut cfg: Config = toml::from_str(toml_src).unwrap();
        cfg.expand_env_vars();
        assert_eq!(cfg.agents[0].env.get("FOO").unwrap(), "hello");
        assert_eq!(cfg.agents[0].env.get("LITERAL").unwrap(), "plain");
        std::env::remove_var("YCODE_TEST_VAR_42");
    }
}
