//! `ycode-mcp` — a thin stdio MCP server that exposes the active project's
//! todo list to AI CLIs (Claude Code, Codex).
//!
//! It holds no state of its own. Every tool call connects to ycode's MCP
//! control socket (`YCODE_MCP_SOCK`, falling back to a stable default path),
//! sends one newline-terminated JSON request, and reads one JSON response.
//! ycode does the project resolution + SQLite work and broadcasts a UI event
//! so the right-pane Todo tab refreshes live.
//!
//! Project context flows implicitly: the agent CLI is spawned by ycode with
//! `YCODE_TERMINAL_ID` in its environment, which is inherited by this child.
//! We forward it (plus our cwd as a fallback) on every request so the model
//! never has to pass a project id.

use std::path::PathBuf;

use rmcp::{
    handler::server::router::tool::ToolRouter, handler::server::wrapper::Parameters,
    model::*, tool, tool_handler, tool_router, transport::stdio, ErrorData as McpError,
    ServerHandler, ServiceExt,
};
use schemars::JsonSchema;
use serde::Deserialize;

#[derive(Debug, Deserialize, JsonSchema)]
struct AddTodoArgs {
    /// The todo text.
    title: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
struct UpdateTodoArgs {
    /// Id of the todo to update (from `list_todos`).
    id: String,
    /// New title. Omit to leave unchanged.
    #[serde(default)]
    title: Option<String>,
    /// New status: one of `todo`, `doing`, `done`. Omit to leave unchanged.
    #[serde(default)]
    status: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
struct DeleteTodoArgs {
    /// Id of the todo to delete (from `list_todos`).
    id: String,
}

#[derive(Clone)]
struct TodoServer {
    // Used by the `#[tool_handler]` macro; dead-code analysis can't see that.
    #[allow(dead_code)]
    tool_router: ToolRouter<TodoServer>,
    // Only read by the Unix `call` impl; unused on non-Unix targets.
    #[cfg_attr(not(unix), allow(dead_code))]
    sock_path: PathBuf,
    #[cfg_attr(not(unix), allow(dead_code))]
    terminal_id: Option<String>,
    #[cfg_attr(not(unix), allow(dead_code))]
    cwd: Option<String>,
}

/// Stable default socket path, mirroring `mcp_listener::default_socket_path`
/// on the ycode side. Only consulted when `YCODE_MCP_SOCK` is unset.
fn default_socket_path() -> PathBuf {
    let tmp = std::env::var_os("TMPDIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    tmp.join("ycode-mcp.sock")
}

#[tool_router]
impl TodoServer {
    fn new() -> Self {
        let sock_path = std::env::var_os("YCODE_MCP_SOCK")
            .map(PathBuf::from)
            .unwrap_or_else(default_socket_path);
        let terminal_id = std::env::var("YCODE_TERMINAL_ID").ok().filter(|s| !s.is_empty());
        let cwd = std::env::current_dir()
            .ok()
            .map(|p| p.to_string_lossy().into_owned());
        Self {
            tool_router: Self::tool_router(),
            sock_path,
            terminal_id,
            cwd,
        }
    }

    /// Round-trip one request through the ycode control socket.
    ///
    /// Unix-only: the control socket is a Unix domain socket. On Windows this
    /// sidecar still builds and serves MCP (so the bundle resource exists), but
    /// every tool call reports it's unsupported — matching the main app, which
    /// doesn't even bind the socket or inject `YCODE_MCP_SOCK` on non-Unix.
    #[cfg(unix)]
    async fn call(
        &self,
        action: &str,
        payload: serde_json::Value,
    ) -> Result<serde_json::Value, String> {
        use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
        use tokio::net::UnixStream;

        let req = serde_json::json!({
            "terminal_id": self.terminal_id,
            "cwd": self.cwd,
            "action": action,
            "payload": payload,
        });

        let stream = UnixStream::connect(&self.sock_path)
            .await
            .map_err(|e| format!("cannot reach ycode at {}: {e}", self.sock_path.display()))?;
        let (read_half, mut write_half) = stream.into_split();

        let mut line = serde_json::to_string(&req).map_err(|e| e.to_string())?;
        line.push('\n');
        write_half
            .write_all(line.as_bytes())
            .await
            .map_err(|e| e.to_string())?;
        write_half.flush().await.map_err(|e| e.to_string())?;

        let mut reader = BufReader::new(read_half);
        let mut resp = String::new();
        reader
            .read_line(&mut resp)
            .await
            .map_err(|e| e.to_string())?;

        let value: serde_json::Value =
            serde_json::from_str(resp.trim()).map_err(|e| format!("bad response: {e}"))?;
        if value.get("ok").and_then(|v| v.as_bool()).unwrap_or(false) {
            Ok(value.get("data").cloned().unwrap_or(serde_json::Value::Null))
        } else {
            Err(value
                .get("error")
                .and_then(|v| v.as_str())
                .unwrap_or("unknown error")
                .to_string())
        }
    }

    #[cfg(not(unix))]
    async fn call(
        &self,
        _action: &str,
        _payload: serde_json::Value,
    ) -> Result<serde_json::Value, String> {
        Err("ycode todo tools require a Unix domain socket; not supported on this platform".into())
    }

    /// Turn a `call` outcome into an MCP tool result, JSON-stringifying the
    /// payload so the model can read structured data back.
    fn into_result(outcome: Result<serde_json::Value, String>) -> Result<CallToolResult, McpError> {
        match outcome {
            Ok(data) => {
                let text = serde_json::to_string_pretty(&data)
                    .unwrap_or_else(|_| data.to_string());
                Ok(CallToolResult::success(vec![Content::text(text)]))
            }
            Err(e) => Err(McpError::internal_error(e, None)),
        }
    }

    #[tool(description = "List all todo items for the current project. Returns id, title, status \
        (todo/doing/done) and ordering for each item.")]
    async fn list_todos(&self) -> Result<CallToolResult, McpError> {
        Self::into_result(self.call("list", serde_json::Value::Null).await)
    }

    #[tool(description = "Add a new todo item to the current project. It starts in the `todo` \
        status and is appended to the end of the list.")]
    async fn add_todo(
        &self,
        Parameters(args): Parameters<AddTodoArgs>,
    ) -> Result<CallToolResult, McpError> {
        Self::into_result(self.call("add", serde_json::json!({ "title": args.title })).await)
    }

    #[tool(description = "Update a todo's title and/or status. Status must be one of \
        `todo`, `doing`, `done`. Provide at least one of title or status.")]
    async fn update_todo(
        &self,
        Parameters(args): Parameters<UpdateTodoArgs>,
    ) -> Result<CallToolResult, McpError> {
        Self::into_result(
            self.call(
                "update",
                serde_json::json!({ "id": args.id, "title": args.title, "status": args.status }),
            )
            .await,
        )
    }

    #[tool(description = "Delete a todo item from the current project by id.")]
    async fn delete_todo(
        &self,
        Parameters(args): Parameters<DeleteTodoArgs>,
    ) -> Result<CallToolResult, McpError> {
        Self::into_result(self.call("delete", serde_json::json!({ "id": args.id })).await)
    }
}

#[tool_handler]
impl ServerHandler for TodoServer {
    fn get_info(&self) -> ServerInfo {
        // `ServerInfo` is `#[non_exhaustive]` — build from default + assign.
        let mut info = ServerInfo::default();
        info.capabilities = ServerCapabilities::builder().enable_tools().build();
        info.instructions = Some(
            "Manage the current ycode project's todo list. The project is inferred from \
             the terminal you are running in — never ask the user for a project id. Use \
             list_todos to read, add_todo to create, update_todo to change title/status \
             (todo/doing/done), and delete_todo to remove."
                .into(),
        );
        info
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Logs MUST go to stderr — stdout is the MCP JSON-RPC channel.
    let _ = tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_max_level(tracing::Level::WARN)
        .try_init();

    let service = TodoServer::new().serve(stdio()).await?;
    service.waiting().await?;
    Ok(())
}
