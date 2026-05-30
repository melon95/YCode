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
/// Extracts a short "last assistant message" preview for the notification
/// body when possible: Codex passes it directly in the `extra[0]` JSON
/// (`last-assistant-message`), Claude requires reading the transcript jsonl
/// referenced by its hook stdin. Extraction failure is silent — the host
/// then falls back to the generic "<source> finished its turn" body.
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

    let body_preview = match source {
        "codex" => extract_codex_message(&value),
        "claude" => extract_claude_message(&value),
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

/// Read the last `"type":"assistant"` line out of Claude's transcript jsonl
/// referenced by its hook stdin (`transcript_path` field). Joins all `text`
/// content parts in order. Returns `None` if the file is missing, empty, or
/// contains no assistant turn (e.g. the hook fired mid-tool before any
/// model output landed).
fn extract_claude_message(payload: &serde_json::Value) -> Option<String> {
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

    fn unique_sock_path() -> PathBuf {
        // macOS sockaddr_un caps at 104 bytes including the NUL terminator,
        // and `$TMPDIR` under `/var/folders/...` already eats ~50 chars. A
        // full ulid (26 chars) + the prefix pushes us over on some setups,
        // so we use `/tmp` and a short counter — collisions across parallel
        // tests are still effectively zero.
        use std::sync::atomic::{AtomicU64, Ordering};
        static SEQ: AtomicU64 = AtomicU64::new(0);
        let n = SEQ.fetch_add(1, Ordering::Relaxed);
        PathBuf::from(format!("/tmp/yc-nt-{}-{n}.sock", std::process::id()))
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn forwards_valid_payload() {
        let (tx, mut rx) = broadcast::channel::<UiEvent>(16);
        let cancel = CancellationToken::new();
        let path = unique_sock_path();
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
                assert!(body_preview.is_none(), "no transcript available in this test");
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
        let (tx, mut rx) = broadcast::channel::<UiEvent>(16);
        let cancel = CancellationToken::new();
        let path = unique_sock_path();
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

        let got = super::extract_claude_message(&outer).unwrap();
        assert_eq!(got, "line one\nline two");
    }

    #[test]
    fn extract_claude_missing_transcript_is_none() {
        let stdin_json = serde_json::json!({
            "transcript_path": "/nonexistent/path/xyz.jsonl",
        });
        let outer = serde_json::json!({"stdin": stdin_json.to_string()});
        assert!(super::extract_claude_message(&outer).is_none());
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
        let path = unique_sock_path();
        // Pre-create a leftover file as if a previous run had crashed.
        std::fs::write(&path, b"stale").unwrap();

        let (tx, _rx) = broadcast::channel::<UiEvent>(16);
        let cancel = CancellationToken::new();
        let bound = start(tx, cancel.clone(), path.clone());
        assert!(bound.is_some(), "should overwrite stale socket file");
        cancel.cancel();
    }
}
