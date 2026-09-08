//! Proxy environment for spawned PTYs.
//!
//! The problem: none of the CLIs ycode launches read the OS proxy settings.
//! curl/libcurl, Go's `net/http`, Node's undici — they all look at
//! `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` / `NO_PROXY` and nothing else.
//! On macOS the *system* proxy (System Settings → Network → Proxies, which is
//! also what ClashX/Surge flip) lives in SCDynamicStore, so a user with a
//! working proxy in Safari still gets a bare connection in every agent
//! terminal unless they hand-exported the variables in `~/.zshrc`.
//!
//! So we resolve the variables ourselves and seed them onto the PTY. Two
//! things about precedence are worth knowing:
//!
//! * The spawned process is a login+interactive shell, so `~/.zshrc` runs
//!   *after* our env is applied. Anything the user exports there wins over
//!   whatever we seed, in every mode. That is the behaviour we want — their
//!   rc is the more specific statement of intent.
//! * [`ProxyMode::System`] only fills variables that aren't already set (so a
//!   dev-mode launch inheriting the terminal's proxy keeps it), while
//!   [`ProxyMode::Manual`] overrides — typing an address into ycode's own
//!   settings is explicit enough to beat an inherited value.

use serde::{Deserialize, Serialize};
use tracing::{debug, warn};

/// Where the proxy variables for a spawned terminal come from.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProxyMode {
    /// Inject nothing. Only what the shell rc exports applies.
    Off,
    /// Read the OS proxy configuration at spawn time. Default: it matches
    /// what the user already sees in their browser, and it is a no-op when
    /// no system proxy is configured.
    #[default]
    System,
    /// Use [`ProxySettings::url`] / [`ProxySettings::no_proxy`] verbatim.
    Manual,
}

/// Proxy block of the user config.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct ProxySettings {
    #[serde(default)]
    pub mode: ProxyMode,
    /// Manual-mode address, used for both HTTP and HTTPS. A missing scheme is
    /// filled in as `http://` — `127.0.0.1:7897` is what people copy out of
    /// their proxy app, and libcurl rejects a schemeless value.
    #[serde(default)]
    pub url: String,
    /// Manual-mode `NO_PROXY`: comma-separated hosts/suffixes/CIDRs.
    #[serde(default)]
    pub no_proxy: String,
}

/// The variables to seed, plus whether they may overwrite existing ones.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ResolvedProxy {
    /// Env pairs, both the upper- and lower-case spelling of each key
    /// (libcurl reads `http_proxy` lower-case only; most other clients read
    /// upper-case, so tools disagree and we set both).
    pub vars: Vec<(String, String)>,
    /// True in manual mode: replace values already present in the env.
    pub force: bool,
}

impl ResolvedProxy {
    pub fn is_empty(&self) -> bool {
        self.vars.is_empty()
    }
}

impl ProxySettings {
    /// Resolve to the env pairs a PTY should get. Runs `scutil` in
    /// [`ProxyMode::System`], so call it off the async runtime.
    pub fn resolve(&self) -> ResolvedProxy {
        match self.mode {
            ProxyMode::Off => ResolvedProxy::default(),
            ProxyMode::Manual => {
                let url = normalize_url(&self.url);
                let mut vars = Vec::new();
                if let Some(url) = url {
                    push_both(&mut vars, "HTTP_PROXY", &url);
                    push_both(&mut vars, "HTTPS_PROXY", &url);
                    push_both(&mut vars, "ALL_PROXY", &url);
                }
                let no_proxy = self.no_proxy.trim();
                if !no_proxy.is_empty() {
                    push_both(&mut vars, "NO_PROXY", no_proxy);
                }
                ResolvedProxy { vars, force: true }
            }
            ProxyMode::System => ResolvedProxy {
                vars: system_proxy().into_env(),
                force: false,
            },
        }
    }
}

/// A schemeless address (`127.0.0.1:7897`, `proxy.corp`) gets `http://`;
/// anything already carrying a scheme is passed through. Returns `None` for
/// blank input so the caller can skip the variable entirely rather than
/// exporting an empty string — an empty `HTTPS_PROXY` is not the same as an
/// unset one for some clients.
fn normalize_url(raw: &str) -> Option<String> {
    let raw = raw.trim();
    if raw.is_empty() {
        return None;
    }
    if raw.contains("://") {
        Some(raw.to_string())
    } else {
        Some(format!("http://{raw}"))
    }
}

fn push_both(out: &mut Vec<(String, String)>, key: &str, value: &str) {
    out.push((key.to_ascii_uppercase(), value.to_string()));
    out.push((key.to_ascii_lowercase(), value.to_string()));
}

/// What the OS proxy configuration says, in the shape we need it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SystemProxy {
    pub http: Option<String>,
    pub https: Option<String>,
    pub socks: Option<String>,
    pub exceptions: Vec<String>,
    /// A PAC URL, when the system is configured for auto-discovery. We can't
    /// express that as `HTTP_PROXY` — recorded so the UI can say why nothing
    /// was injected instead of looking broken.
    pub pac_url: Option<String>,
}

impl SystemProxy {
    pub fn into_env(self) -> Vec<(String, String)> {
        let mut vars = Vec::new();
        if let Some(http) = &self.http {
            push_both(&mut vars, "HTTP_PROXY", http);
        }
        if let Some(https) = &self.https {
            push_both(&mut vars, "HTTPS_PROXY", https);
        }
        // ALL_PROXY is the catch-all for non-HTTP clients (git's own
        // transport, ssh wrappers). Prefer the SOCKS entry when the system
        // has one, else fall back to the HTTPS/HTTP address.
        let all = self
            .socks
            .as_ref()
            .or(self.https.as_ref())
            .or(self.http.as_ref());
        if let Some(all) = all {
            push_both(&mut vars, "ALL_PROXY", all);
        }
        if !self.exceptions.is_empty() {
            push_both(&mut vars, "NO_PROXY", &self.exceptions.join(","));
        }
        vars
    }
}

/// Read the OS proxy configuration. macOS only for now; every other platform
/// returns nothing, which makes [`ProxyMode::System`] a no-op there rather
/// than an error.
pub fn system_proxy() -> SystemProxy {
    #[cfg(target_os = "macos")]
    {
        match std::process::Command::new("/usr/sbin/scutil")
            .arg("--proxy")
            .output()
        {
            Ok(out) if out.status.success() => {
                let parsed = parse_scutil(&String::from_utf8_lossy(&out.stdout));
                debug!(?parsed, "system proxy read from scutil");
                parsed
            }
            Ok(out) => {
                warn!(status = ?out.status, "scutil --proxy failed");
                SystemProxy::default()
            }
            Err(e) => {
                warn!(error = %e, "could not run scutil --proxy");
                SystemProxy::default()
            }
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        SystemProxy::default()
    }
}

/// Parse `scutil --proxy` output:
///
/// ```text
/// <dictionary> {
///   ExceptionsList : <array> {
///     0 : 127.0.0.1
///     1 : *.local
///   }
///   HTTPEnable : 1
///   HTTPPort : 7897
///   HTTPProxy : 127.0.0.1
///   ...
/// }
/// ```
///
/// A protocol counts only when its `*Enable` key is `1` — the host/port keys
/// linger in the store after the user switches the proxy off, so trusting
/// them alone would route every agent through a dead port.
pub fn parse_scutil(output: &str) -> SystemProxy {
    let mut scalars: std::collections::HashMap<&str, &str> = std::collections::HashMap::new();
    let mut exceptions = Vec::new();
    // Depth 1 is the top-level dictionary body; anything deeper is a nested
    // block (only ExceptionsList in practice) whose entries are numbered.
    let mut depth = 0usize;
    let mut in_exceptions = false;

    for line in output.lines() {
        let line = line.trim();
        if line.ends_with('{') {
            depth += 1;
            if depth == 2 {
                in_exceptions = line.starts_with("ExceptionsList");
            }
            continue;
        }
        if line == "}" {
            if depth == 2 {
                in_exceptions = false;
            }
            depth = depth.saturating_sub(1);
            continue;
        }
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        let (key, value) = (key.trim(), value.trim());
        if depth >= 2 {
            // `<local>` is a Cocoa-only token for "simple hostnames"; no
            // env-var-reading client understands it, so drop it rather than
            // handing curl a literal it will try to match as a host.
            if in_exceptions && !value.is_empty() && value != "<local>" {
                exceptions.push(value.to_string());
            }
            continue;
        }
        if depth == 1 {
            scalars.insert(key, value);
        }
    }

    let enabled = |key: &str| scalars.get(key).copied() == Some("1");
    let endpoint = |proto: &str, scheme: &str| -> Option<String> {
        if !enabled(&format!("{proto}Enable")) {
            return None;
        }
        let host = scalars.get(&*format!("{proto}Proxy"))?;
        let port = scalars.get(&*format!("{proto}Port"))?;
        Some(format!("{scheme}://{host}:{port}"))
    };

    SystemProxy {
        http: endpoint("HTTP", "http"),
        https: endpoint("HTTPS", "http"),
        // socks5h: let the proxy resolve DNS. Resolving locally leaks the
        // hostname and breaks names that only exist on the far side.
        socks: endpoint("SOCKS", "socks5h"),
        exceptions,
        pac_url: if enabled("ProxyAutoConfigEnable") {
            scalars
                .get("ProxyAutoConfigURLString")
                .map(|s| s.to_string())
        } else {
            None
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"<dictionary> {
  ExceptionsList : <array> {
    0 : 127.0.0.1
    1 : 192.168.0.0/16
    2 : *.local
    3 : <local>
  }
  HTTPEnable : 1
  HTTPPort : 7897
  HTTPProxy : 127.0.0.1
  HTTPSEnable : 1
  HTTPSPort : 7897
  HTTPSProxy : 127.0.0.1
  ProxyAutoConfigEnable : 0
  SOCKSEnable : 1
  SOCKSPort : 7897
  SOCKSProxy : 127.0.0.1
}
"#;

    #[test]
    fn parses_scutil_endpoints_and_exceptions() {
        let p = parse_scutil(SAMPLE);
        assert_eq!(p.http.as_deref(), Some("http://127.0.0.1:7897"));
        assert_eq!(p.https.as_deref(), Some("http://127.0.0.1:7897"));
        assert_eq!(p.socks.as_deref(), Some("socks5h://127.0.0.1:7897"));
        assert_eq!(p.exceptions, ["127.0.0.1", "192.168.0.0/16", "*.local"]);
        assert!(p.pac_url.is_none());
    }

    /// The host/port keys survive turning the proxy off, so the Enable flag
    /// is the only thing that says whether it's live.
    #[test]
    fn disabled_protocol_is_ignored_even_with_host_and_port_present() {
        let out = r#"<dictionary> {
  HTTPEnable : 0
  HTTPPort : 7897
  HTTPProxy : 127.0.0.1
  SOCKSEnable : 0
  SOCKSPort : 1080
  SOCKSProxy : 127.0.0.1
}
"#;
        let p = parse_scutil(out);
        assert!(p.http.is_none());
        assert!(p.socks.is_none());
        assert!(p.into_env().is_empty());
    }

    #[test]
    fn pac_url_is_reported_but_yields_no_env() {
        let out = r#"<dictionary> {
  ProxyAutoConfigEnable : 1
  ProxyAutoConfigURLString : http://wpad.corp/proxy.pac
}
"#;
        let p = parse_scutil(out);
        assert_eq!(p.pac_url.as_deref(), Some("http://wpad.corp/proxy.pac"));
        assert!(p.clone().into_env().is_empty());
    }

    #[test]
    fn empty_dictionary_yields_nothing() {
        assert_eq!(parse_scutil("<dictionary> {\n}\n"), SystemProxy::default());
    }

    #[test]
    fn system_env_sets_both_cases_and_prefers_socks_for_all_proxy() {
        let vars = parse_scutil(SAMPLE).into_env();
        let get = |k: &str| {
            vars.iter()
                .find(|(key, _)| key == k)
                .map(|(_, v)| v.as_str())
        };
        assert_eq!(get("HTTPS_PROXY"), Some("http://127.0.0.1:7897"));
        assert_eq!(get("https_proxy"), Some("http://127.0.0.1:7897"));
        assert_eq!(get("ALL_PROXY"), Some("socks5h://127.0.0.1:7897"));
        assert_eq!(get("NO_PROXY"), Some("127.0.0.1,192.168.0.0/16,*.local"));
    }

    #[test]
    fn off_mode_resolves_to_nothing() {
        let s = ProxySettings {
            mode: ProxyMode::Off,
            url: "http://127.0.0.1:7897".into(),
            no_proxy: "localhost".into(),
        };
        assert!(s.resolve().is_empty());
    }

    #[test]
    fn manual_mode_fills_in_a_missing_scheme_and_forces() {
        let s = ProxySettings {
            mode: ProxyMode::Manual,
            url: " 127.0.0.1:7897 ".into(),
            no_proxy: "localhost, *.internal".into(),
        };
        let r = s.resolve();
        assert!(r.force);
        assert!(r
            .vars
            .contains(&("HTTP_PROXY".into(), "http://127.0.0.1:7897".into())));
        assert!(r
            .vars
            .contains(&("all_proxy".into(), "http://127.0.0.1:7897".into())));
        assert!(r
            .vars
            .contains(&("NO_PROXY".into(), "localhost, *.internal".into())));
    }

    #[test]
    fn manual_mode_keeps_an_explicit_scheme() {
        let s = ProxySettings {
            mode: ProxyMode::Manual,
            url: "socks5h://127.0.0.1:1080".into(),
            no_proxy: String::new(),
        };
        let r = s.resolve();
        assert!(r
            .vars
            .contains(&("HTTPS_PROXY".into(), "socks5h://127.0.0.1:1080".into())));
        assert!(!r.vars.iter().any(|(k, _)| k == "NO_PROXY"));
    }

    /// Manual mode with a blank address is the state right after switching
    /// the mode chip, before anything is typed. It must not export an empty
    /// `HTTPS_PROXY` — some clients treat that as "proxy to nowhere".
    #[test]
    fn manual_mode_with_blank_url_exports_no_proxy_vars() {
        let s = ProxySettings {
            mode: ProxyMode::Manual,
            url: "   ".into(),
            no_proxy: String::new(),
        };
        assert!(s.resolve().is_empty());
    }
}
