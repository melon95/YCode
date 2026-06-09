//! Claude Code session discovery + jsonl parsing.
//!
//! Layout: `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl`.
//! `encoded-cwd` is `cwd.replace('/', '-')`. Reverse-mapping the encoded
//! string is **not** unambiguous (cwds containing `-` collide) so callers
//! must keep a forward table per plan §12.5.1.

use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::unified::{
    DiffSummary, PlanStep, ToolStatus, UnifiedEvent, UnifiedEventKind, UnifiedRole,
};
use crate::{AgentBackend, DiscoveredSession, IntrospectError};

pub struct ClaudeBackend;

impl AgentBackend for ClaudeBackend {
    fn name(&self) -> &'static str {
        "claude"
    }

    fn sessions_root(&self, home: &Path) -> Option<PathBuf> {
        Some(home.join(".claude").join("projects"))
    }

    fn workspace_dir(&self, home: &Path, cwd: &Path) -> Option<PathBuf> {
        self.sessions_root(home)
            .map(|root| root.join(encode_cwd(cwd)))
    }
}

/// `/Users/melon/work/x` → `-Users-melon-work-x`. The forward direction is
/// the only reliable one.
pub fn encode_cwd(cwd: &Path) -> String {
    cwd.to_string_lossy().replace('/', "-")
}

/// Discover every `*.jsonl` session under `<root>/<encoded-cwd>` matching
/// `cwd`. Returns sessions in undefined order — caller sorts.
pub fn scan_workspace(home: &Path, cwd: &Path) -> Result<Vec<DiscoveredSession>, IntrospectError> {
    let dir = ClaudeBackend
        .workspace_dir(home, cwd)
        .ok_or_else(|| IntrospectError::Io("no home dir".into()))?;
    if !dir.is_dir() {
        return Ok(vec![]);
    }
    let mut out = Vec::new();
    for entry in std::fs::read_dir(&dir).map_err(|e| IntrospectError::Io(e.to_string()))? {
        let entry = match entry {
            Ok(e) => e,
            Err(_) => continue,
        };
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("jsonl") {
            continue;
        }
        let session_id = path
            .file_stem()
            .and_then(|s| s.to_str())
            .map(|s| s.to_string());
        let title = extract_title(&path);
        out.push(DiscoveredSession {
            agent: "claude",
            jsonl_path: path,
            session_id,
            cwd: Some(cwd.to_path_buf()),
            title,
        });
    }
    Ok(out)
}

/// Read the first ~40 lines of `path` and return:
/// * the `summary` event's `summary` field, if present (best title — claude
///   writes one when the user picks "Compact conversation"); else
/// * the first `user` message text, truncated to ~80 chars.
fn extract_title(path: &Path) -> Option<String> {
    use std::io::{BufRead, BufReader};
    let f = std::fs::File::open(path).ok()?;
    let mut reader = BufReader::new(f);
    let mut buf = String::new();
    let mut first_user: Option<String> = None;
    for _ in 0..40 {
        buf.clear();
        let read = reader.read_line(&mut buf).ok()?;
        if read == 0 {
            break;
        }
        let trimmed = buf.trim();
        if trimmed.is_empty() {
            continue;
        }
        let v: serde_json::Value = match serde_json::from_str(trimmed) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let kind = v.get("type").and_then(|s| s.as_str()).unwrap_or("");
        if kind == "summary" {
            if let Some(s) = v.get("summary").and_then(|s| s.as_str()) {
                return Some(truncate_title(s));
            }
        }
        if kind == "user" && first_user.is_none() {
            if let Some(text) = extract_text(&v) {
                if !text.trim().is_empty() {
                    first_user = Some(truncate_title(text.trim()));
                }
            }
        }
    }
    first_user
}

fn truncate_title(s: &str) -> String {
    const MAX: usize = 80;
    // Collapse newlines so titles stay one-line.
    let one_line: String = s.chars().map(|c| if c == '\n' { ' ' } else { c }).collect();
    if one_line.chars().count() <= MAX {
        return one_line;
    }
    let mut out: String = one_line.chars().take(MAX).collect();
    out.push('…');
    out
}

/// Parse one jsonl line into a typed `RawEvent`. Defensive: unknown shapes
/// surface as `RawEvent::Unknown` rather than failing the whole batch
/// (plan R1).
#[derive(Clone, Debug)]
pub enum RawEvent {
    User {
        text: String,
        ts_ms: i64,
    },
    Assistant {
        text: String,
        ts_ms: i64,
    },
    Thinking {
        text: String,
        ts_ms: i64,
    },
    ToolUse {
        tool: String,
        input: Value,
        ts_ms: i64,
    },
    ToolResult {
        tool: String,
        output: String,
        is_error: bool,
        ts_ms: i64,
    },
    Plan {
        steps: Vec<PlanStep>,
        ts_ms: i64,
    },
    Unknown {
        type_tag: String,
    },
}

pub fn parse_line(line: &str) -> Result<RawEvent, IntrospectError> {
    let v: Value = serde_json::from_str(line).map_err(|e| IntrospectError::Parse(e.to_string()))?;
    let ts_ms = parse_ts(&v);
    let kind = v.get("type").and_then(|t| t.as_str()).unwrap_or("");

    match kind {
        "user" => Ok(RawEvent::User {
            text: extract_text(&v).unwrap_or_default(),
            ts_ms,
        }),
        "assistant" => {
            // Assistant messages may carry tool_use or thinking blocks.
            if let Some(content) = v.pointer("/message/content").and_then(|c| c.as_array()) {
                for block in content {
                    let block_type = block.get("type").and_then(|t| t.as_str()).unwrap_or("");
                    if block_type == "tool_use" {
                        let tool = block
                            .get("name")
                            .and_then(|n| n.as_str())
                            .unwrap_or("")
                            .to_string();
                        let input = block.get("input").cloned().unwrap_or(Value::Null);
                        return Ok(RawEvent::ToolUse { tool, input, ts_ms });
                    }
                    if block_type == "thinking" {
                        let text = block
                            .get("thinking")
                            .and_then(|t| t.as_str())
                            .unwrap_or("")
                            .to_string();
                        return Ok(RawEvent::Thinking { text, ts_ms });
                    }
                }
            }
            Ok(RawEvent::Assistant {
                text: extract_text(&v).unwrap_or_default(),
                ts_ms,
            })
        }
        "tool_result" | "user_tool_result" => {
            // Some claude versions embed the tool result as `type=user` with
            // a tool_result block inside; others emit a dedicated event.
            let tool = v
                .pointer("/message/content/0/tool_use_id")
                .and_then(|t| t.as_str())
                .unwrap_or("")
                .to_string();
            let output = v
                .pointer("/message/content/0/content")
                .and_then(|c| c.as_str())
                .unwrap_or("")
                .to_string();
            let is_error = v
                .pointer("/message/content/0/is_error")
                .and_then(|b| b.as_bool())
                .unwrap_or(false);
            Ok(RawEvent::ToolResult {
                tool,
                output,
                is_error,
                ts_ms,
            })
        }
        "summary" => Ok(RawEvent::Assistant {
            text: v
                .get("summary")
                .and_then(|s| s.as_str())
                .unwrap_or("")
                .to_string(),
            ts_ms,
        }),
        other => Ok(RawEvent::Unknown {
            type_tag: other.to_string(),
        }),
    }
}

fn parse_ts(v: &Value) -> i64 {
    if let Some(s) = v.get("timestamp").and_then(|t| t.as_str()) {
        if let Ok(t) =
            time::OffsetDateTime::parse(s, &time::format_description::well_known::Rfc3339)
        {
            return t.unix_timestamp() * 1000 + (t.millisecond() as i64);
        }
    }
    0
}

fn extract_text(v: &Value) -> Option<String> {
    // Modern claude: `message.content` is an array of blocks each with text.
    if let Some(arr) = v.pointer("/message/content").and_then(|c| c.as_array()) {
        let mut buf = String::new();
        for block in arr {
            if let Some(text) = block.get("text").and_then(|t| t.as_str()) {
                if !buf.is_empty() {
                    buf.push('\n');
                }
                buf.push_str(text);
            }
        }
        if !buf.is_empty() {
            return Some(buf);
        }
    }
    // Legacy: `message.content` is a plain string.
    if let Some(s) = v.pointer("/message/content").and_then(|c| c.as_str()) {
        return Some(s.to_string());
    }
    None
}

/// Normalise into `UnifiedEvent`. `session_id` and `seq` are filled by the
/// caller because they aren't on the raw line.
pub fn normalize(raw: RawEvent, seq: u64, session_id: &str) -> UnifiedEvent {
    let (ts_ms, kind) = match raw {
        RawEvent::User { text, ts_ms } => (
            ts_ms,
            UnifiedEventKind::Message {
                role: UnifiedRole::User,
                text,
            },
        ),
        RawEvent::Assistant { text, ts_ms } => (
            ts_ms,
            UnifiedEventKind::Message {
                role: UnifiedRole::Assistant,
                text,
            },
        ),
        RawEvent::Thinking { text, ts_ms } => (ts_ms, UnifiedEventKind::Thinking { text }),
        RawEvent::ToolUse { tool, input, ts_ms } => (
            ts_ms,
            UnifiedEventKind::ToolUse {
                tool,
                input_json: input.to_string(),
                status: ToolStatus::Pending,
            },
        ),
        RawEvent::ToolResult {
            tool,
            output,
            is_error,
            ts_ms,
        } => (
            ts_ms,
            UnifiedEventKind::ToolResult {
                tool,
                output_excerpt: truncate(output, 4096),
                status: if is_error {
                    ToolStatus::Error
                } else {
                    ToolStatus::Ok
                },
            },
        ),
        RawEvent::Plan { steps, ts_ms } => (ts_ms, UnifiedEventKind::Plan { steps }),
        RawEvent::Unknown { type_tag } => (0, UnifiedEventKind::Unknown { raw_type: type_tag }),
    };
    UnifiedEvent {
        seq,
        ts_ms,
        agent: "claude".into(),
        session_id: session_id.into(),
        kind,
    }
}

fn truncate(mut s: String, max: usize) -> String {
    if s.len() <= max {
        return s;
    }
    // Find a char boundary at or below max.
    let mut idx = max;
    while !s.is_char_boundary(idx) && idx > 0 {
        idx -= 1;
    }
    s.truncate(idx);
    s.push_str("…");
    s
}

// Quiet the unused-import lint when only DiffSummary is referenced transitively.
#[allow(dead_code)]
fn _ensure_diff_summary_visible(_: DiffSummary) {}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn encode_cwd_is_simple_slash_replacement() {
        assert_eq!(
            encode_cwd(&PathBuf::from("/Users/me/work/app")),
            "-Users-me-work-app"
        );
    }

    #[test]
    fn parses_user_assistant_text() {
        let user =
            r#"{"type":"user","message":{"content":"hi"},"timestamp":"2024-05-01T12:00:00Z"}"#;
        match parse_line(user).unwrap() {
            RawEvent::User { text, .. } => assert_eq!(text, "hi"),
            other => panic!("got {other:?}"),
        }

        let asst = r#"{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}}"#;
        match parse_line(asst).unwrap() {
            RawEvent::Assistant { text, .. } => assert_eq!(text, "hello"),
            other => panic!("got {other:?}"),
        }
    }

    #[test]
    fn parses_tool_use_block() {
        let line = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"a.ts"}}]}}"#;
        match parse_line(line).unwrap() {
            RawEvent::ToolUse { tool, input, .. } => {
                assert_eq!(tool, "Read");
                assert_eq!(
                    input.get("file_path").and_then(|v| v.as_str()),
                    Some("a.ts")
                );
            }
            other => panic!("got {other:?}"),
        }
    }

    #[test]
    fn parses_thinking_block() {
        let line =
            r#"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hm"}]}}"#;
        match parse_line(line).unwrap() {
            RawEvent::Thinking { text, .. } => assert_eq!(text, "hm"),
            other => panic!("got {other:?}"),
        }
    }

    #[test]
    fn unknown_type_does_not_error() {
        let line = r#"{"type":"some-new-type","payload":{}}"#;
        match parse_line(line).unwrap() {
            RawEvent::Unknown { type_tag } => assert_eq!(type_tag, "some-new-type"),
            other => panic!("got {other:?}"),
        }
    }

    #[test]
    fn normalize_emits_user_message() {
        let ev = normalize(
            RawEvent::User {
                text: "hi".into(),
                ts_ms: 0,
            },
            3,
            "sess-uuid",
        );
        assert_eq!(ev.session_id, "sess-uuid");
        assert_eq!(ev.seq, 3);
        match ev.kind {
            UnifiedEventKind::Message {
                role: UnifiedRole::User,
                text,
            } => assert_eq!(text, "hi"),
            other => panic!("got {other:?}"),
        }
    }
}
