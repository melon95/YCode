//! One running language server.
//!
//! `LspSession::spawn` launches the binary, drives the `initialize` /
//! `initialized` handshake, and leaves three background tasks running:
//!
//! - **writer** — drains an mpsc queue onto the child's stdin, frame by
//!   frame, so callers don't have to take a lock to send.
//! - **reader** — peels Content-Length framed messages off stdout. Responses
//!   get routed to their pending `oneshot` by id. Server-initiated
//!   notifications get handed to a `MessageSink` so the IPC layer can choose
//!   what to do with them (today: forward diagnostics onto the UI bus).
//! - **stderr drain** — keeps the child from blocking on a full stderr pipe
//!   and surfaces server traces in our tracing log.
//!
//! Server-initiated *requests* (window/workDoneProgress/create, etc.) are
//! noted in the log but not answered — none of the methods we drive depend
//! on the server's request-side capabilities. A future PR can grow a proper
//! handler if a server we add insists.

use std::collections::HashMap;
use std::path::Path;
use std::process::Stdio;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;

use serde_json::{json, Value};
use tokio::io::BufReader;
use tokio::process::{Child, Command};
use tokio::sync::{mpsc, oneshot, RwLock};
use tracing::{debug, info, warn};

use crate::dirs::server_root;
use crate::manifest::ServerManifest;
use crate::protocol::{read_message, write_message, IncomingMessage, RequestId, ResponseError};
use crate::LspError;

/// Token type legend handed to every server during `initialize`. We pin a
/// VSCode-default-ish set so the wire encoding is stable across servers —
/// the frontend gets a `Vec<u32>` and maps `tokenTypeIdx → CSS class` from
/// the same list, no per-server adapter required.
pub const TOKEN_TYPES: &[&str] = &[
    "namespace",
    "type",
    "class",
    "enum",
    "interface",
    "struct",
    "typeParameter",
    "parameter",
    "variable",
    "property",
    "enumMember",
    "event",
    "function",
    "method",
    "macro",
    "keyword",
    "modifier",
    "comment",
    "string",
    "number",
    "regexp",
    "operator",
    "decorator",
];

/// Notifications surfaced to the IPC layer. We don't model every LSP
/// server-→client message — only the ones a caller actually consumes today.
#[derive(Clone, Debug)]
pub enum ServerNotification {
    /// `textDocument/publishDiagnostics` — passed through verbatim so the
    /// IPC layer can decide whether/how to surface it.
    PublishDiagnostics { uri: String, params: Value },
}

/// Hook the IPC layer registers on construction so server-initiated traffic
/// can leave the lsp crate without coupling it to `ycode-ipc::UiEvent`.
pub type NotificationSink =
    Arc<dyn Fn(&str, ServerNotification) + Send + Sync + 'static>;

pub struct LspSession {
    pub server_id: String,
    pub project_id: String,
    /// `file://<repo_root>` — passed in `initialize` and reused for diagnostic
    /// routing on the frontend.
    pub root_uri: String,
    /// Outbound queue. Background writer drains it.
    write_tx: mpsc::Sender<Vec<u8>>,
    /// id → response sender. Responses are popped here by the reader.
    pending: Arc<RwLock<HashMap<RequestId, oneshot::Sender<Result<Value, ResponseError>>>>>,
    next_id: AtomicI64,
}

impl LspSession {
    /// Launch the server binary described by `manifest`, complete the
    /// initialize handshake, and return a ready-to-use session.
    pub async fn spawn(
        manifest: &ServerManifest,
        project_id: String,
        project_root: &Path,
        sink: NotificationSink,
    ) -> Result<Arc<Self>, LspError> {
        let server_dir = server_root(&manifest.id)?;
        let server_dir_str = server_dir.as_str().to_string();
        let binary = manifest
            .command
            .binary
            .replace("${SERVER_DIR}", &server_dir_str);
        let args: Vec<String> = manifest
            .command
            .args
            .iter()
            .map(|a| a.replace("${SERVER_DIR}", &server_dir_str))
            .collect();

        let mut cmd = Command::new(&binary);
        cmd.args(&args)
            .current_dir(project_root)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            // Cloning the parent env is fine — npm-installed shims need PATH
            // to resolve `node`, and GitHub-release binaries are self-contained
            // so extra env entries are harmless.
            .kill_on_drop(true);

        let mut child: Child = cmd
            .spawn()
            .map_err(|e| LspError::InstallCommand(binary.clone(), e.to_string()))?;

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| LspError::InstallCommand(binary.clone(), "no stdin".into()))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| LspError::InstallCommand(binary.clone(), "no stdout".into()))?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| LspError::InstallCommand(binary.clone(), "no stderr".into()))?;

        // ── Writer ────────────────────────────────────────────────────
        let (write_tx, mut write_rx) = mpsc::channel::<Vec<u8>>(64);
        let server_id_for_writer = manifest.id.clone();
        tokio::spawn(async move {
            let mut stdin = stdin;
            while let Some(body) = write_rx.recv().await {
                if let Err(e) = write_message(&mut stdin, &body).await {
                    warn!(server_id = %server_id_for_writer, error = %e, "lsp write failed");
                    break;
                }
            }
            debug!(server_id = %server_id_for_writer, "lsp writer task ended");
        });

        let pending: Arc<RwLock<HashMap<RequestId, oneshot::Sender<Result<Value, ResponseError>>>>> =
            Arc::new(RwLock::new(HashMap::new()));

        // ── Reader ────────────────────────────────────────────────────
        let server_id_for_reader = manifest.id.clone();
        let pending_for_reader = pending.clone();
        let sink_for_reader = sink.clone();
        tokio::spawn(async move {
            let mut reader = BufReader::new(stdout);
            loop {
                match read_message(&mut reader).await {
                    Ok(Some(body)) => {
                        if let Err(e) = handle_incoming(
                            &body,
                            &pending_for_reader,
                            &sink_for_reader,
                            &server_id_for_reader,
                        )
                        .await
                        {
                            warn!(
                                server_id = %server_id_for_reader,
                                error = %e,
                                "lsp message handling failed"
                            );
                        }
                    }
                    Ok(None) => {
                        info!(server_id = %server_id_for_reader, "lsp stdout EOF");
                        break;
                    }
                    Err(e) => {
                        warn!(server_id = %server_id_for_reader, error = %e, "lsp read error");
                        break;
                    }
                }
            }
            // Drain any still-pending requests with an error so callers
            // don't hang on an exited server.
            let mut map = pending_for_reader.write().await;
            for (_, tx) in map.drain() {
                let _ = tx.send(Err(ResponseError {
                    code: -32099,
                    message: "lsp server exited".into(),
                    data: None,
                }));
            }
        });

        // ── stderr drain ──────────────────────────────────────────────
        let server_id_for_err = manifest.id.clone();
        tokio::spawn(async move {
            use tokio::io::AsyncBufReadExt;
            let mut reader = BufReader::new(stderr);
            let mut line = String::new();
            loop {
                line.clear();
                match reader.read_line(&mut line).await {
                    Ok(0) => break,
                    Ok(_) => debug!(
                        server_id = %server_id_for_err,
                        "[lsp stderr] {}",
                        line.trim_end()
                    ),
                    Err(_) => break,
                }
            }
        });

        // ── Reap child ────────────────────────────────────────────────
        // Without this `Child` would never be `.wait()`ed and the OS would
        // leave a zombie until process exit.
        let server_id_for_waiter = manifest.id.clone();
        tokio::spawn(async move {
            match child.wait().await {
                Ok(status) => info!(
                    server_id = %server_id_for_waiter,
                    code = ?status.code(),
                    "lsp process exited"
                ),
                Err(e) => warn!(
                    server_id = %server_id_for_waiter,
                    error = %e,
                    "lsp wait failed"
                ),
            }
        });

        let root_uri = path_to_file_uri(project_root);
        let session = Arc::new(Self {
            server_id: manifest.id.clone(),
            project_id,
            root_uri: root_uri.clone(),
            write_tx,
            pending,
            next_id: AtomicI64::new(1),
        });

        // initialize handshake — block here so the caller knows the server
        // is ready to receive textDocument/* by the time `spawn` returns.
        session.initialize(project_root).await?;
        Ok(session)
    }

    async fn initialize(&self, project_root: &Path) -> Result<(), LspError> {
        let params = json!({
            "processId": std::process::id(),
            "rootUri": self.root_uri,
            "workspaceFolders": [{
                "uri": self.root_uri,
                "name": project_root.file_name()
                    .and_then(|s| s.to_str())
                    .unwrap_or("workspace"),
            }],
            "capabilities": {
                "textDocument": {
                    "synchronization": {
                        "dynamicRegistration": false,
                        "didSave": false,
                    },
                    "definition": { "linkSupport": true },
                    "semanticTokens": {
                        "requests": { "full": true },
                        "tokenTypes": TOKEN_TYPES,
                        "tokenModifiers": [],
                        "formats": ["relative"],
                        "overlappingTokenSupport": false,
                        "multilineTokenSupport": false,
                    },
                    "publishDiagnostics": {
                        "relatedInformation": false,
                    },
                },
                "workspace": { "workspaceFolders": true },
            },
            "clientInfo": { "name": "ycode", "version": env!("CARGO_PKG_VERSION") },
            "initializationOptions": serde_json::Value::Null,
        });
        let _ = self.request("initialize", params).await?;
        self.notify("initialized", json!({})).await?;
        Ok(())
    }

    /// Send a request and await the matching response. Blocks the caller
    /// until either a response or the server exits.
    pub async fn request(&self, method: &str, params: Value) -> Result<Value, LspError> {
        let id = RequestId::Number(self.next_id.fetch_add(1, Ordering::SeqCst));
        let (tx, rx) = oneshot::channel();
        self.pending.write().await.insert(id.clone(), tx);

        let msg = json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        });
        let body = serde_json::to_vec(&msg)?;
        self.write_tx
            .send(body)
            .await
            .map_err(|_| LspError::InstallCommand(self.server_id.clone(), "writer gone".into()))?;

        match rx.await {
            Ok(Ok(v)) => Ok(v),
            Ok(Err(e)) => Err(LspError::InstallCommand(
                format!("lsp {}", method),
                e.message,
            )),
            Err(_) => Err(LspError::InstallCommand(
                format!("lsp {}", method),
                "no response (server gone)".into(),
            )),
        }
    }

    pub async fn notify(&self, method: &str, params: Value) -> Result<(), LspError> {
        let msg = json!({
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        });
        let body = serde_json::to_vec(&msg)?;
        self.write_tx
            .send(body)
            .await
            .map_err(|_| LspError::InstallCommand(self.server_id.clone(), "writer gone".into()))?;
        Ok(())
    }

    pub async fn did_open(
        &self,
        uri: &str,
        language_id: &str,
        version: i64,
        text: &str,
    ) -> Result<(), LspError> {
        self.notify(
            "textDocument/didOpen",
            json!({
                "textDocument": {
                    "uri": uri,
                    "languageId": language_id,
                    "version": version,
                    "text": text,
                }
            }),
        )
        .await
    }

    pub async fn did_change_full(
        &self,
        uri: &str,
        version: i64,
        text: &str,
    ) -> Result<(), LspError> {
        self.notify(
            "textDocument/didChange",
            json!({
                "textDocument": { "uri": uri, "version": version },
                "contentChanges": [{ "text": text }],
            }),
        )
        .await
    }

    pub async fn did_close(&self, uri: &str) -> Result<(), LspError> {
        self.notify(
            "textDocument/didClose",
            json!({ "textDocument": { "uri": uri } }),
        )
        .await
    }

    pub async fn definition(
        &self,
        uri: &str,
        line: u32,
        character: u32,
    ) -> Result<Value, LspError> {
        self.request(
            "textDocument/definition",
            json!({
                "textDocument": { "uri": uri },
                "position": { "line": line, "character": character },
            }),
        )
        .await
    }

    pub async fn semantic_tokens_full(&self, uri: &str) -> Result<Value, LspError> {
        self.request(
            "textDocument/semanticTokens/full",
            json!({ "textDocument": { "uri": uri } }),
        )
        .await
    }

    /// Best-effort graceful shutdown. Servers that don't ack within a tick
    /// just get their `kill_on_drop` clean-up — we don't block.
    pub async fn shutdown(&self) {
        let _ = self.request("shutdown", Value::Null).await;
        let _ = self.notify("exit", Value::Null).await;
    }
}

async fn handle_incoming(
    body: &[u8],
    pending: &Arc<RwLock<HashMap<RequestId, oneshot::Sender<Result<Value, ResponseError>>>>>,
    sink: &NotificationSink,
    server_id: &str,
) -> Result<(), LspError> {
    let msg: IncomingMessage = serde_json::from_slice(body)?;
    match (msg.id, msg.method) {
        // Response — has id, may have result XOR error.
        (Some(id), None) => {
            let mut map = pending.write().await;
            if let Some(tx) = map.remove(&id) {
                let outcome = if let Some(err) = msg.error {
                    Err(err)
                } else {
                    Ok(msg.result.unwrap_or(Value::Null))
                };
                let _ = tx.send(outcome);
            } else {
                debug!(server_id = %server_id, "response for unknown id");
            }
        }
        // Notification — method without id.
        (None, Some(method)) => {
            on_notification(server_id, &method, msg.params.unwrap_or(Value::Null), sink);
        }
        // Server-initiated request — log and drop. Returning a "method not
        // found" reply would be more correct but requires writing back from
        // here; nothing we drive cares.
        (Some(_), Some(method)) => {
            debug!(server_id = %server_id, method = %method, "ignoring server request");
        }
        _ => {
            debug!(server_id = %server_id, "ignoring unclassifiable lsp message");
        }
    }
    Ok(())
}

fn on_notification(server_id: &str, method: &str, params: Value, sink: &NotificationSink) {
    match method {
        "textDocument/publishDiagnostics" => {
            let uri = params
                .get("uri")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string();
            sink(
                server_id,
                ServerNotification::PublishDiagnostics { uri, params },
            );
        }
        // Log noise: window/logMessage, $/progress, etc. Drop them silently
        // — the user can crank tracing if they want to see what the server
        // is up to.
        _ => {
            debug!(server_id = %server_id, method = %method, "lsp notification (ignored)");
        }
    }
}

/// Render an OS path as a `file://` URI. URL-encodes the *path* (preserving
/// `/`) so that paths with spaces or non-ASCII characters survive round-trip
/// through the editor and back. Per RFC 8089.
pub fn path_to_file_uri(path: &Path) -> String {
    let s = path.to_string_lossy();
    let mut out = String::from("file://");
    for ch in s.chars() {
        match ch {
            // Reserved unreserved: A-Za-z0-9 - . _ ~ and path delim '/'
            'A'..='Z' | 'a'..='z' | '0'..='9' | '-' | '.' | '_' | '~' | '/' => out.push(ch),
            // Windows drive separators stay literal; the parser on the other
            // side joins `file:///C:/foo` back to a normal path.
            ':' => out.push(ch),
            _ => {
                let mut buf = [0u8; 4];
                for byte in ch.encode_utf8(&mut buf).bytes() {
                    out.push_str(&format!("%{byte:02X}"));
                }
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_uri_encodes_spaces_and_unicode() {
        let uri = path_to_file_uri(Path::new("/tmp/hello world/файл.rs"));
        assert!(uri.starts_with("file:///tmp/hello%20world/"));
        assert!(uri.ends_with(".rs"));
        assert!(uri.contains("%"));
    }

    #[test]
    fn file_uri_keeps_ascii_path_intact() {
        assert_eq!(
            path_to_file_uri(Path::new("/repo/src/main.rs")),
            "file:///repo/src/main.rs"
        );
    }
}
