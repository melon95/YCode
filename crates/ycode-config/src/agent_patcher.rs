//! Patches user-owned agent CLI config files so they invoke the `ycode-notify`
//! helper on turn-complete / notification events.
//!
//! Two formats to handle:
//!
//! - **Claude Code** writes JSON to `~/.claude/settings.json`. Hooks are
//!   additive (a list per event), so we can drop our entry next to whatever
//!   the user already has. We tag our entry with `"_ycode_managed": true` so
//!   we can find and remove it without touching theirs.
//!
//! - **Codex** uses a single `notify = [...]` field in `~/.codex/config.toml`.
//!   Only one command is supported, so if the user already set one we refuse
//!   to overwrite (the UI shows a "managed by you" state instead). We use
//!   `toml_edit` to preserve user comments and field ordering, and tag our
//!   line with a `# ycode-managed` comment right above it.
//!
//! All install operations create a one-shot backup at `<file>.ycode.bak`
//! the first time we touch a file — uninstall doesn't restore from it
//! (we know our own changes by marker), it's purely a safety net the user
//! can fall back to if they suspect we broke something.

use serde::Serialize;
use std::path::{Path, PathBuf};
use thiserror::Error;

#[derive(Error, Debug)]
pub enum PatchError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
    #[error("toml parse: {0}")]
    TomlParse(#[from] toml_edit::TomlError),
    #[error("home directory not found")]
    NoHome,
    #[error("unexpected schema in {file}: {msg}")]
    Schema { file: &'static str, msg: String },
}

/// State of the Claude `Stop` + `Notification` hook entries.
///
/// Claude hooks are a list per event, so we can coexist with the user's
/// own entries — there is no "conflict" branch here. Either our marker
/// entry is present or it isn't.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum HookStatus {
    NotInstalled,
    Installed,
}

/// State of the Codex `notify` field.
///
/// Codex only allows one notify command, so a user-set notify blocks us.
/// `ConflictUserSet` carries the existing argv so the UI can render it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum NotifyStatus {
    NotInstalled,
    Installed,
    ConflictUserSet { existing: Vec<String> },
}

const YCODE_MARKER_KEY: &str = "_ycode_managed";
const CODEX_MARKER_COMMENT: &str = "# ycode-managed (do not edit this line or the one below)";

/// `$HOME/.claude/settings.json`. Returns `None` when `$HOME` is unset.
pub fn claude_settings_path() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".claude/settings.json"))
}

/// `$HOME/.codex/config.toml`. Returns `None` when `$HOME` is unset.
pub fn codex_config_path() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".codex/config.toml"))
}

fn backup_path(path: &Path) -> PathBuf {
    let mut s = path.as_os_str().to_owned();
    s.push(".ycode.bak");
    PathBuf::from(s)
}

fn backup_once(path: &Path) -> Result<(), PatchError> {
    let bak = backup_path(path);
    if !bak.exists() && path.exists() {
        std::fs::copy(path, &bak)?;
    }
    Ok(())
}

fn write_atomically(path: &Path, contents: &str) -> Result<(), PatchError> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    // Same-directory tmp file so rename stays atomic across mount boundaries.
    let tmp = path.with_extension(format!(
        "{}.ycode.tmp",
        path.extension().and_then(|s| s.to_str()).unwrap_or("")
    ));
    std::fs::write(&tmp, contents)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

// ────────────────────────────── Claude ──────────────────────────────

/// Read `~/.claude/settings.json` and report whether our Stop/Notification
/// hook entries are installed. Missing file → `NotInstalled`.
pub fn claude_hook_status(path: &Path) -> Result<HookStatus, PatchError> {
    if !path.exists() {
        return Ok(HookStatus::NotInstalled);
    }
    let raw = std::fs::read_to_string(path)?;
    if raw.trim().is_empty() {
        return Ok(HookStatus::NotInstalled);
    }
    let value: serde_json::Value = serde_json::from_str(&raw)?;
    let has_stop = claude_has_ycode_entry(&value, "Stop");
    let has_notif = claude_has_ycode_entry(&value, "Notification");
    Ok(if has_stop && has_notif {
        HookStatus::Installed
    } else {
        HookStatus::NotInstalled
    })
}

fn claude_has_ycode_entry(root: &serde_json::Value, event: &str) -> bool {
    root.get("hooks")
        .and_then(|h| h.get(event))
        .and_then(|arr| arr.as_array())
        .map(|arr| {
            arr.iter().any(|entry| {
                entry
                    .get(YCODE_MARKER_KEY)
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false)
            })
        })
        .unwrap_or(false)
}

/// Add (or refresh) ycode-managed `Stop` and `Notification` hook entries
/// pointing at `helper_bin`. Preserves any other entries the user already has.
pub fn install_claude_hook(path: &Path, helper_bin: &Path) -> Result<(), PatchError> {
    backup_once(path)?;

    let mut root: serde_json::Value = if path.exists() {
        let raw = std::fs::read_to_string(path)?;
        if raw.trim().is_empty() {
            serde_json::json!({})
        } else {
            serde_json::from_str(&raw)?
        }
    } else {
        serde_json::json!({})
    };

    if !root.is_object() {
        return Err(PatchError::Schema {
            file: "claude settings.json",
            msg: "top-level value must be an object".into(),
        });
    }

    let helper = helper_bin.to_string_lossy().into_owned();
    // Stop fires on every turn-end and ignores `matcher` per the docs; we keep
    // the field as `""` for schema cleanliness. Notification's matcher accepts
    // a `|`-separated subtype list — we deliberately exclude `auth_success`
    // and the `elicitation_*` subtypes since they're noisy without being
    // actionable, leaving just the two subtypes that mean "user needed".
    for (event, sub, matcher) in [
        ("Stop", "stop", ""),
        ("Notification", "notification", "permission_prompt|idle_prompt"),
    ] {
        claude_remove_ycode_entry(&mut root, event);
        claude_append_ycode_entry(&mut root, event, &helper, sub, matcher)?;
    }

    let body = serde_json::to_string_pretty(&root)?;
    write_atomically(path, &body)
}

/// Strip our managed entries from `Stop` and `Notification`. Other user
/// entries are kept intact. Missing file is a no-op.
pub fn uninstall_claude_hook(path: &Path) -> Result<(), PatchError> {
    if !path.exists() {
        return Ok(());
    }
    let raw = std::fs::read_to_string(path)?;
    if raw.trim().is_empty() {
        return Ok(());
    }
    let mut root: serde_json::Value = serde_json::from_str(&raw)?;
    for event in ["Stop", "Notification"] {
        claude_remove_ycode_entry(&mut root, event);
    }
    claude_compact_hooks(&mut root);

    let body = serde_json::to_string_pretty(&root)?;
    write_atomically(path, &body)
}

fn claude_remove_ycode_entry(root: &mut serde_json::Value, event: &str) {
    let Some(hooks) = root.get_mut("hooks").and_then(|h| h.as_object_mut()) else {
        return;
    };
    let Some(arr) = hooks.get_mut(event).and_then(|v| v.as_array_mut()) else {
        return;
    };
    arr.retain(|entry| {
        !entry
            .get(YCODE_MARKER_KEY)
            .and_then(|v| v.as_bool())
            .unwrap_or(false)
    });
}

fn claude_append_ycode_entry(
    root: &mut serde_json::Value,
    event: &str,
    helper: &str,
    sub: &str,
    matcher: &str,
) -> Result<(), PatchError> {
    let obj = root.as_object_mut().expect("checked in install_claude_hook");
    let hooks = obj
        .entry("hooks".to_string())
        .or_insert_with(|| serde_json::json!({}));
    if !hooks.is_object() {
        return Err(PatchError::Schema {
            file: "claude settings.json",
            msg: format!("`hooks` must be an object, got {hooks}"),
        });
    }
    let hooks_obj = hooks.as_object_mut().unwrap();
    let arr = hooks_obj
        .entry(event.to_string())
        .or_insert_with(|| serde_json::json!([]));
    if !arr.is_array() {
        return Err(PatchError::Schema {
            file: "claude settings.json",
            msg: format!("`hooks.{event}` must be an array, got {arr}"),
        });
    }
    arr.as_array_mut().unwrap().push(serde_json::json!({
        YCODE_MARKER_KEY: true,
        "matcher": matcher,
        "hooks": [
            { "type": "command", "command": format!("{helper} {sub} claude") }
        ]
    }));
    Ok(())
}

/// After removing entries we may leave behind empty arrays / empty `hooks`
/// object. Drop them so we exit with the same file shape the user started
/// from when nothing else of theirs is in there.
fn claude_compact_hooks(root: &mut serde_json::Value) {
    let Some(obj) = root.as_object_mut() else {
        return;
    };
    let Some(hooks) = obj.get_mut("hooks").and_then(|h| h.as_object_mut()) else {
        return;
    };
    hooks.retain(|_, v| !v.as_array().map(|a| a.is_empty()).unwrap_or(false));
    if hooks.is_empty() {
        obj.remove("hooks");
    }
}

// ────────────────────────────── Codex ──────────────────────────────

/// Read `~/.codex/config.toml` and report the state of the `notify` field.
pub fn codex_notify_status(path: &Path) -> Result<NotifyStatus, PatchError> {
    if !path.exists() {
        return Ok(NotifyStatus::NotInstalled);
    }
    let raw = std::fs::read_to_string(path)?;
    if raw.trim().is_empty() {
        return Ok(NotifyStatus::NotInstalled);
    }
    let doc: toml_edit::DocumentMut = raw.parse()?;

    let Some(item) = doc.get("notify") else {
        return Ok(NotifyStatus::NotInstalled);
    };
    let argv = match toml_array_to_strings(item) {
        Some(v) => v,
        None => {
            // notify is set to something we can't make sense of (not an array
            // of strings). Treat as a user-owned value we won't touch.
            return Ok(NotifyStatus::ConflictUserSet {
                existing: vec![item.to_string()],
            });
        }
    };
    if codex_has_marker(&raw) {
        Ok(NotifyStatus::Installed)
    } else {
        Ok(NotifyStatus::ConflictUserSet { existing: argv })
    }
}

fn codex_has_marker(raw: &str) -> bool {
    raw.lines().any(|line| line.trim_start() == CODEX_MARKER_COMMENT)
}

fn toml_array_to_strings(item: &toml_edit::Item) -> Option<Vec<String>> {
    let arr = item.as_array()?;
    let mut out = Vec::with_capacity(arr.len());
    for v in arr.iter() {
        out.push(v.as_str()?.to_string());
    }
    Some(out)
}

/// Set `notify = ["<helper>", "turn_complete", "codex"]` with our marker
/// comment, only if no user-set `notify` is present. Returns the resulting
/// status (e.g. `ConflictUserSet` when we declined to overwrite).
pub fn install_codex_notify(path: &Path, helper_bin: &Path) -> Result<NotifyStatus, PatchError> {
    let current = codex_notify_status(path)?;
    if let NotifyStatus::ConflictUserSet { .. } = &current {
        return Ok(current);
    }

    backup_once(path)?;

    let raw = if path.exists() {
        std::fs::read_to_string(path)?
    } else {
        String::new()
    };

    // Strip any prior ycode-managed block (idempotent reinstall).
    let stripped = strip_codex_managed_block(&raw);

    let helper = helper_bin.to_string_lossy();
    let block = format!(
        "\n{marker}\nnotify = [{a:?}, {b:?}, {c:?}]\n",
        marker = CODEX_MARKER_COMMENT,
        a = helper.as_ref(),
        b = "turn_complete",
        c = "codex",
    );

    let new_contents = insert_before_first_table(&stripped, &block);
    write_atomically(path, &new_contents)?;
    Ok(NotifyStatus::Installed)
}

/// Wrap an existing user-set Codex `notify` so YCode fires first and the
/// user's wrapper still runs. Encodes the existing argv into our `--next`
/// flag — ycode-notify decodes and `exec`s it after pinging the UDS. On
/// uninstall we restore the original argv from `--next`.
///
/// `existing` must be the argv the caller observed via `codex_notify_status`
/// (we don't re-read it to avoid TOCTOU mismatches).
pub fn install_codex_notify_chain(
    path: &Path,
    helper_bin: &Path,
    existing: &[String],
) -> Result<NotifyStatus, PatchError> {
    // No-op if we're already installed (whether plain or chained — both
    // carry our marker; reinstalling would just rewrite the same line).
    if matches!(codex_notify_status(path)?, NotifyStatus::Installed) {
        return Ok(NotifyStatus::Installed);
    }
    if existing.is_empty() {
        // Nothing to wrap → equivalent to a plain install.
        return install_codex_notify(path, helper_bin);
    }

    backup_once(path)?;

    let raw = if path.exists() {
        std::fs::read_to_string(path)?
    } else {
        String::new()
    };
    // Remove the user's existing `notify = [...]` line (we're encoding it into
    // our --next argument) and any prior ycode-managed block. If both edits
    // succeed via toml_edit we keep the structured output; if parsing fails
    // we fall back to the lossy line strip so we still write something sane.
    let stripped = strip_codex_managed_block(&raw);
    let without_notify = remove_top_level_notify(&stripped).unwrap_or(stripped);

    let helper = helper_bin.to_string_lossy();
    let chain_json = serde_json::to_string(existing)?;
    let block = format!(
        "\n{marker}\nnotify = [{a:?}, {b:?}, {c:?}, {d:?}, {chain:?}]\n",
        marker = CODEX_MARKER_COMMENT,
        a = helper.as_ref(),
        b = "turn_complete",
        c = "codex",
        d = "--next",
        chain = chain_json,
    );

    let new_contents = insert_before_first_table(&without_notify, &block);
    write_atomically(path, &new_contents)?;
    Ok(NotifyStatus::Installed)
}

/// Append `block` (which starts/ends in `\n` as needed) immediately above the
/// first `[table.header]` line in `raw`. TOML's grammar attaches any key
/// declared *after* a table header to that table — so a naive trailing
/// append makes our `notify = [...]` get parsed as a member of whichever
/// section came last. If `raw` has no table headers, we just append at the
/// end.
fn insert_before_first_table(raw: &str, block: &str) -> String {
    let mut out = String::with_capacity(raw.len() + block.len() + 2);
    let mut inserted = false;
    for line in raw.split_inclusive('\n') {
        if !inserted && is_table_header_line(line) {
            if !out.ends_with("\n\n") {
                if !out.ends_with('\n') {
                    out.push('\n');
                }
            }
            out.push_str(block.trim_start_matches('\n'));
            if !out.ends_with("\n\n") {
                if !out.ends_with('\n') {
                    out.push('\n');
                }
                out.push('\n');
            }
            inserted = true;
        }
        out.push_str(line);
    }
    if !inserted {
        let mut tail = out.trim_end().to_string();
        if !tail.is_empty() {
            tail.push('\n');
        }
        tail.push_str(&block);
        if !tail.ends_with('\n') {
            tail.push('\n');
        }
        out = tail;
    }
    out
}

fn is_table_header_line(line: &str) -> bool {
    let trimmed = line.trim_start();
    if !trimmed.starts_with('[') {
        return false;
    }
    // Skip array-of-tables `[[` and inline arrays — only `[ident...]` is
    // a TOML table header. Both `[name]` and `[[name]]` change the
    // "current table", but only true root-level scalars need protection
    // from the latter too; treat both the same.
    true
}

fn remove_top_level_notify(raw: &str) -> Option<String> {
    let mut doc: toml_edit::DocumentMut = raw.parse().ok()?;
    if doc.remove("notify").is_some() {
        Some(doc.to_string())
    } else {
        Some(raw.to_string())
    }
}

/// Remove our marker comment and notify line, if present. Missing file or
/// user-managed notify → no-op. If we were installed in chain mode (notify
/// argv contains `--next <ARGV_JSON>`), restore the wrapped argv as the
/// user's new notify so their original tool keeps running.
pub fn uninstall_codex_notify(path: &Path) -> Result<(), PatchError> {
    if !path.exists() {
        return Ok(());
    }
    let raw = std::fs::read_to_string(path)?;
    if !codex_has_marker(&raw) {
        return Ok(());
    }

    let wrapped = extract_wrapped_chain(&raw);
    let cleaned = strip_codex_managed_block(&raw);

    if let Some(prev) = wrapped {
        // Restore the user's original notify (without our marker), placed
        // above the first table header so TOML parses it as a root key.
        let mut block = String::from("notify = [");
        for (i, s) in prev.iter().enumerate() {
            if i > 0 {
                block.push_str(", ");
            }
            block.push_str(&format!("{s:?}"));
        }
        block.push_str("]\n");
        let new_contents = insert_before_first_table(&cleaned, &block);
        write_atomically(path, &new_contents)
    } else {
        write_atomically(path, &cleaned)
    }
}

/// If the current ycode-managed `notify = [...]` line encodes a `--next
/// ARGV_JSON` pair, return the decoded inner argv so uninstall can restore
/// it. Returns `None` when the notify isn't chained.
fn extract_wrapped_chain(raw: &str) -> Option<Vec<String>> {
    let doc: toml_edit::DocumentMut = raw.parse().ok()?;
    let argv = toml_array_to_strings(doc.get("notify")?)?;
    let mut it = argv.iter();
    while let Some(tok) = it.next() {
        if tok == "--next" {
            let json = it.next()?;
            return serde_json::from_str::<Vec<String>>(json).ok();
        }
    }
    None
}

/// Drop the `# ycode-managed` comment line and the immediately following
/// non-empty line (which is our `notify = [...]`). Leaves everything else
/// untouched.
fn strip_codex_managed_block(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut skip_next_nonblank = false;
    for line in raw.split_inclusive('\n') {
        let trimmed = line.trim_end_matches(['\n', '\r']);
        if trimmed.trim_start() == CODEX_MARKER_COMMENT {
            skip_next_nonblank = true;
            continue;
        }
        if skip_next_nonblank {
            if trimmed.trim().is_empty() {
                // Preserve blank spacing but keep waiting for the real line.
                continue;
            }
            skip_next_nonblank = false;
            continue;
        }
        out.push_str(line);
    }
    out
}

// ───────────────────────────── tests ─────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use tempfile::TempDir;

    fn helper() -> PathBuf {
        PathBuf::from("/opt/ycode/bin/ycode-notify")
    }

    fn tmp_file(name: &str) -> (TempDir, PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(name);
        (dir, path)
    }

    // ── Claude ──

    #[test]
    fn claude_status_missing_file_is_not_installed() {
        let (_d, path) = tmp_file("settings.json");
        assert_eq!(claude_hook_status(&path).unwrap(), HookStatus::NotInstalled);
    }

    #[test]
    fn claude_install_creates_file_and_marks_installed() {
        let (_d, path) = tmp_file("settings.json");
        install_claude_hook(&path, &helper()).unwrap();
        assert_eq!(claude_hook_status(&path).unwrap(), HookStatus::Installed);

        let body = std::fs::read_to_string(&path).unwrap();
        let v: serde_json::Value = serde_json::from_str(&body).unwrap();
        let stop = v["hooks"]["Stop"].as_array().unwrap();
        assert_eq!(stop.len(), 1);
        assert_eq!(stop[0][YCODE_MARKER_KEY], true);
        assert!(stop[0]["hooks"][0]["command"]
            .as_str()
            .unwrap()
            .contains("ycode-notify"));
        assert!(stop[0]["hooks"][0]["command"]
            .as_str()
            .unwrap()
            .contains("stop claude"));

        // Stop has no meaningful matcher (the docs say it's ignored), so we
        // keep it as the empty string. Notification however filters subtypes:
        // we want only the two "needs human" ones, not auth_success / the
        // elicitation noise.
        assert_eq!(stop[0]["matcher"], "");

        let notif = v["hooks"]["Notification"].as_array().unwrap();
        assert_eq!(notif.len(), 1);
        assert!(notif[0]["hooks"][0]["command"]
            .as_str()
            .unwrap()
            .contains("notification claude"));
        assert_eq!(notif[0]["matcher"], "permission_prompt|idle_prompt");
    }

    #[test]
    fn claude_install_preserves_user_hooks() {
        let (_d, path) = tmp_file("settings.json");
        let user = serde_json::json!({
            "model": "claude-opus-4-7",
            "hooks": {
                "Stop": [
                    { "matcher": "myproject", "hooks": [{"type":"command","command":"echo hi"}] }
                ]
            }
        });
        std::fs::write(&path, serde_json::to_string_pretty(&user).unwrap()).unwrap();

        install_claude_hook(&path, &helper()).unwrap();

        let body = std::fs::read_to_string(&path).unwrap();
        let v: serde_json::Value = serde_json::from_str(&body).unwrap();
        // Top-level user keys untouched.
        assert_eq!(v["model"], "claude-opus-4-7");
        // User's Stop hook still there alongside ours.
        let stop = v["hooks"]["Stop"].as_array().unwrap();
        assert_eq!(stop.len(), 2);
        assert!(stop.iter().any(|e| e["matcher"] == "myproject"));
        assert!(stop.iter().any(|e| e[YCODE_MARKER_KEY] == true));
    }

    #[test]
    fn claude_install_is_idempotent() {
        let (_d, path) = tmp_file("settings.json");
        install_claude_hook(&path, &helper()).unwrap();
        install_claude_hook(&path, &helper()).unwrap();
        install_claude_hook(&path, &helper()).unwrap();

        let body = std::fs::read_to_string(&path).unwrap();
        let v: serde_json::Value = serde_json::from_str(&body).unwrap();
        // Still exactly one ycode entry per event.
        for event in ["Stop", "Notification"] {
            let arr = v["hooks"][event].as_array().unwrap();
            let mine = arr
                .iter()
                .filter(|e| e[YCODE_MARKER_KEY] == true)
                .count();
            assert_eq!(mine, 1, "event {event} had {mine} ycode entries");
        }
    }

    #[test]
    fn claude_uninstall_removes_only_ours() {
        let (_d, path) = tmp_file("settings.json");
        let user = serde_json::json!({
            "hooks": {
                "Stop": [
                    { "matcher": "x", "hooks": [{"type":"command","command":"echo x"}] }
                ]
            }
        });
        std::fs::write(&path, serde_json::to_string_pretty(&user).unwrap()).unwrap();

        install_claude_hook(&path, &helper()).unwrap();
        uninstall_claude_hook(&path).unwrap();

        let body = std::fs::read_to_string(&path).unwrap();
        let v: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert_eq!(claude_hook_status(&path).unwrap(), HookStatus::NotInstalled);

        let stop = v["hooks"]["Stop"].as_array().unwrap();
        assert_eq!(stop.len(), 1);
        assert_eq!(stop[0]["matcher"], "x");
        // Notification was added by us only — should be gone (empty arrays
        // compacted away).
        assert!(v["hooks"].get("Notification").is_none());
    }

    #[test]
    fn claude_uninstall_clean_when_we_were_only_user() {
        let (_d, path) = tmp_file("settings.json");
        install_claude_hook(&path, &helper()).unwrap();
        uninstall_claude_hook(&path).unwrap();

        let body = std::fs::read_to_string(&path).unwrap();
        let v: serde_json::Value = serde_json::from_str(&body).unwrap();
        // hooks object compacted away entirely.
        assert!(v.get("hooks").is_none());
    }

    #[test]
    fn claude_install_writes_backup_once() {
        let (_d, path) = tmp_file("settings.json");
        std::fs::write(&path, r#"{"hooks":{}}"#).unwrap();

        install_claude_hook(&path, &helper()).unwrap();
        let bak = backup_path(&path);
        assert!(bak.exists());
        let first_bak = std::fs::read_to_string(&bak).unwrap();
        assert_eq!(first_bak, r#"{"hooks":{}}"#);

        // Second install must NOT overwrite the backup with the now-modified
        // file — we want the pristine pre-ycode copy preserved.
        install_claude_hook(&path, &helper()).unwrap();
        let bak2 = std::fs::read_to_string(&bak).unwrap();
        assert_eq!(bak2, first_bak);
    }

    // ── Codex ──

    #[test]
    fn codex_status_missing_file_is_not_installed() {
        let (_d, path) = tmp_file("config.toml");
        assert_eq!(codex_notify_status(&path).unwrap(), NotifyStatus::NotInstalled);
    }

    #[test]
    fn codex_install_writes_notify_and_marker() {
        let (_d, path) = tmp_file("config.toml");
        let result = install_codex_notify(&path, &helper()).unwrap();
        assert_eq!(result, NotifyStatus::Installed);
        assert_eq!(codex_notify_status(&path).unwrap(), NotifyStatus::Installed);

        let body = std::fs::read_to_string(&path).unwrap();
        assert!(body.contains(CODEX_MARKER_COMMENT));
        assert!(body.contains("ycode-notify"));
        assert!(body.contains("turn_complete"));
    }

    #[test]
    fn codex_install_preserves_existing_settings() {
        let (_d, path) = tmp_file("config.toml");
        let user = r#"# user comment
model = "gpt-5"

[providers.openai]
api_key = "sk-xxx"
"#;
        std::fs::write(&path, user).unwrap();
        install_codex_notify(&path, &helper()).unwrap();

        let body = std::fs::read_to_string(&path).unwrap();
        assert!(body.contains("# user comment"));
        assert!(body.contains(r#"model = "gpt-5""#));
        assert!(body.contains("[providers.openai]"));
        assert!(body.contains(r#"api_key = "sk-xxx""#));
        assert!(body.contains(CODEX_MARKER_COMMENT));
    }

    #[test]
    fn codex_install_refuses_when_user_has_notify() {
        let (_d, path) = tmp_file("config.toml");
        let user = r#"notify = ["/my/own/script.sh"]
"#;
        std::fs::write(&path, user).unwrap();

        let result = install_codex_notify(&path, &helper()).unwrap();
        match result {
            NotifyStatus::ConflictUserSet { existing } => {
                assert_eq!(existing, vec!["/my/own/script.sh".to_string()]);
            }
            other => panic!("expected ConflictUserSet, got {other:?}"),
        }
        // File must not have been touched.
        let body = std::fs::read_to_string(&path).unwrap();
        assert_eq!(body, user);
        assert!(!body.contains(CODEX_MARKER_COMMENT));
    }

    #[test]
    fn codex_install_is_idempotent() {
        let (_d, path) = tmp_file("config.toml");
        std::fs::write(&path, "model = \"gpt-5\"\n").unwrap();
        install_codex_notify(&path, &helper()).unwrap();
        install_codex_notify(&path, &helper()).unwrap();
        install_codex_notify(&path, &helper()).unwrap();

        let body = std::fs::read_to_string(&path).unwrap();
        let marker_count = body.matches(CODEX_MARKER_COMMENT).count();
        let notify_count = body.matches("\nnotify = ").count();
        assert_eq!(marker_count, 1);
        assert_eq!(notify_count, 1);
    }

    #[test]
    fn codex_uninstall_removes_our_block_only() {
        let (_d, path) = tmp_file("config.toml");
        std::fs::write(&path, "model = \"gpt-5\"\napproval = \"on-request\"\n").unwrap();
        install_codex_notify(&path, &helper()).unwrap();
        uninstall_codex_notify(&path).unwrap();

        let body = std::fs::read_to_string(&path).unwrap();
        assert!(body.contains(r#"model = "gpt-5""#));
        assert!(body.contains(r#"approval = "on-request""#));
        assert!(!body.contains(CODEX_MARKER_COMMENT));
        assert!(!body.contains("notify ="));
        assert_eq!(codex_notify_status(&path).unwrap(), NotifyStatus::NotInstalled);
    }

    #[test]
    fn codex_uninstall_skips_when_user_owned() {
        let (_d, path) = tmp_file("config.toml");
        let user = r#"notify = ["/my/own/script.sh"]
"#;
        std::fs::write(&path, user).unwrap();
        uninstall_codex_notify(&path).unwrap();
        let body = std::fs::read_to_string(&path).unwrap();
        assert_eq!(body, user);
    }

    /// Regression: when the existing config ends with a table that contains
    /// typed fields (e.g. `[tui.foo]\n"x" = 1`), a naive trailing append
    /// makes our `notify = [...]` parse as a member of that table, breaking
    /// the host CLI on the next launch. The install must place our line
    /// above the first `[table]` header so it stays a root-level key.
    #[test]
    fn codex_install_does_not_break_trailing_table() {
        let (_d, path) = tmp_file("config.toml");
        let user = "model = \"gpt-5\"\n\n[tui.model_availability_nux]\n\"gpt-5\" = 1\n";
        std::fs::write(&path, user).unwrap();
        install_codex_notify(&path, &helper()).unwrap();

        let body = std::fs::read_to_string(&path).unwrap();
        // Must still parse as valid TOML with `tui.model_availability_nux.\"gpt-5\"`
        // staying an integer (not getting a stray `notify` sibling that
        // turns the table into a sequence-typed mess).
        let doc: toml_edit::DocumentMut = body.parse().unwrap();
        assert!(doc.get("notify").is_some(), "notify must be root-level");
        let nux = doc["tui"]["model_availability_nux"]
            .as_table()
            .expect("nux still a table");
        assert!(nux.get("notify").is_none(), "notify must NOT live under tui.*");
        assert_eq!(nux.get("gpt-5").and_then(|v| v.as_integer()), Some(1));
    }

    #[test]
    fn codex_chain_install_does_not_break_trailing_table() {
        let (_d, path) = tmp_file("config.toml");
        let user = "notify = [\"/old/script\"]\n\n[tui.model_availability_nux]\n\"gpt-5\" = 1\n";
        std::fs::write(&path, user).unwrap();
        let existing = match codex_notify_status(&path).unwrap() {
            NotifyStatus::ConflictUserSet { existing } => existing,
            other => panic!("expected conflict, got {other:?}"),
        };
        install_codex_notify_chain(&path, &helper(), &existing).unwrap();

        let body = std::fs::read_to_string(&path).unwrap();
        let doc: toml_edit::DocumentMut = body.parse().unwrap();
        let notify = doc.get("notify").expect("root notify").as_array().unwrap();
        // First arg points at the helper; --next encodes the old script.
        assert!(notify
            .get(0)
            .and_then(|v| v.as_str())
            .unwrap()
            .contains("ycode-notify"));
        let nux = doc["tui"]["model_availability_nux"].as_table().unwrap();
        assert_eq!(nux.get("gpt-5").and_then(|v| v.as_integer()), Some(1));
        assert!(nux.get("notify").is_none());
    }

    #[test]
    fn codex_chain_wraps_existing_notify() {
        let (_d, path) = tmp_file("config.toml");
        std::fs::write(&path, "model = \"gpt-5\"\n").unwrap();
        let existing = vec![
            "/path/to/sky".to_string(),
            "turn-ended".to_string(),
            "--previous-notify".to_string(),
            r#"["/bin/bash","/x/codex-notify.sh"]"#.to_string(),
        ];
        let status = install_codex_notify_chain(&path, &helper(), &existing).unwrap();
        assert_eq!(status, NotifyStatus::Installed);

        let body = std::fs::read_to_string(&path).unwrap();
        assert!(body.contains(CODEX_MARKER_COMMENT));
        assert!(body.contains("--next"));
        assert!(body.contains("ycode-notify"));
        // The pre-existing tool's path is preserved inside the encoded chain.
        assert!(body.contains("/path/to/sky"));
        assert!(body.contains("/x/codex-notify.sh"));
    }

    #[test]
    fn codex_chain_uninstall_restores_original_notify() {
        let (_d, path) = tmp_file("config.toml");
        // Seed with the user's existing notify, simulating the real-world
        // pre-install state.
        let original = r#"notify = ["/path/to/sky", "turn-ended", "--previous-notify", "[\"/bin/bash\",\"/x/codex-notify.sh\"]"]
"#;
        std::fs::write(&path, original).unwrap();

        // The patcher reads the existing argv via status, then wraps it.
        let existing = match codex_notify_status(&path).unwrap() {
            NotifyStatus::ConflictUserSet { existing } => existing,
            other => panic!("expected conflict, got {other:?}"),
        };
        install_codex_notify_chain(&path, &helper(), &existing).unwrap();
        assert_eq!(codex_notify_status(&path).unwrap(), NotifyStatus::Installed);

        // Uninstall must restore the original argv as a plain user notify.
        uninstall_codex_notify(&path).unwrap();
        let after = codex_notify_status(&path).unwrap();
        match after {
            NotifyStatus::ConflictUserSet { existing: restored } => {
                assert_eq!(restored, existing, "round-trip preserves argv");
            }
            other => panic!("expected restored user notify, got {other:?}"),
        }
        let body = std::fs::read_to_string(&path).unwrap();
        assert!(!body.contains(CODEX_MARKER_COMMENT));
        assert!(!body.contains("--next"));
    }
}
