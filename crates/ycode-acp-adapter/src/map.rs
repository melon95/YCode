//! Map ACP `session/update` notifications onto our adapter's `AgentEvent`.
//!
//! Single-file translation layer keeps the wire-shape changes localised; the
//! orchestrator never sees ACP types.

use ulid::Ulid;
use ycode_adapter::{
    AgentCommand, AgentEvent, FileLoc, PermissionKind, PermissionOption, PlanItem, ToolStatus,
};

use crate::protocol::{
    AcpStopReason, ContentBlock, PermissionOptionWire, SessionUpdate, ToolCallStatus,
    ToolCallUpdate,
};

pub fn map_update(update: SessionUpdate) -> Option<AgentEvent> {
    match update {
        SessionUpdate::AgentMessageChunk(chunk) => Some(AgentEvent::AssistantText {
            chunk_id: Ulid::new().to_string(),
            text: extract_text(&chunk.content),
            final_chunk: false,
        }),
        SessionUpdate::AgentThoughtChunk(_) => None, // not surfaced in MVP UI
        SessionUpdate::UserMessageChunk(chunk) => Some(AgentEvent::UserEcho {
            text: extract_text(&chunk.content),
        }),
        SessionUpdate::ToolCall(tc) => Some(map_tool_call_started(tc)),
        SessionUpdate::ToolCallUpdate(tc) => Some(map_tool_call_updated(tc)),
        SessionUpdate::Plan(plan) => Some(AgentEvent::Plan {
            items: plan
                .entries
                .into_iter()
                .enumerate()
                .map(|(i, e)| PlanItem {
                    id: format!("p{i}"),
                    title: e.content.unwrap_or_default(),
                    status: e
                        .status
                        .as_deref()
                        .map(plan_status_to_tool_status)
                        .unwrap_or(ToolStatus::Pending),
                    priority: priority_to_u8(e.priority.as_deref()),
                })
                .collect(),
        }),
        SessionUpdate::AvailableCommandsUpdate(cmds) => Some(AgentEvent::AvailableCommands {
            commands: cmds
                .available_commands
                .into_iter()
                .map(|c| AgentCommand {
                    name: c.name,
                    description: c.description,
                })
                .collect(),
        }),
        SessionUpdate::CurrentModeUpdate(m) => Some(AgentEvent::ModeChanged {
            mode_id: m.current_mode_id,
        }),
        SessionUpdate::Unknown => None,
    }
}

pub fn extract_text(block: &ContentBlock) -> String {
    match block {
        ContentBlock::Text { text } => text.clone(),
        ContentBlock::Other => String::new(),
    }
}

fn map_tool_call_started(tc: ToolCallUpdate) -> AgentEvent {
    AgentEvent::ToolCallStarted {
        id: tc.tool_call_id.clone().unwrap_or_else(|| Ulid::new().to_string()),
        name: tc.title.clone().or(tc.kind.clone()).unwrap_or_else(|| "tool".into()),
        args_preview: tc
            .raw_input
            .as_ref()
            .map(|v| short_preview(v))
            .unwrap_or_default(),
        locations: tc
            .locations
            .clone()
            .unwrap_or_default()
            .into_iter()
            .map(|l| FileLoc {
                path: l.path,
                line: l.line,
            })
            .collect(),
    }
}

fn map_tool_call_updated(tc: ToolCallUpdate) -> AgentEvent {
    let status = tc
        .status
        .map(map_status)
        .unwrap_or(ToolStatus::Running);
    let output_preview = tc.content.as_ref().and_then(|c| c.first()).map(|v| short_preview(v));
    AgentEvent::ToolCallUpdated {
        id: tc.tool_call_id.unwrap_or_default(),
        status,
        output_preview,
    }
}

pub fn map_status(s: ToolCallStatus) -> ToolStatus {
    match s {
        ToolCallStatus::Pending => ToolStatus::Pending,
        ToolCallStatus::InProgress => ToolStatus::Running,
        ToolCallStatus::Completed => ToolStatus::Completed,
        ToolCallStatus::Failed => ToolStatus::Failed,
        ToolCallStatus::Cancelled => ToolStatus::Cancelled,
    }
}

pub fn map_stop_reason(s: AcpStopReason) -> ycode_adapter::StopReason {
    use ycode_adapter::StopReason as Y;
    match s {
        AcpStopReason::EndTurn => Y::EndTurn,
        AcpStopReason::MaxTokens => Y::MaxTokens,
        AcpStopReason::MaxTurnRequests => Y::Other {
            detail: "max_turn_requests".into(),
        },
        AcpStopReason::Refusal => Y::Refusal,
        AcpStopReason::Cancelled => Y::Cancelled,
    }
}

pub fn map_permission_options(opts: Vec<PermissionOptionWire>) -> Vec<PermissionOption> {
    opts.into_iter()
        .map(|o| PermissionOption {
            option_id: o.option_id,
            name: o.name,
            kind: o
                .kind
                .as_deref()
                .map(permission_kind_from_str)
                .unwrap_or(PermissionKind::AllowOnce),
        })
        .collect()
}

fn permission_kind_from_str(s: &str) -> PermissionKind {
    match s {
        "allow_always" => PermissionKind::AllowAlways,
        "reject_once" => PermissionKind::RejectOnce,
        "reject_always" => PermissionKind::RejectAlways,
        _ => PermissionKind::AllowOnce,
    }
}

fn plan_status_to_tool_status(s: &str) -> ToolStatus {
    match s {
        "pending" => ToolStatus::Pending,
        "in_progress" => ToolStatus::Running,
        "completed" => ToolStatus::Completed,
        "failed" => ToolStatus::Failed,
        _ => ToolStatus::Pending,
    }
}

fn priority_to_u8(p: Option<&str>) -> u8 {
    match p {
        Some("high") => 0,
        Some("medium") => 1,
        Some("low") => 2,
        _ => 1,
    }
}

fn short_preview(v: &serde_json::Value) -> String {
    let s = serde_json::to_string(v).unwrap_or_default();
    if s.len() > 200 {
        format!("{}…", &s[..200])
    } else {
        s
    }
}
