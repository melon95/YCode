//! Codex CLI session discovery + jsonl parsing.
//!
//! Layout: `~/.codex/sessions/YYYY/MM/DD/rollout-<uuid>.jsonl`. The first
//! line is always a `session_meta` record holding the workspace cwd, the
//! session UUID, and the originator (`Codex CLI` vs `Codex Desktop`).

use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::unified::{ToolStatus, UnifiedEvent, UnifiedEventKind, UnifiedRole};
use crate::{AgentBackend, DiscoveredSession, IntrospectError};

pub struct CodexBackend;

impl AgentBackend for CodexBackend {
    fn name(&self) -> &'static str {
        "codex"
    }

    fn sessions_root(&self, home: &Path) -> Option<PathBuf> {
        Some(home.join(".codex").join("sessions"))
    }
}

/// Walk `<root>/YYYY/MM/DD/*.jsonl`, read each first line, keep the ones
/// whose `payload.cwd` matches `cwd`. Per plan §8.12 / §12.5.2.
pub fn scan_workspace(home: &Path, cwd: &Path) -> Result<Vec<DiscoveredSession>, IntrospectError> {
    let root = CodexBackend
        .sessions_root(home)
        .ok_or_else(|| IntrospectError::Io("no home dir".into()))?;
    if !root.is_dir() {
        return Ok(vec![]);
    }
    let mut files = Vec::new();
    collect_jsonl(&root, &mut files);

    let cwd_str = cwd.to_string_lossy().into_owned();
    let mut out = Vec::new();
    for path in files {
        let first = match read_first_line(&path) {
            Ok(s) => s,
            Err(_) => continue,
        };
        let Ok(v) = serde_json::from_str::<Value>(&first) else {
            continue;
        };
        // First record is always `type=session_meta`. Drop Codex Desktop —
        // its `cwd` is the user's home and would pollute every workspace.
        if v.get("type").and_then(|t| t.as_str()) != Some("session_meta") {
            continue;
        }
        let originator = v
            .pointer("/payload/originator")
            .and_then(|s| s.as_str())
            .unwrap_or("");
        if originator.eq_ignore_ascii_case("Codex Desktop") {
            continue;
        }
        let payload_cwd = v
            .pointer("/payload/cwd")
            .and_then(|s| s.as_str())
            .unwrap_or("");
        if payload_cwd != cwd_str {
            continue;
        }
        let session_id = v
            .pointer("/payload/id")
            .and_then(|s| s.as_str())
            .map(|s| s.to_string());
        let title = extract_title(&path);
        out.push(DiscoveredSession {
            agent: "codex",
            jsonl_path: path,
            session_id,
            cwd: Some(cwd.to_path_buf()),
            title,
        });
    }
    Ok(out)
}

/// Read the first ~60 lines of `path` looking for the first real user
/// prompt. Codex rollouts encode user input as
/// `response_item.message.role="user"` with `input_text` content blocks.
/// The CLI auto-prepends synthetic wrappers like `<environment_context>` and
/// `<turn_aborted>` under the same role — we skip those by ignoring any
/// content whose first non-whitespace char is `<` (XML-ish tag).
fn extract_title(path: &Path) -> Option<String> {
    use std::io::{BufRead, BufReader};
    let f = std::fs::File::open(path).ok()?;
    let mut reader = BufReader::new(f);
    let mut buf = String::new();
    for _ in 0..60 {
        buf.clear();
        let read = reader.read_line(&mut buf).ok()?;
        if read == 0 {
            break;
        }
        let trimmed_line = buf.trim();
        if trimmed_line.is_empty() {
            continue;
        }
        let v: serde_json::Value = match serde_json::from_str(trimmed_line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if let Some(text) = first_user_input_text(&v) {
            let trimmed = text.trim();
            if !trimmed.is_empty() && !trimmed.starts_with('<') {
                return Some(truncate_title(trimmed));
            }
        }
    }
    None
}

/// Pull `text` out of `{type: response_item, payload: {type: message,
/// role: "user", content: [{type: "input_text", text: "..."}]}}` —
/// the actual codex wire shape for user prompts.
fn first_user_input_text(v: &serde_json::Value) -> Option<&str> {
    if v.get("type").and_then(|t| t.as_str()) != Some("response_item") {
        return None;
    }
    if v.pointer("/payload/type").and_then(|t| t.as_str()) != Some("message") {
        return None;
    }
    if v.pointer("/payload/role").and_then(|t| t.as_str()) != Some("user") {
        return None;
    }
    let content = v.pointer("/payload/content").and_then(|c| c.as_array())?;
    for block in content {
        if block.get("type").and_then(|t| t.as_str()) == Some("input_text") {
            if let Some(text) = block.get("text").and_then(|t| t.as_str()) {
                return Some(text);
            }
        }
    }
    None
}

fn truncate_title(s: &str) -> String {
    const MAX: usize = 80;
    let one_line: String = s.chars().map(|c| if c == '\n' { ' ' } else { c }).collect();
    if one_line.chars().count() <= MAX {
        return one_line;
    }
    let mut out: String = one_line.chars().take(MAX).collect();
    out.push('…');
    out
}

fn collect_jsonl(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let p = entry.path();
        if p.is_dir() {
            collect_jsonl(&p, out);
        } else if p.extension().and_then(|s| s.to_str()) == Some("jsonl") {
            out.push(p);
        }
    }
}

fn read_first_line(path: &Path) -> Result<String, IntrospectError> {
    use std::io::{BufRead, BufReader};
    let f = std::fs::File::open(path).map_err(|e| IntrospectError::Io(e.to_string()))?;
    let mut reader = BufReader::new(f);
    let mut line = String::new();
    reader
        .read_line(&mut line)
        .map_err(|e| IntrospectError::Io(e.to_string()))?;
    Ok(line)
}

#[derive(Clone, Debug)]
pub enum RawEvent {
    UserMessage { text: String, ts_ms: i64 },
    AssistantMessage { text: String, ts_ms: i64 },
    Reasoning { text: String, ts_ms: i64 },
    FunctionCall { name: String, args: Value, ts_ms: i64 },
    FunctionResult { name: String, output: String, ts_ms: i64 },
    SessionMeta { cwd: Option<String> },
    Unknown { type_tag: String },
}

pub fn parse_line(line: &str) -> Result<RawEvent, IntrospectError> {
    let v: Value = serde_json::from_str(line).map_err(|e| IntrospectError::Parse(e.to_string()))?;
    let ts_ms = parse_ts(&v);
    let kind = v.get("type").and_then(|t| t.as_str()).unwrap_or("");

    match kind {
        "session_meta" => Ok(RawEvent::SessionMeta {
            cwd: v
                .pointer("/payload/cwd")
                .and_then(|s| s.as_str())
                .map(|s| s.to_string()),
        }),
        "event_msg" => {
            let inner_type = v
                .pointer("/payload/type")
                .and_then(|t| t.as_str())
                .unwrap_or("");
            match inner_type {
                "user_message" => Ok(RawEvent::UserMessage {
                    text: v
                        .pointer("/payload/message")
                        .and_then(|s| s.as_str())
                        .unwrap_or("")
                        .to_string(),
                    ts_ms,
                }),
                "agent_message" | "assistant_message" => Ok(RawEvent::AssistantMessage {
                    text: v
                        .pointer("/payload/message")
                        .and_then(|s| s.as_str())
                        .unwrap_or("")
                        .to_string(),
                    ts_ms,
                }),
                "agent_reasoning" | "reasoning" => Ok(RawEvent::Reasoning {
                    text: v
                        .pointer("/payload/text")
                        .and_then(|s| s.as_str())
                        .or_else(|| v.pointer("/payload/message").and_then(|s| s.as_str()))
                        .unwrap_or("")
                        .to_string(),
                    ts_ms,
                }),
                other => Ok(RawEvent::Unknown {
                    type_tag: format!("event_msg.{other}"),
                }),
            }
        }
        "response_item" => {
            let inner_type = v
                .pointer("/payload/type")
                .and_then(|t| t.as_str())
                .unwrap_or("");
            match inner_type {
                "function_call" => Ok(RawEvent::FunctionCall {
                    name: v
                        .pointer("/payload/name")
                        .and_then(|s| s.as_str())
                        .unwrap_or("")
                        .to_string(),
                    args: v
                        .pointer("/payload/arguments")
                        .cloned()
                        .unwrap_or(Value::Null),
                    ts_ms,
                }),
                "function_call_output" => Ok(RawEvent::FunctionResult {
                    name: v
                        .pointer("/payload/name")
                        .and_then(|s| s.as_str())
                        .unwrap_or("")
                        .to_string(),
                    output: v
                        .pointer("/payload/output")
                        .and_then(|s| s.as_str())
                        .unwrap_or("")
                        .to_string(),
                    ts_ms,
                }),
                "message" => {
                    let role = v
                        .pointer("/payload/role")
                        .and_then(|s| s.as_str())
                        .unwrap_or("");
                    let text = collect_message_text(v.pointer("/payload/content"));
                    match role {
                        "user" => Ok(RawEvent::UserMessage { text, ts_ms }),
                        "assistant" => Ok(RawEvent::AssistantMessage { text, ts_ms }),
                        // `developer`, `system`, `tool` etc — surface as
                        // Unknown so the UI tags them but doesn't render in
                        // the chat stream.
                        other => Ok(RawEvent::Unknown {
                            type_tag: format!("response_item.message.{other}"),
                        }),
                    }
                }
                "reasoning" => Ok(RawEvent::Reasoning {
                    text: collect_summary_text(v.pointer("/payload/summary"))
                        .unwrap_or_default(),
                    ts_ms,
                }),
                other => Ok(RawEvent::Unknown {
                    type_tag: format!("response_item.{other}"),
                }),
            }
        }
        other => Ok(RawEvent::Unknown {
            type_tag: other.to_string(),
        }),
    }
}

/// Collect all `input_text` / `text` blocks in a `payload.content` array into
/// a single string. Codex breaks long messages into multiple blocks.
fn collect_message_text(content: Option<&Value>) -> String {
    let Some(arr) = content.and_then(|c| c.as_array()) else {
        return String::new();
    };
    let mut out = String::new();
    for block in arr {
        let text = block
            .get("text")
            .and_then(|t| t.as_str())
            .or_else(|| block.pointer("/input_text").and_then(|t| t.as_str()));
        if let Some(t) = text {
            if !out.is_empty() {
                out.push('\n');
            }
            out.push_str(t);
        }
    }
    out
}

/// Reasoning summaries are an array of `{type:"summary_text", text:"…"}`.
fn collect_summary_text(summary: Option<&Value>) -> Option<String> {
    let arr = summary?.as_array()?;
    let mut out = String::new();
    for block in arr {
        if let Some(t) = block.get("text").and_then(|t| t.as_str()) {
            if !out.is_empty() {
                out.push('\n');
            }
            out.push_str(t);
        }
    }
    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}

fn parse_ts(v: &Value) -> i64 {
    // Codex emits `timestamp` at the top level or `ts` inside payload — try both.
    let tries = [v.get("timestamp"), v.pointer("/payload/timestamp")];
    for s in tries.into_iter().flatten().filter_map(|t| t.as_str()) {
        if let Ok(t) = time::OffsetDateTime::parse(s, &time::format_description::well_known::Rfc3339)
        {
            return t.unix_timestamp() * 1000 + (t.millisecond() as i64);
        }
    }
    0
}

pub fn normalize(raw: RawEvent, seq: u64, session_id: &str) -> Option<UnifiedEvent> {
    let (ts_ms, kind) = match raw {
        RawEvent::UserMessage { text, ts_ms } => (
            ts_ms,
            UnifiedEventKind::Message {
                role: UnifiedRole::User,
                text,
            },
        ),
        RawEvent::AssistantMessage { text, ts_ms } => (
            ts_ms,
            UnifiedEventKind::Message {
                role: UnifiedRole::Assistant,
                text,
            },
        ),
        RawEvent::Reasoning { text, ts_ms } => (ts_ms, UnifiedEventKind::Thinking { text }),
        RawEvent::FunctionCall {
            name,
            args,
            ts_ms,
        } => (
            ts_ms,
            UnifiedEventKind::ToolUse {
                tool: name,
                input_json: args.to_string(),
                status: ToolStatus::Pending,
            },
        ),
        RawEvent::FunctionResult {
            name,
            output,
            ts_ms,
        } => (
            ts_ms,
            UnifiedEventKind::ToolResult {
                tool: name,
                output_excerpt: truncate(output, 4096),
                status: ToolStatus::Ok,
            },
        ),
        RawEvent::SessionMeta { .. } => return None,
        RawEvent::Unknown { type_tag } => (0, UnifiedEventKind::Unknown { raw_type: type_tag }),
    };
    Some(UnifiedEvent {
        seq,
        ts_ms,
        agent: "codex".into(),
        session_id: session_id.into(),
        kind,
    })
}

fn truncate(mut s: String, max: usize) -> String {
    if s.len() <= max {
        return s;
    }
    let mut idx = max;
    while !s.is_char_boundary(idx) && idx > 0 {
        idx -= 1;
    }
    s.truncate(idx);
    s.push_str("…");
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_session_meta() {
        let line = r#"{"type":"session_meta","payload":{"id":"abc","cwd":"/repo","originator":"Codex CLI"}}"#;
        match parse_line(line).unwrap() {
            RawEvent::SessionMeta { cwd } => assert_eq!(cwd.as_deref(), Some("/repo")),
            other => panic!("got {other:?}"),
        }
    }

    #[test]
    fn parses_user_and_agent_messages() {
        let user = r#"{"type":"event_msg","payload":{"type":"user_message","message":"hi"}}"#;
        match parse_line(user).unwrap() {
            RawEvent::UserMessage { text, .. } => assert_eq!(text, "hi"),
            other => panic!("got {other:?}"),
        }
        let asst = r#"{"type":"event_msg","payload":{"type":"agent_message","message":"yo"}}"#;
        match parse_line(asst).unwrap() {
            RawEvent::AssistantMessage { text, .. } => assert_eq!(text, "yo"),
            other => panic!("got {other:?}"),
        }
    }

    #[test]
    fn parses_response_item_message_user_and_assistant() {
        // Real codex (cli_version 0.130.0) emits user prompts as
        // `response_item.message` with role=user + input_text blocks.
        let user = r#"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"ls"}]}}"#;
        match parse_line(user).unwrap() {
            RawEvent::UserMessage { text, .. } => assert_eq!(text, "ls"),
            other => panic!("got {other:?}"),
        }
        let asst = r#"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"text","text":"hi"}]}}"#;
        match parse_line(asst).unwrap() {
            RawEvent::AssistantMessage { text, .. } => assert_eq!(text, "hi"),
            other => panic!("got {other:?}"),
        }
    }

    #[test]
    fn extract_title_skips_environment_context_wrapper() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("r.jsonl");
        // session_meta + auto-injected <environment_context> + real user input.
        let body = concat!(
            r#"{"type":"session_meta","payload":{"id":"x","cwd":"/repo","originator":"Codex CLI"}}"#,
            "\n",
            r#"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\n  <cwd>/repo</cwd>\n</environment_context>"}]}}"#,
            "\n",
            r#"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"refactor auth"}]}}"#,
            "\n",
        );
        std::fs::write(&path, body).unwrap();
        assert_eq!(extract_title(&path).as_deref(), Some("refactor auth"));
    }

    #[test]
    fn parses_function_call_and_result() {
        let call = r#"{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":{"cmd":"ls"}}}"#;
        match parse_line(call).unwrap() {
            RawEvent::FunctionCall { name, args, .. } => {
                assert_eq!(name, "shell");
                assert_eq!(args.get("cmd").and_then(|v| v.as_str()), Some("ls"));
            }
            other => panic!("got {other:?}"),
        }
        let out = r#"{"type":"response_item","payload":{"type":"function_call_output","name":"shell","output":"a\nb"}}"#;
        match parse_line(out).unwrap() {
            RawEvent::FunctionResult { name, output, .. } => {
                assert_eq!(name, "shell");
                assert_eq!(output, "a\nb");
            }
            other => panic!("got {other:?}"),
        }
    }
}
