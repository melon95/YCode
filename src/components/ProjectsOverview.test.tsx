// 项目总览卡片的行为函数测试 — 只覆盖纯函数(相对时间格式化),
// 组件本体的渲染由集成路径兜底。

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { relativeTime } from "./ProjectsOverview";

// 组件模块顶层会引到 tauri/ipc,纯函数测试里全部 mock 掉。
vi.mock("../lib/ipc", () => ({
  createProject: vi.fn(),
  gitBranch: vi.fn(),
}));
vi.mock("@tauri-apps/plugin-dialog", () => ({ open: vi.fn() }));

describe("relativeTime", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-08-31T12:00:00Z"));
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it("一分钟内显示「刚刚」", () => {
    expect(relativeTime(Date.now() - 30_000)).toBe("刚刚");
  });

  it("小时内按分钟计", () => {
    expect(relativeTime(Date.now() - 5 * 60_000)).toBe("5 分钟前");
  });

  it("一天内按小时计", () => {
    expect(relativeTime(Date.now() - 3 * 3_600_000)).toBe("3 小时前");
  });

  it("超过一天按天计 — 空闲卡片的「上次会话 2 天前」", () => {
    expect(relativeTime(Date.now() - 2 * 86_400_000)).toBe("2 天前");
  });
});
