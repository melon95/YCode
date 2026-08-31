// Session status vocabulary for the redesigned UI.
//
// The store already computes a 4-state `SessionLight` (running / waiting /
// done / error) by folding the PTY lifecycle together with the agent's turn
// signal. This module renames those states into the vocabulary the redesign
// uses and pins each one to a themed color token, so every surface that shows
// status (sidebar rows, project tabs, panes, status bar, inbox) agrees on
// both the wording and the visual treatment.
//
// The mapping is deliberately attention-ordered: `blocked` is the only state
// that means "nothing moves until you act", so it gets the alarm color and
// the only ring animation.

import type { SessionLight } from "./types";

export type StatusKind = "working" | "blocked" | "done" | "error" | "idle";

export const STATUS_BY_LIGHT: Record<SessionLight, StatusKind> = {
  running: "working",
  waiting: "blocked",
  done: "done",
  error: "error",
};

export const STATUS_LABEL: Record<StatusKind, string> = {
  working: "进行中",
  blocked: "等你处理",
  done: "已完成",
  error: "出错",
  idle: "空闲",
};

/// Sort weight for "which session should I look at first". Lower sorts first.
export const STATUS_RANK: Record<StatusKind, number> = {
  blocked: 0,
  error: 1,
  working: 2,
  done: 3,
  idle: 4,
};

export function statusFromLight(light: SessionLight | undefined): StatusKind {
  return light ? STATUS_BY_LIGHT[light] : "idle";
}
