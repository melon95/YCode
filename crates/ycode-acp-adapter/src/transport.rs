//! Process spawn + NDJSON-framed JSON-RPC over stdio.
//!
//! ## Threading model
//!
//! - `writer_task` drains an `mpsc::Receiver<String>` to the child's stdin.
//!   Owning a single writer lets us serialize concurrent outbound messages
//!   without locking.
//! - `reader_task` reads NDJSON lines from stdout, parses each into
//!   [`RpcMessage`], and dispatches via the handler interface.
//! - Outgoing requests register a `oneshot::Sender` keyed by request id; the
//!   reader task fulfills the oneshot when a matching response arrives.
//!
//! ## Day-3 risk note (per the plan)
//!
//! Inbound `session/request_permission` MUST be handled without blocking the
//! reader task. The handler returns a `BoxFuture` that we `tokio::spawn`; the
//! reader continues immediately. When the spawned task completes, it pushes
//! the response back through the writer.

use std::collections::HashMap;
use std::process::Stdio;
use std::sync::Arc;

use serde::Serialize;
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::{mpsc, oneshot, Mutex};
use tokio::task::JoinHandle;
use tracing::{debug, error, trace, warn};

use crate::protocol::{
    RpcError, RpcId, RpcMessage, RpcNotification, RpcRequest, RpcResponse,
};

/// Capacity of the outbound message queue. Bursty `session/update` round-trips
/// can produce a few dozen messages in flight; 256 leaves comfortable headroom.
const OUTBOUND_CAPACITY: usize = 256;

pub struct Transport {
    /// Sender for outbound serialized JSON-RPC frames. Cloneable; the writer
    /// task drains the receiver.
    out_tx: mpsc::Sender<String>,
    /// Pending outgoing requests keyed by id. The reader task removes entries
    /// when responses arrive.
    pending: Arc<Mutex<HashMap<String, oneshot::Sender<RpcResponse>>>>,
    /// Monotonically increasing request id counter.
    next_id: Mutex<i64>,
    /// Background tasks. Aborted on shutdown.
    tasks: Mutex<Vec<JoinHandle<()>>>,
    /// Spawned child. Killed on shutdown.
    child: Mutex<Option<Child>>,
}

/// Server-method handler. Implementations decide what to do with each
/// incoming request or notification. The transport calls these and forwards
/// the result (or error) back over the wire.
#[async_trait::async_trait]
pub trait MessageHandler: Send + Sync + 'static {
    /// Handle an incoming JSON-RPC request. Return JSON to send back as
    /// `result`, or an `RpcError` for the `error` field. Implementations
    /// SHOULD return quickly or `tokio::spawn` for long-running work — the
    /// handler is awaited from the reader task.
    async fn handle_request(&self, method: &str, params: Option<Value>) -> Result<Value, RpcError>;

    /// Handle an incoming notification. No response is sent. Errors are
    /// logged but otherwise dropped.
    async fn handle_notification(&self, method: &str, params: Option<Value>);
}

impl Transport {
    /// Spawn `command` with `args` and `env`, frame JSON-RPC over its stdio.
    /// `handler` is invoked for every incoming request/notification.
    pub async fn spawn(
        command: &str,
        args: &[String],
        env: &[(String, String)],
        cwd: Option<&str>,
        handler: Arc<dyn MessageHandler>,
    ) -> Result<Arc<Self>, std::io::Error> {
        let mut cmd = Command::new(command);
        cmd.args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            // Inherit env by default; explicit overrides on top.
            .env_clear()
            .envs(std::env::vars())
            // claude-code-acp refuses to spawn inside an existing Claude
            // Code session (it errors `session/new` with -32603). Strip
            // the marker from the child's env so ycode itself can be
            // launched from a Claude Code terminal without breaking. No
            // other ACP agent uses this var, so the strip is safe.
            .env_remove("CLAUDECODE");
        for (k, v) in env {
            cmd.env(k, v);
        }
        if let Some(cwd) = cwd {
            cmd.current_dir(cwd);
        }
        let mut child = cmd.spawn()?;

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::Other, "no stdin on child"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::Other, "no stdout on child"))?;
        let stderr = child.stderr.take();

        let (out_tx, out_rx) = mpsc::channel::<String>(OUTBOUND_CAPACITY);
        let pending: Arc<Mutex<HashMap<String, oneshot::Sender<RpcResponse>>>> =
            Arc::new(Mutex::new(HashMap::new()));

        let transport = Arc::new(Self {
            out_tx: out_tx.clone(),
            pending: pending.clone(),
            next_id: Mutex::new(1),
            tasks: Mutex::new(Vec::new()),
            child: Mutex::new(Some(child)),
        });

        let writer = tokio::spawn(writer_task(stdin, out_rx));
        let reader = tokio::spawn(reader_task(
            stdout,
            pending,
            handler,
            out_tx.clone(),
        ));
        let stderr_task = if let Some(stderr) = stderr {
            Some(tokio::spawn(stderr_task(stderr)))
        } else {
            None
        };
        {
            let mut tasks = transport.tasks.lock().await;
            tasks.push(writer);
            tasks.push(reader);
            if let Some(t) = stderr_task {
                tasks.push(t);
            }
        }

        Ok(transport)
    }

    /// Send an outgoing request and await the matching response.
    pub async fn request<P: Serialize>(
        &self,
        method: &str,
        params: P,
    ) -> Result<RpcResponse, TransportError> {
        let id_num = {
            let mut next = self.next_id.lock().await;
            let id = *next;
            *next += 1;
            id
        };
        let id_str = id_num.to_string();
        let (tx, rx) = oneshot::channel::<RpcResponse>();
        self.pending.lock().await.insert(id_str.clone(), tx);

        let req = RpcRequest {
            jsonrpc: "2.0".into(),
            id: RpcId::Number(id_num),
            method: method.to_string(),
            params: Some(serde_json::to_value(params)?),
        };
        let line = serde_json::to_string(&req)?;
        self.out_tx
            .send(line)
            .await
            .map_err(|_| TransportError::Closed)?;

        let resp = rx.await.map_err(|_| TransportError::Closed)?;
        Ok(resp)
    }

    /// Send an outgoing notification (fire-and-forget).
    pub async fn notify<P: Serialize>(
        &self,
        method: &str,
        params: P,
    ) -> Result<(), TransportError> {
        let n = RpcNotification {
            jsonrpc: "2.0".into(),
            method: method.to_string(),
            params: Some(serde_json::to_value(params)?),
        };
        let line = serde_json::to_string(&n)?;
        self.out_tx
            .send(line)
            .await
            .map_err(|_| TransportError::Closed)?;
        Ok(())
    }

    /// Cancel background tasks and kill the child. Idempotent.
    pub async fn shutdown(&self) {
        for t in self.tasks.lock().await.drain(..) {
            t.abort();
        }
        if let Some(mut child) = self.child.lock().await.take() {
            let _ = child.start_kill();
            let _ = child.wait().await;
        }
    }
}

async fn writer_task(mut stdin: ChildStdin, mut rx: mpsc::Receiver<String>) {
    while let Some(line) = rx.recv().await {
        trace!(message = %line, "→ agent");
        if stdin.write_all(line.as_bytes()).await.is_err()
            || stdin.write_all(b"\n").await.is_err()
        {
            warn!("agent stdin closed");
            return;
        }
        if stdin.flush().await.is_err() {
            warn!("agent stdin flush failed");
            return;
        }
    }
}

async fn reader_task(
    stdout: ChildStdout,
    pending: Arc<Mutex<HashMap<String, oneshot::Sender<RpcResponse>>>>,
    handler: Arc<dyn MessageHandler>,
    out_tx: mpsc::Sender<String>,
) {
    let mut lines = BufReader::new(stdout).lines();
    loop {
        match lines.next_line().await {
            Ok(Some(line)) => {
                trace!(message = %line, "← agent");
                if line.trim().is_empty() {
                    continue;
                }
                let parsed: Result<RpcMessage, _> = serde_json::from_str(&line);
                match parsed {
                    Ok(msg) => dispatch(msg, &pending, &handler, &out_tx).await,
                    Err(e) => warn!(error = %e, line = %line, "malformed JSON-RPC frame"),
                }
            }
            Ok(None) => {
                debug!("agent stdout closed");
                return;
            }
            Err(e) => {
                error!(error = %e, "reader IO error");
                return;
            }
        }
    }
}

async fn stderr_task(stderr: tokio::process::ChildStderr) {
    let mut lines = BufReader::new(stderr).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        // Agents often log diagnostics here. Surface at debug; users can
        // crank up the filter when troubleshooting.
        debug!(target: "acp.agent.stderr", "{line}");
    }
}

async fn dispatch(
    msg: RpcMessage,
    pending: &Arc<Mutex<HashMap<String, oneshot::Sender<RpcResponse>>>>,
    handler: &Arc<dyn MessageHandler>,
    out_tx: &mpsc::Sender<String>,
) {
    match msg {
        RpcMessage::Response(resp) => {
            let key = id_key(&resp.id);
            if let Some(slot) = pending.lock().await.remove(&key) {
                let _ = slot.send(resp);
            } else {
                warn!(id = %key, "stray response with no matching request");
            }
        }
        RpcMessage::Request(req) => {
            // Day-3 risk mitigation: spawn so the reader keeps draining.
            let handler = handler.clone();
            let out_tx = out_tx.clone();
            let id = req.id.clone();
            tokio::spawn(async move {
                let result = handler.handle_request(&req.method, req.params).await;
                let response = match result {
                    Ok(value) => RpcResponse {
                        jsonrpc: "2.0".into(),
                        id,
                        result: Some(value),
                        error: None,
                    },
                    Err(err) => RpcResponse {
                        jsonrpc: "2.0".into(),
                        id,
                        result: None,
                        error: Some(err),
                    },
                };
                if let Ok(line) = serde_json::to_string(&response) {
                    let _ = out_tx.send(line).await;
                }
            });
        }
        RpcMessage::Notification(n) => {
            let handler = handler.clone();
            tokio::spawn(async move {
                handler.handle_notification(&n.method, n.params).await;
            });
        }
    }
}

fn id_key(id: &RpcId) -> String {
    match id {
        RpcId::Number(n) => n.to_string(),
        RpcId::String(s) => s.clone(),
    }
}

#[derive(Debug, thiserror::Error)]
pub enum TransportError {
    #[error("transport closed")]
    Closed,
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
}
