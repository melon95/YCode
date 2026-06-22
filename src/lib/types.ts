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

import type { TodoView as RawTodoView } from "@bindings/TodoView";

export type TodoView = Omit<
  RawTodoView,
  "sort_order" | "started_at_ms" | "done_at_ms" | "created_at_ms" | "updated_at_ms"
> & {
  sort_order: number;
  started_at_ms: number | null;
  done_at_ms: number | null;
  created_at_ms: number;
  updated_at_ms: number;
};

export type { SessionStatus } from "@bindings/SessionStatus";
export type { AgentProfileView } from "@bindings/AgentProfileView";
export type { AgentLaunchProfileView } from "@bindings/AgentLaunchProfileView";
export type { ConfigView } from "@bindings/ConfigView";
export type { FontSizesView } from "@bindings/FontSizesView";
export type { NotificationSettingsView } from "@bindings/NotificationSettingsView";
export type { UiEvent } from "@bindings/UiEvent";
export type { UiEventKind } from "@bindings/UiEventKind";
export type { CreateSessionRequest } from "@bindings/CreateSessionRequest";
export type { CreateProjectRequest } from "@bindings/CreateProjectRequest";
export type { RenameSessionRequest } from "@bindings/RenameSessionRequest";
export type { WritePtyRequest } from "@bindings/WritePtyRequest";
export type { ResizePtyRequest } from "@bindings/ResizePtyRequest";
export type { SpawnPtyRequest } from "@bindings/SpawnPtyRequest";
export type { FileEntry } from "@bindings/FileEntry";
export type { FileContents } from "@bindings/FileContents";
export type { GitFileChange } from "@bindings/GitFileChange";
export type { GitFileStatus } from "@bindings/GitFileStatus";
export type { OpenInExternalEditorRequest } from "@bindings/OpenInExternalEditorRequest";
export type { WriteFileRequest } from "@bindings/WriteFileRequest";
import type { DiscoveredSessionView as RawDiscoveredSessionView } from "@bindings/DiscoveredSessionView";
export type DiscoveredSessionView = Omit<
  RawDiscoveredSessionView,
  "size_bytes" | "modified_at_ms"
> & {
  size_bytes: number;
  modified_at_ms: number;
};

import type { SearchHit as RawSearchHit } from "@bindings/SearchHit";
export type SearchHit = Omit<RawSearchHit, "seq" | "ts_ms"> & {
  seq: number;
  ts_ms: number;
};

import type { UnifiedEvent as RawUnifiedEvent } from "@bindings/UnifiedEvent";
export type UnifiedEvent = Omit<RawUnifiedEvent, "seq" | "ts_ms"> & {
  seq: number;
  ts_ms: number;
};

// Usage views type every numeric field as f64 on the Rust side, so ts-rs
// emits `number` throughout — no bigint retyping needed.
export type { TokenCountsView } from "@bindings/TokenCountsView";
export type { SessionUsageView } from "@bindings/SessionUsageView";
export type { ModelUsageView } from "@bindings/ModelUsageView";
export type { DailyUsageView } from "@bindings/DailyUsageView";
export type { ProjectUsageView } from "@bindings/ProjectUsageView";
export type { WorkspaceUsageView } from "@bindings/WorkspaceUsageView";

export type { UnifiedEventKind } from "@bindings/UnifiedEventKind";
export type { UnifiedRole } from "@bindings/UnifiedRole";
export type { ToolStatus } from "@bindings/ToolStatus";
export type { PlanStep } from "@bindings/PlanStep";
export type { DiffSummary } from "@bindings/DiffSummary";

export type { ServerManifest } from "@bindings/ServerManifest";
export type { InstallSpec } from "@bindings/InstallSpec";
export type { AssetPattern } from "@bindings/AssetPattern";
export type { CommandSpec } from "@bindings/CommandSpec";
export type { InstallStage } from "@bindings/InstallStage";

import type { LspManifestView as RawLspManifestView } from "@bindings/LspManifestView";
import type { LspInstallationView as RawLspInstallationView } from "@bindings/LspInstallationView";

export type LspInstallationView = Omit<RawLspInstallationView, "installed_at_ms"> & {
  installed_at_ms: number;
};
export type LspManifestView = Omit<RawLspManifestView, "installation"> & {
  installation: LspInstallationView | null;
};

/// Lowercased status label used as a CSS modifier (`.dot.running` etc.).
export type StatusLabel = "running" | "exited" | "error";

export function statusLabel(s: { type: string }): StatusLabel {
  return s.type.toLowerCase() as StatusLabel;
}

/// Convenience: `true` iff this session can accept a restart click.
export function isRestartable(status: { type: string }): boolean {
  return status.type === "Exited" || status.type === "Error";
}
