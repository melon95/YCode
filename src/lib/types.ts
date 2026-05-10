// Re-export the ts-rs–generated bindings under stable names, with one
// pragmatic patch: `*_at_ms` fields are typed `bigint` because their Rust
// originals are i64, but Tauri's JSON wire format delivers them as JS
// numbers. We retype them to `number` so consumers (sort, compare, format)
// don't need `Number(...)` casts everywhere.

import type { SessionView as RawSessionView } from "@bindings/SessionView";

export type SessionView = Omit<
  RawSessionView,
  "created_at_ms" | "updated_at_ms" | "archived_at_ms"
> & {
  created_at_ms: number;
  updated_at_ms: number;
  archived_at_ms: number | null;
};

import type { ProjectView as RawProjectView } from "@bindings/ProjectView";

export type ProjectView = Omit<
  RawProjectView,
  "created_at_ms" | "session_count"
> & {
  created_at_ms: number;
  session_count: number;
};

export type { SessionStatus } from "@bindings/SessionStatus";
export type { AgentProfileView } from "@bindings/AgentProfileView";
export type { UiEvent } from "@bindings/UiEvent";
export type { UiEventKind } from "@bindings/UiEventKind";
export type { CreateSessionRequest } from "@bindings/CreateSessionRequest";
export type { CreateProjectRequest } from "@bindings/CreateProjectRequest";
export type { WritePtyRequest } from "@bindings/WritePtyRequest";
export type { ResizePtyRequest } from "@bindings/ResizePtyRequest";

/// Lowercased status label used as a CSS modifier (`.dot.running` etc.).
export type StatusLabel = "running" | "exited" | "error";

export function statusLabel(s: { type: string }): StatusLabel {
  return s.type.toLowerCase() as StatusLabel;
}

/// Convenience: `true` iff this session can accept a restart click.
export function isRestartable(status: { type: string }): boolean {
  return status.type === "Exited" || status.type === "Error";
}
