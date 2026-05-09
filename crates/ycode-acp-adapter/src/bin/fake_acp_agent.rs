//! Minimal in-process ACP server. Used by `tests/loopback.rs` to exercise
//! the adapter's wire layer end-to-end without a real LLM.
//!
//! Behaviour:
//! - Responds to `initialize` and `session/new`.
//! - On `session/prompt`, streams an `agent_message_chunk`, optionally runs
//!   a permission round-trip (if the prompt contains `permission`), then
//!   resolves with `stop_reason: end_turn`.
//! - On `session/cancel`, terminates the in-flight prompt with
//!   `stop_reason: cancelled`.
//!
//! Wire format: NDJSON JSON-RPC 2.0, per the ACP spec.

use std::io::{BufRead, BufReader, Read, Stdin, Write};

use serde_json::{json, Value};

fn main() {
    let stdin_handle = std::io::stdin();
    let mut reader = BufReader::new(stdin_handle);
    let mut session_id: Option<String> = None;
    let mut next_outbound_id: i64 = 1000;

    while let Some(msg) = read_message(&mut reader) {
        let method = msg.get("method").and_then(|m| m.as_str());
        let id = msg.get("id").cloned();

        match method {
            Some("initialize") => {
                send(json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": {
                        "protocolVersion": 1,
                        "agentInfo": {"name": "fake-acp-agent", "version": "0.0.1"},
                        "agentCapabilities": {}
                    }
                }));
            }
            Some("session/new") => {
                session_id = Some("fake-session-1".to_string());
                send(json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": {"sessionId": "fake-session-1"}
                }));
            }
            Some("session/prompt") => {
                handle_prompt(&mut reader, &session_id, id, &msg, &mut next_outbound_id);
            }
            Some("session/cancel") => {
                // No in-flight prompt at this point (handled inline within
                // handle_prompt). Ignore.
            }
            _ => {
                if let Some(id) = id {
                    send(json!({
                        "jsonrpc": "2.0",
                        "id": id,
                        "error": {"code": -32601, "message": "method not implemented"}
                    }));
                }
            }
        }
    }
}

fn handle_prompt<R: Read>(
    reader: &mut BufReader<R>,
    session_id: &Option<String>,
    request_id: Option<Value>,
    msg: &Value,
    next_outbound_id: &mut i64,
) {
    let sid = session_id.clone().unwrap_or_default();
    let prompt_text = extract_prompt_text(msg);
    let needs_permission = prompt_text.contains("permission");

    send(update(
        &sid,
        json!({
            "sessionUpdate": "agent_message_chunk",
            "content": {"type": "text", "text": format!("ack: {prompt_text}")}
        }),
    ));
    send(update(
        &sid,
        json!({
            "sessionUpdate": "tool_call",
            "toolCallId": "tc-1",
            "title": "fake_tool",
            "kind": "fake_tool",
            "status": "in_progress"
        }),
    ));

    let stop_reason = if needs_permission {
        let outbound_id = *next_outbound_id;
        *next_outbound_id += 1;
        send(json!({
            "jsonrpc": "2.0",
            "id": outbound_id,
            "method": "session/request_permission",
            "params": {
                "sessionId": sid,
                "toolCall": {
                    "toolCallId": "tc-1",
                    "title": "fake permission summary",
                    "kind": "fake_tool"
                },
                "options": [
                    {"optionId": "allow_once", "name": "Allow", "kind": "allow_once"},
                    {"optionId": "reject_once", "name": "Reject", "kind": "reject_once"}
                ]
            }
        }));

        // Drain stdin until we see either the matching response or a cancel.
        let mut outcome: Option<String> = None;
        let mut got_cancel = false;
        while outcome.is_none() && !got_cancel {
            let Some(in_msg) = read_message(reader) else {
                return;
            };
            if in_msg.get("method").and_then(|m| m.as_str()) == Some("session/cancel") {
                got_cancel = true;
                break;
            }
            if let Some(resp_id) = in_msg.get("id").and_then(|i| i.as_i64()) {
                if resp_id == outbound_id {
                    let inner = in_msg.get("result").and_then(|r| r.get("outcome"));
                    outcome = inner
                        .and_then(|o| {
                            if let Some(opt) = o.get("optionId").and_then(|v| v.as_str()) {
                                Some(opt.to_string())
                            } else if o.get("outcome").and_then(|v| v.as_str()) == Some("cancelled")
                            {
                                Some("__cancelled__".to_string())
                            } else {
                                None
                            }
                        })
                        .or_else(|| Some("reject_once".to_string()));
                }
            }
        }

        let allowed = matches!(
            outcome.as_deref(),
            Some("allow_once") | Some("allow_always")
        );
        let final_status = if got_cancel || outcome.as_deref() == Some("__cancelled__") {
            "cancelled"
        } else if allowed {
            "completed"
        } else {
            "failed"
        };
        send(update(
            &sid,
            json!({
                "sessionUpdate": "tool_call_update",
                "toolCallId": "tc-1",
                "status": final_status
            }),
        ));

        if got_cancel || outcome.as_deref() == Some("__cancelled__") {
            "cancelled"
        } else if allowed {
            "end_turn"
        } else {
            "refusal"
        }
    } else {
        send(update(
            &sid,
            json!({
                "sessionUpdate": "tool_call_update",
                "toolCallId": "tc-1",
                "status": "completed"
            }),
        ));
        "end_turn"
    };

    send(json!({
        "jsonrpc": "2.0",
        "id": request_id,
        "result": {"stopReason": stop_reason}
    }));
}

fn read_message<R: Read>(reader: &mut BufReader<R>) -> Option<Value> {
    let mut buf = String::new();
    loop {
        buf.clear();
        let n = reader.read_line(&mut buf).ok()?;
        if n == 0 {
            return None;
        }
        let trimmed = buf.trim();
        if trimmed.is_empty() {
            continue;
        }
        match serde_json::from_str(trimmed) {
            Ok(v) => return Some(v),
            Err(_) => continue, // skip malformed lines
        }
    }
}

fn extract_prompt_text(msg: &Value) -> String {
    msg.get("params")
        .and_then(|p| p.get("prompt"))
        .and_then(|p| p.as_array())
        .and_then(|arr| arr.iter().find_map(|b| b.get("text").and_then(|t| t.as_str())))
        .unwrap_or("")
        .to_string()
}

fn update(session_id: &str, update_body: Value) -> Value {
    json!({
        "jsonrpc": "2.0",
        "method": "session/update",
        "params": {
            "sessionId": session_id,
            "update": update_body,
        }
    })
}

fn send(msg: Value) {
    let line = serde_json::to_string(&msg).expect("encode JSON");
    let stdout = std::io::stdout();
    let mut g = stdout.lock();
    let _ = writeln!(g, "{line}");
    let _ = g.flush();
}

// Pull `Stdin` into scope so it doesn't generate "unused import" if
// architecture changes later.
#[allow(dead_code)]
fn _force_stdin_in_scope(_: Stdin) {}
