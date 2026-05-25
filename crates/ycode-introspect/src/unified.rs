//! Normalised view of one event from a CLI agent session. Per plan §5.5.2.
//!
//! The frontend renders a stream of these regardless of source agent so
//! HistoryTab only has to know one shape.

use serde::{Deserialize, Serialize};
use ts_rs::TS;

#[derive(Clone, Debug, Serialize, Deserialize, TS, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
#[ts(export, export_to = "../../ycode-ipc/bindings/")]
pub enum UnifiedRole {
    User,
    Assistant,
    System,
    Tool,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
#[ts(export, export_to = "../../ycode-ipc/bindings/")]
pub enum ToolStatus {
    Pending,
    Ok,
    Error,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS, PartialEq, Eq)]
#[ts(export, export_to = "../../ycode-ipc/bindings/")]
pub struct PlanStep {
    pub text: String,
    /// "done" | "in_progress" | "todo" — kept as a plain string so we can
    /// surface anything the agent emits without churn-recompiling enums.
    pub state: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS, PartialEq, Eq)]
#[ts(export, export_to = "../../ycode-ipc/bindings/")]
pub struct DiffSummary {
    pub file: String,
    pub additions: u32,
    pub deletions: u32,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
#[ts(export, export_to = "../../ycode-ipc/bindings/")]
pub enum UnifiedEventKind {
    /// Plain chat message.
    Message { role: UnifiedRole, text: String },
    /// Model "thinking" / scratchpad. May be hidden by default in UI.
    Thinking { text: String },
    /// Tool call request (Read/Edit/Bash/etc).
    ToolUse {
        tool: String,
        input_json: String,
        status: ToolStatus,
    },
    /// Tool call response.
    ToolResult {
        tool: String,
        output_excerpt: String,
        status: ToolStatus,
    },
    /// Structured plan / todo list update.
    Plan { steps: Vec<PlanStep> },
    /// One or more file edits committed by the agent.
    Edits { files: Vec<DiffSummary> },
    /// Permission prompt surface (e.g. "Allow Bash?").
    Permission {
        tool: String,
        summary: String,
        decided: Option<String>,
    },
    /// Catch-all for events we don't yet model — keeps the parser
    /// forward-compatible without dropping data on the floor (plan R1).
    Unknown { raw_type: String },
}

/// One normalised event from a session jsonl line. `seq` is the line number
/// (0-indexed); `ts_ms` is unix-millis (or 0 when the source line carries
/// no timestamp).
#[derive(Clone, Debug, Serialize, Deserialize, TS, PartialEq, Eq)]
#[ts(export, export_to = "../../ycode-ipc/bindings/")]
pub struct UnifiedEvent {
    pub seq: u64,
    pub ts_ms: i64,
    pub agent: String,
    pub session_id: String,
    pub kind: UnifiedEventKind,
}

impl UnifiedEvent {
    /// Short snippet for FTS / preview columns. Caller is expected to
    /// truncate further as needed.
    pub fn preview(&self) -> String {
        match &self.kind {
            UnifiedEventKind::Message { text, .. } => text.clone(),
            UnifiedEventKind::Thinking { text } => text.clone(),
            UnifiedEventKind::ToolUse { tool, .. } => format!("[tool: {tool}]"),
            UnifiedEventKind::ToolResult { tool, .. } => format!("[result: {tool}]"),
            UnifiedEventKind::Plan { steps } => steps
                .iter()
                .map(|s| s.text.as_str())
                .collect::<Vec<_>>()
                .join(" / "),
            UnifiedEventKind::Edits { files } => files
                .iter()
                .map(|f| f.file.as_str())
                .collect::<Vec<_>>()
                .join(", "),
            UnifiedEventKind::Permission { summary, .. } => summary.clone(),
            UnifiedEventKind::Unknown { raw_type } => format!("?? {raw_type}"),
        }
    }
}
