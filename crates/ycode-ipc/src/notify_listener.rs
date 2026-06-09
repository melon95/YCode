//! Local IPC listener for agent CLI completion hooks.
//!
//! Each PTY-spawned CLI gets `YCODE_NOTIFY_SOCK` in its environment pointing
//! at a Unix domain socket this listener owns. When the CLI's hook system
//! (Claude `Stop`, Codex `notify`) fires, it invokes the bundled
//! `ycode-notify` helper, which connects to that socket and writes one
//! newline-terminated JSON object. We parse it and forward an
//! [`UiEventKind::AgentTurnComplete`] onto the UI bus.
//!
//! Lifecycle:
//! 1. `bind` creates the socket (unlinking any stale file first).
//! 2. `run` accepts in a loop, reading one line per connection.
//! 3. The listener exits when `cancel` is triggered and the socket file
//!    is unlinked.

use std::path::{Path, PathBuf};

use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};
use tokio::sync::broadcast;
use tokio_util::sync::CancellationToken;
use tracing::{debug, info, warn};

use crate::events::UiEvent;

/// Construct a per-process socket path under `$TMPDIR`. Using the running
/// ycode pid keeps every instance isolated so a leftover socket from a
/// previous crashed run can't accidentally route hook events to the wrong
/// app — and the unlink in [`bind`] always targets a path the current
/// process owns.
pub fn default_socket_path() -> PathBuf {
    let tmp = std::env::var_os("TMPDIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    tmp.join(format!("ycode-notify-{}.sock", std::process::id()))
}

/// Bind the listener socket and start the accept loop in a background task.
/// Returns the bound socket path so callers can pass it through
/// `YCODE_NOTIFY_SOCK` when spawning agent CLIs.
///
/// Bind failure is non-fatal — we log and return `None`. The app continues
/// without completion notifications instead of refusing to start.
#[cfg(unix)]
pub fn start(
    bus: broadcast::Sender<UiEvent>,
    cancel: CancellationToken,
    sock_path: PathBuf,
) -> Option<PathBuf> {
    use tokio::net::UnixListener;

    // Stale-file cleanup. `bind` will return EADDRINUSE if the file exists
    // even when no one is listening on it — common after a crash.
    if sock_path.exists() {
        if let Err(e) = std::fs::remove_file(&sock_path) {
            warn!(path = %sock_path.display(), error = %e, "could not remove stale notify socket");
            return None;
        }
    }

    let listener = match UnixListener::bind(&sock_path) {
        Ok(l) => l,
        Err(e) => {
            warn!(path = %sock_path.display(), error = %e, "notify socket bind failed; completion notifications disabled");
            return None;
        }
    };

    info!(path = %sock_path.display(), "notify listener started");
    let path_for_task = sock_path.clone();
    let bus_for_task = bus;
    let cancel_for_task = cancel;
    tokio::spawn(async move {
        run_accept_loop(listener, bus_for_task, cancel_for_task.clone()).await;
        // Best-effort cleanup. If this fails the next ycode launch's
        // `remove_file` will take care of it.
        let _ = std::fs::remove_file(&path_for_task);
        debug!(path = %path_for_task.display(), "notify listener stopped");
    });

    Some(sock_path)
}

#[cfg(not(unix))]
pub fn start(
    _bus: broadcast::Sender<UiEvent>,
    _cancel: CancellationToken,
    _sock_path: PathBuf,
) -> Option<PathBuf> {
    // Windows named-pipe support is deferred — v1 ships Unix-only. Callers
    // get back `None` and skip injecting YCODE_NOTIFY_SOCK into spawned
    // children, which short-circuits the helper at the other end.
    None
}

#[cfg(unix)]
async fn run_accept_loop(
    listener: tokio::net::UnixListener,
    bus: broadcast::Sender<UiEvent>,
    cancel: CancellationToken,
) {
    loop {
        tokio::select! {
            biased;
            _ = cancel.cancelled() => return,
            accepted = listener.accept() => match accepted {
                Ok((stream, _addr)) => {
                    let bus = bus.clone();
                    tokio::spawn(async move {
                        handle_connection(stream, bus).await;
                    });
                }
                Err(e) => {
                    warn!(error = %e, "notify accept failed");
                    // Bursty accept errors shouldn't pin a CPU. A short
                    // delay lets transient FD pressure clear.
                    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                }
            }
        }
    }
}

#[cfg(unix)]
async fn handle_connection(stream: tokio::net::UnixStream, bus: broadcast::Sender<UiEvent>) {
    // Cap the payload so a malformed sender can't make us read forever.
    // Real hook payloads are well under this — Claude's Stop JSON is a few
    // hundred bytes; Codex's notify wrapper is similar.
    const MAX_PAYLOAD: usize = 128 * 1024;

    let mut reader = BufReader::new(stream).take(MAX_PAYLOAD as u64);
    let mut line = String::new();
    match reader.read_line(&mut line).await {
        Ok(0) => return,
        Ok(_) => {}
        Err(e) => {
            debug!(error = %e, "notify connection read error");
            return;
        }
    }

    let trimmed = line.trim();
    if trimmed.is_empty() {
        return;
    }
    match parse_payload(trimmed) {
        Some(event) => {
            // Sending to the broadcast channel fails only if there are no
            // subscribers — that's fine, the event would be dropped anyway.
            let _ = bus.send(event);
        }
        None => {
            warn!(payload = %trimmed, "notify payload could not be parsed");
        }
    }
}

/// Parse a single helper payload line into a `UiEvent`. Returns `None` for
/// malformed input or when the required `terminal_id` field is missing —
/// without a routing id there's nowhere meaningful to send the event.
///
/// Body preview is sourced per-(source, event):
/// - Codex `turn_complete`: `extra[0]` JSON's `last-assistant-message`
/// - Claude `notification`: stdin JSON's `message` field (the hook's
///   per-event payload already carries the user-facing text)
/// - Claude `stop`: tail the transcript jsonl referenced by stdin and pull
///   the final assistant turn's text
///
/// Extraction failure is silent — the host falls back to the generic
/// "<source> finished its turn" body.
fn parse_payload(line: &str) -> Option<UiEvent> {
    let value: serde_json::Value = serde_json::from_str(line).ok()?;
    let terminal_id = value.get("terminal_id")?.as_str()?;
    if terminal_id.is_empty() {
        return None;
    }
    let source = value
        .get("source")
        .and_then(|v| v.as_str())
        .unwrap_or("unknown");
    let event_kind = value
        .get("event")
        .and_then(|v| v.as_str())
        .unwrap_or("stop");

    let body_preview = match (source, event_kind) {
        ("codex", "permission_request") => extract_codex_permission_request(&value),
        ("codex", _) => extract_codex_message(&value),
        ("claude", "notification") => extract_claude_notification_message(&value),
        ("claude", _) => extract_claude_transcript_tail(&value),
        _ => None,
    }
    .map(|s| truncate_preview(&s, 200));

    Some(UiEvent::agent_turn_complete(
        terminal_id,
        source,
        event_kind,
        body_preview,
    ))
}

/// Build the notification body for Codex's `PermissionRequest` hook. The
/// hook pipes a JSON object to stdin (we forward it verbatim under
/// `stdin`); meaningful fields for the body are:
///
/// - `tool_input.description` — human-readable approval reason if Codex
///   has one (e.g. "Run `rm -rf node_modules`")
/// - `tool_input.command` — Bash command being requested (`Bash` tool)
/// - `tool_name` — fallback label when no description is available
///
/// We prefer description, fall back to a tool-name-prefixed command, then
/// to just the tool name. Empty/missing → `None` and the host shows the
/// generic "Codex needs your approval" body.
fn extract_codex_permission_request(payload: &serde_json::Value) -> Option<String> {
    let stdin = payload.get("stdin")?.as_str()?;
    let parsed: serde_json::Value = serde_json::from_str(stdin).ok()?;
    let tool_name = parsed.get("tool_name").and_then(|v| v.as_str()).unwrap_or("");
    let tool_input = parsed.get("tool_input");
    let tool_label = format_codex_tool_label(tool_name);

    // Preferred: explicit human-readable description.
    if let Some(s) = tool_input
        .and_then(|v| v.get("description"))
        .and_then(|v| v.as_str())
    {
        let t = s.trim();
        if !t.is_empty() {
            return Some(t.to_string());
        }
    }

    // Bash and similar tools carry the requested command directly.
    if let Some(s) = tool_input
        .and_then(|v| v.get("command"))
        .and_then(|v| v.as_str())
    {
        let t = s.trim();
        if !t.is_empty() {
            return Some(if tool_label.is_empty() {
                t.to_string()
            } else {
                format!("{tool_label}: {t}")
            });
        }
    }

    // Last-ditch: tool label alone. Still informative — "apply_patch" tells
    // the user it's a file edit, "codeagentswarm-tasks / check_active" tells
    // them which MCP server is asking, even without parameters.
    if !tool_label.is_empty() {
        return Some(tool_label);
    }
    None
}

/// Render Codex's `tool_name` wire string into a label that reads like the
/// in-CLI TUI. Codex names MCP tools `mcp__<server>__<tool>` on the wire
/// (underscores everywhere) but its own permission dialog shows
/// "codeagentswarm-tasks MCP server to run tool 'check_active'" — server
/// dashed, prefix dropped, tool kept verbatim. Mirror that so the
/// notification body stays scannable instead of bleeding `mcp__…__` noise.
///
/// Non-MCP names (`Bash`, `apply_patch`, future first-party tools) pass
/// through unchanged.
fn format_codex_tool_label(tool_name: &str) -> String {
    let Some(rest) = tool_name.strip_prefix("mcp__") else {
        return tool_name.to_string();
    };
    // `split_once` on the `__` separator: anything left of the first `__`
    // is the server, anything right is the tool (which may itself contain
    // single underscores — `check_active` keeps them).
    let Some((server, tool)) = rest.split_once("__") else {
        // Malformed `mcp__foo` with no second separator: surface just the
        // remaining name rather than dropping it entirely.
        return rest.to_string();
    };
    let server_pretty = server.replace('_', "-");
    format!("{server_pretty} / {tool}")
}

/// Pick the assistant text out of Codex's notify payload, which arrives as
/// the first element of `extra` (a JSON string Codex appends after our argv).
/// Field name is `last-assistant-message` per current Codex; we also accept
/// the underscored variant in case it shifts in a future release.
fn extract_codex_message(payload: &serde_json::Value) -> Option<String> {
    let extras = payload.get("extra")?.as_array()?;
    let first = extras.first()?.as_str()?;
    let obj: serde_json::Value = serde_json::from_str(first).ok()?;
    for key in ["last-assistant-message", "last_assistant_message"] {
        if let Some(s) = obj.get(key).and_then(|v| v.as_str()) {
            if !s.trim().is_empty() {
                return Some(s.to_string());
            }
        }
    }
    None
}

/// Pull the user-facing text out of a Claude `Notification` hook. The event's
/// own JSON payload (piped to stdin by the hook runner) carries a `message`
/// field already — that's the same string Claude Code would have shown to the
/// user. Skipping the transcript tail here saves a file read on the
/// "permission needed" / "idle" path, which is the hot one for the
/// "needs your attention" notification.
fn extract_claude_notification_message(payload: &serde_json::Value) -> Option<String> {
    let stdin = payload.get("stdin")?.as_str()?;
    let parsed: serde_json::Value = serde_json::from_str(stdin).ok()?;
    let msg = parsed.get("message")?.as_str()?;
    let trimmed = msg.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

/// Read the last `"type":"assistant"` line out of Claude's transcript jsonl
/// referenced by its hook stdin (`transcript_path` field). Joins all `text`
/// content parts in order. Returns `None` if the file is missing, empty, or
/// contains no assistant turn (e.g. the hook fired mid-tool before any
/// model output landed).
///
/// Only the `Stop` hook needs this — `Notification` already carries the
/// human-readable string in stdin (see
/// [`extract_claude_notification_message`]).
fn extract_claude_transcript_tail(payload: &serde_json::Value) -> Option<String> {
    let stdin = payload.get("stdin")?.as_str()?;
    let parsed: serde_json::Value = serde_json::from_str(stdin).ok()?;
    let path_str = parsed.get("transcript_path")?.as_str()?;
    let raw = std::fs::read_to_string(path_str).ok()?;
    raw.lines().rev().find_map(|line| {
        let v: serde_json::Value = serde_json::from_str(line).ok()?;
        if v.get("type")?.as_str()? != "assistant" {
            return None;
        }
        let content = v.get("message")?.get("content")?.as_array()?;
        let mut buf = String::new();
        for item in content {
            if item.get("type").and_then(|x| x.as_str()) == Some("text") {
                if let Some(t) = item.get("text").and_then(|v| v.as_str()) {
                    if !buf.is_empty() {
                        buf.push('\n');
                    }
                    buf.push_str(t);
                }
            }
        }
        if buf.trim().is_empty() {
            None
        } else {
            Some(buf)
        }
    })
}

/// Truncate at character (not byte) boundary so a multibyte tail can't get
/// sliced mid-codepoint. macOS notification bodies render ~4 lines tops, so
/// 200 chars is the practical ceiling.
fn truncate_preview(s: &str, max_chars: usize) -> String {
    let trimmed = s.trim();
    let count = trimmed.chars().count();
    if count <= max_chars {
        return trimmed.to_string();
    }
    let mut out: String = trimmed.chars().take(max_chars).collect();
    out.push('…');
    out
}

/// Return true if `path` is a valid existing socket path. Used by tests
/// and for diagnostics; production code just trusts `start` to have
/// returned a working path.
#[allow(dead_code)]
pub(crate) fn socket_exists(path: &Path) -> bool {
    path.exists()
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::time::Duration;
    use tokio::io::AsyncWriteExt;
    use tokio::net::UnixStream;

    fn unique_sock_path() -> (tempfile::TempDir, PathBuf) {
        // macOS sockaddr_un caps at 104 bytes including the NUL terminator,
        // and `$TMPDIR` under `/var/folders/...` already eats ~50 chars. A
        // full ulid (26 chars) + the prefix pushes us over on some setups.
        // Keep each test isolated in a short /tmp directory.
        use std::sync::atomic::{AtomicU64, Ordering};
        static SEQ: AtomicU64 = AtomicU64::new(0);
        let n = SEQ.fetch_add(1, Ordering::Relaxed);
        let dir = tempfile::Builder::new()
            .prefix(&format!("yc{}-{n}-", std::process::id()))
            .tempdir_in("/tmp")
            .unwrap();
        let path = dir.path().join("n.sock");
        (dir, path)
    }

    fn unix_socket_bind_available() -> bool {
        let (_dir, path) = unique_sock_path();
        match std::os::unix::net::UnixListener::bind(&path) {
            Ok(listener) => {
                drop(listener);
                let _ = std::fs::remove_file(path);
                true
            }
            Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => false,
            Err(_) => false,
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn forwards_valid_payload() {
        if !unix_socket_bind_available() {
            eprintln!("skipping Unix socket listener test: bind is not permitted");
            return;
        }
        let (tx, mut rx) = broadcast::channel::<UiEvent>(16);
        let cancel = CancellationToken::new();
        let (_dir, path) = unique_sock_path();
        let bound = start(tx, cancel.clone(), path.clone()).expect("listener should bind");
        assert!(bound.exists());

        // Give the accept loop a tick to be ready.
        tokio::time::sleep(Duration::from_millis(20)).await;

        let mut sock = UnixStream::connect(&bound).await.unwrap();
        let payload = r#"{"terminal_id":"t-1","source":"claude","event":"stop"}"#;
        sock.write_all(payload.as_bytes()).await.unwrap();
        sock.write_all(b"\n").await.unwrap();
        sock.shutdown().await.unwrap();

        let ev = tokio::time::timeout(Duration::from_secs(2), rx.recv())
            .await
            .expect("listener should emit within 2s")
            .expect("broadcast receive");
        assert_eq!(ev.session_id, "t-1");
        match ev.kind {
            crate::events::UiEventKind::AgentTurnComplete {
                source,
                event_kind,
                body_preview,
            } => {
                assert_eq!(source, "claude");
                assert_eq!(event_kind, "stop");
                assert!(
                    body_preview.is_none(),
                    "no transcript available in this test"
                );
            }
            other => panic!("unexpected event kind: {other:?}"),
        }

        cancel.cancel();
        // Give the cleanup task time to run before the test exits.
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(!path.exists(), "socket file should be cleaned up on cancel");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn ignores_payload_without_terminal_id() {
        if !unix_socket_bind_available() {
            eprintln!("skipping Unix socket listener test: bind is not permitted");
            return;
        }
        let (tx, mut rx) = broadcast::channel::<UiEvent>(16);
        let cancel = CancellationToken::new();
        let (_dir, path) = unique_sock_path();
        let bound = start(tx, cancel.clone(), path).expect("listener should bind");

        tokio::time::sleep(Duration::from_millis(20)).await;
        let mut sock = UnixStream::connect(&bound).await.unwrap();
        sock.write_all(b"{\"source\":\"codex\",\"event\":\"stop\"}\n")
            .await
            .unwrap();
        sock.shutdown().await.unwrap();

        // No event should arrive; assert by timing out a short window.
        let res = tokio::time::timeout(Duration::from_millis(150), rx.recv()).await;
        assert!(res.is_err(), "missing terminal_id must drop the payload");
        cancel.cancel();
    }

    #[test]
    fn extract_codex_pulls_last_assistant_message() {
        let inner = r#"{"type":"agent-turn-complete","thread-id":"t","turn-id":"u","cwd":"/x","client":"cli","input-messages":["hi"],"last-assistant-message":"Done — wrote 3 files."}"#;
        let outer = serde_json::json!({
            "terminal_id": "t-1",
            "source": "codex",
            "event": "turn_complete",
            "stdin": "",
            "extra": [inner],
        });
        let got = super::extract_codex_message(&outer).unwrap();
        assert_eq!(got, "Done — wrote 3 files.");
    }

    #[test]
    fn extract_codex_handles_missing_field() {
        let inner = r#"{"type":"agent-turn-complete"}"#;
        let outer = serde_json::json!({"extra": [inner]});
        assert!(super::extract_codex_message(&outer).is_none());
    }

    /// PermissionRequest hook body should prefer `description` when present.
    /// This is the user-facing "why" Codex sometimes attaches to a tool
    /// call — way more useful than the raw command line.
    #[test]
    fn extract_codex_permission_uses_description() {
        let inner = serde_json::json!({
            "tool_name": "Bash",
            "tool_input": {
                "command": "rm -rf node_modules",
                "description": "Clean dependency cache before reinstall"
            }
        });
        let outer = serde_json::json!({
            "stdin": inner.to_string(),
        });
        assert_eq!(
            super::extract_codex_permission_request(&outer),
            Some("Clean dependency cache before reinstall".to_string()),
        );
    }

    /// No description → fall back to `tool_name: command` so the user can
    /// at least see what's about to run.
    #[test]
    fn extract_codex_permission_falls_back_to_command() {
        let inner = serde_json::json!({
            "tool_name": "Bash",
            "tool_input": { "command": "psql -c 'DROP DATABASE prod'" }
        });
        let outer = serde_json::json!({ "stdin": inner.to_string() });
        assert_eq!(
            super::extract_codex_permission_request(&outer),
            Some("Bash: psql -c 'DROP DATABASE prod'".to_string()),
        );
    }

    /// MCP tool calls don't have a `command` field; the body should still
    /// surface the canonical tool name so the user knows what tool is
    /// asking, even without parameters. Format-wise, the `mcp__server__tool`
    /// wire string is rewritten into the TUI-style "server / tool" so the
    /// notification reads at a glance instead of as raw schema noise.
    #[test]
    fn extract_codex_permission_falls_back_to_tool_name_only() {
        let inner = serde_json::json!({
            "tool_name": "mcp__fs__write",
            "tool_input": { "path": "/etc/hosts" }
        });
        let outer = serde_json::json!({ "stdin": inner.to_string() });
        assert_eq!(
            super::extract_codex_permission_request(&outer),
            Some("fs / write".to_string()),
        );
    }

    /// Real-world case caught the original bug: a server name with
    /// underscores (`codeagentswarm_tasks`) gets dashed for display, the
    /// `mcp__` prefix drops, and the tool name keeps its internal
    /// underscores. Matches what Codex's own TUI prompt shows.
    #[test]
    fn extract_codex_permission_dashes_mcp_server_name() {
        let inner = serde_json::json!({
            "tool_name": "mcp__codeagentswarm_tasks__check_active",
            "tool_input": {}
        });
        let outer = serde_json::json!({ "stdin": inner.to_string() });
        assert_eq!(
            super::extract_codex_permission_request(&outer),
            Some("codeagentswarm-tasks / check_active".to_string()),
        );
    }

    /// Non-MCP tool names (`Bash`, `apply_patch`, …) must pass through
    /// untouched — they're already display-friendly and changing them
    /// would mangle the existing "Bash: …" path.
    #[test]
    fn extract_codex_permission_non_mcp_tool_label_passes_through() {
        let inner = serde_json::json!({
            "tool_name": "apply_patch",
            "tool_input": {}
        });
        let outer = serde_json::json!({ "stdin": inner.to_string() });
        assert_eq!(
            super::extract_codex_permission_request(&outer),
            Some("apply_patch".to_string()),
        );
    }

    /// Bash with a command but no description should prefix the formatted
    /// label — `Bash` is not MCP so it stays bare — and append the command.
    /// Regression guard for the format_codex_tool_label refactor.
    #[test]
    fn extract_codex_permission_bash_uses_tool_label_with_command() {
        let inner = serde_json::json!({
            "tool_name": "Bash",
            "tool_input": { "command": "ls -la" }
        });
        let outer = serde_json::json!({ "stdin": inner.to_string() });
        assert_eq!(
            super::extract_codex_permission_request(&outer),
            Some("Bash: ls -la".to_string()),
        );
    }

    /// Codex always passes JSON via stdin for PermissionRequest, so an
    /// empty stdin means malformed input — should return None and let the
    /// host show its generic "needs your approval" fallback.
    #[test]
    fn extract_codex_permission_missing_stdin_is_none() {
        let outer = serde_json::json!({ "stdin": "" });
        assert!(super::extract_codex_permission_request(&outer).is_none());
    }

    /// End-to-end: parse_payload routes Codex permission_request through
    /// the new extractor and surfaces the description as body_preview.
    #[test]
    fn parse_payload_codex_permission_request_uses_description() {
        let stdin_json = serde_json::json!({
            "tool_name": "apply_patch",
            "tool_input": {
                "description": "Edit src/lib.rs to add the new function",
            }
        });
        let outer = serde_json::json!({
            "terminal_id": "t-1",
            "source": "codex",
            "event": "permission_request",
            "stdin": stdin_json.to_string(),
        });
        let line = serde_json::to_string(&outer).unwrap();
        let event = super::parse_payload(&line).expect("payload should parse");
        match event.kind {
            crate::events::UiEventKind::AgentTurnComplete {
                source,
                event_kind,
                body_preview,
            } => {
                assert_eq!(source, "codex");
                assert_eq!(event_kind, "permission_request");
                assert_eq!(
                    body_preview.as_deref(),
                    Some("Edit src/lib.rs to add the new function"),
                );
            }
            other => panic!("unexpected event kind: {other:?}"),
        }
    }

    #[test]
    fn extract_claude_reads_transcript_last_assistant() {
        let dir = tempfile::tempdir().unwrap();
        let transcript = dir.path().join("session.jsonl");
        // Mix of event types — only the final assistant turn matters.
        let lines = [
            r#"{"type":"user","message":{"content":"hi"}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"first"}]}}"#,
            r#"{"type":"tool_use","tool":"Bash"}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"line one"},{"type":"text","text":"line two"}]}}"#,
        ];
        std::fs::write(&transcript, lines.join("\n")).unwrap();

        let stdin_json = serde_json::json!({
            "session_id": "s",
            "transcript_path": transcript.to_string_lossy(),
            "hook_event_name": "Stop",
        });
        let outer = serde_json::json!({"stdin": stdin_json.to_string()});

        let got = super::extract_claude_transcript_tail(&outer).unwrap();
        assert_eq!(got, "line one\nline two");
    }

    #[test]
    fn extract_claude_missing_transcript_is_none() {
        let stdin_json = serde_json::json!({
            "transcript_path": "/nonexistent/path/xyz.jsonl",
        });
        let outer = serde_json::json!({"stdin": stdin_json.to_string()});
        assert!(super::extract_claude_transcript_tail(&outer).is_none());
    }

    /// Notification payloads carry the user-facing text in stdin's `message`
    /// field — no transcript IO required. This is the hot path on permission
    /// prompts / idle prompts and we want to confirm it bypasses the file
    /// read entirely.
    #[test]
    fn extract_claude_notification_pulls_message_field() {
        let stdin_json = serde_json::json!({
            "session_id": "s",
            "hook_event_name": "Notification",
            "message": "Claude needs your permission to use Bash",
            // A bogus transcript path proves the notification path doesn't
            // touch the file: if it did, we'd get None instead of the message.
            "transcript_path": "/nonexistent/should/not/be/read.jsonl",
        });
        let outer = serde_json::json!({
            "terminal_id": "t-1",
            "source": "claude",
            "event": "notification",
            "stdin": stdin_json.to_string(),
        });

        let got = super::extract_claude_notification_message(&outer).unwrap();
        assert_eq!(got, "Claude needs your permission to use Bash");
    }

    /// End-to-end: parse_payload for a Claude notification event must use the
    /// `message` field rather than tailing the transcript, even when both are
    /// present in stdin.
    #[test]
    fn parse_payload_claude_notification_uses_message() {
        let stdin_json = serde_json::json!({
            "session_id": "s",
            "hook_event_name": "Notification",
            "message": "Claude is waiting for your input",
            "transcript_path": "/nonexistent/xyz.jsonl",
        });
        let outer = serde_json::json!({
            "terminal_id": "t-1",
            "source": "claude",
            "event": "notification",
            "stdin": stdin_json.to_string(),
        });
        let line = serde_json::to_string(&outer).unwrap();
        let event = super::parse_payload(&line).expect("payload should parse");
        match event.kind {
            crate::events::UiEventKind::AgentTurnComplete {
                source,
                event_kind,
                body_preview,
            } => {
                assert_eq!(source, "claude");
                assert_eq!(event_kind, "notification");
                assert_eq!(
                    body_preview.as_deref(),
                    Some("Claude is waiting for your input"),
                );
            }
            other => panic!("unexpected event kind: {other:?}"),
        }
    }

    #[test]
    fn truncate_keeps_short_strings() {
        assert_eq!(super::truncate_preview("hello", 200), "hello");
        assert_eq!(super::truncate_preview("  spaced  ", 200), "spaced");
    }

    #[test]
    fn truncate_appends_ellipsis_at_char_boundary() {
        // 5 multibyte chars + ASCII tail, cap at 5 → keep first 5 chars + …
        let s = "héllo world";
        let got = super::truncate_preview(s, 5);
        assert_eq!(got, "héllo…");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn rebinds_over_stale_socket() {
        if !unix_socket_bind_available() {
            eprintln!("skipping Unix socket listener test: bind is not permitted");
            return;
        }
        let (_dir, path) = unique_sock_path();
        // Pre-create a leftover file as if a previous run had crashed.
        std::fs::write(&path, b"stale").unwrap();

        let (tx, _rx) = broadcast::channel::<UiEvent>(16);
        let cancel = CancellationToken::new();
        let bound = start(tx, cancel.clone(), path.clone());
        assert!(bound.is_some(), "should overwrite stale socket file");
        cancel.cancel();
    }
}
