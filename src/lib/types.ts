// Re-export the ts-rs–generated bindings under stable names, with one
// pragmatic patch: `*_at_ms` fields are typed `bigint` because their Rust
// originals are u64/i64, but Tauri's JSON wire format delivers them as JS
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

import type { ReplayRequest as RawReplayRequest } from "@bindings/ReplayRequest";
import type { ReplayEntry as RawReplayEntry } from "@bindings/ReplayEntry";

export type ReplayRequest = Omit<RawReplayRequest, "from_seq"> & {
  from_seq: number;
};
export type ReplayEntry = Omit<RawReplayEntry, "seq" | "ts_ms"> & {
  seq: number;
  ts_ms: number;
};

export type { SessionState } from "@bindings/SessionState";
export type { AgentEvent } from "@bindings/AgentEvent";
export type { AgentProfileView } from "@bindings/AgentProfileView";
export type { UiEvent } from "@bindings/UiEvent";
export type { UiEventKind } from "@bindings/UiEventKind";
export type { CreateSessionRequest } from "@bindings/CreateSessionRequest";
export type { SendPromptRequest } from "@bindings/SendPromptRequest";
export type { AnswerPermissionRequest } from "@bindings/AnswerPermissionRequest";
export type { PermissionOption } from "@bindings/PermissionOption";
export type { PermissionKind } from "@bindings/PermissionKind";
export type { ToolStatus } from "@bindings/ToolStatus";
export type { PlanItem } from "@bindings/PlanItem";
export type { AgentCommand } from "@bindings/AgentCommand";

export type StateLabel =
  | "idle"
  | "initializing"
  | "running"
  | "awaitingpermission"
  | "cancelling"
  | "done"
  | "error";

export function stateLabel(s: { type: string }): StateLabel {
  return s.type.toLowerCase() as StateLabel;
}
