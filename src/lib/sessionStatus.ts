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

/// 状态名的词条 key,不是文案本身 —— 这张表在模块加载时就求值,那会儿
/// i18next 还没 init,直接存译文会把启动时的语言永久烙进常量里,之后
/// 用户再换语言这些字也不会跟着变。存 key、由调用点 `t()` 是唯一能让
/// 它跟随语言切换的形态。
export const STATUS_LABEL_KEY: Record<StatusKind, string> = {
  working: "status.working",
  blocked: "status.blocked",
  done: "status.done",
  error: "status.error",
  idle: "status.idle",
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

/// 「等你处理」在收到多少字节的 PTY 输出之后该自己撤下来。
///
/// 清除 waiting 原本只有一条路:用户在 ycode 自己的终端里敲字
/// (`terminalInput.ts`)。可 agent 的终端未必在 ycode 里 —— 在外部终端
/// (ghostty/iTerm)、另一台机器、或 CLI 自己的窗口里答完权限询问,ycode
/// 一个按键都收不到,那条「等你处理」就永远挂在收件箱上,而会话其实早
/// 就继续跑了。
///
/// PTY 输出是这种情况下唯一能看见的「agent 又动起来了」的证据,但不能
/// 一有输出就撤:turn-complete 钩子触发之后,CLI 还会继续吐尾巴 ——
/// 重绘输入框、插件提示、光标定位。那些字节紧跟在 waiting 之后到达,
/// 拿它们当「用户答过了」会让灯在用户读到之前就灭掉,正是
/// `terminalInput.ts` 里那段注释当初要避开的坑。
///
/// 所以用体量把两者分开:尾巴是几百字节的定长重绘,而真正恢复工作的
/// agent 会成千字节地刷。阈值取 4 KiB —— 高到装得下最啰嗦的收尾重绘,
/// 低到 agent 一开口就会越过。
export const RESUME_OUTPUT_BYTES = 4096;

/// 累计输出是否已经越过阈值、足以判定 agent 自己恢复了工作。
export function outputImpliesResumed(bytesSinceWaiting: number): boolean {
  return bytesSinceWaiting >= RESUME_OUTPUT_BYTES;
}
