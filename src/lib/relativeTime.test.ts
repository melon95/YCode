// 相对时间格式化。原本这套断言长在 ProjectsOverview.test.tsx 上,那会儿
// 函数还住在组件文件里;三份重复实现合并到 lib/relativeTime 之后,测试
// 跟着搬过来 —— 顺带甩掉了为测一个纯函数而 mock 掉 tauri/ipc 的那一坨。

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { i18next } from "./i18n";
import { relativeTime } from "./relativeTime";

const t = i18next.t.bind(i18next);

describe("relativeTime", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-08-31T12:00:00Z"));
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  // 断言比的是「渲染成哪条词条」而不是某种语言的字面量:后者会让这些
  // 用例锁死在一种语言上,换语言就得改测试,而阈值逻辑其实没动。
  it("一分钟内显示「刚刚」", () => {
    expect(relativeTime(Date.now() - 30_000, t)).toBe(t("time.justNow"));
  });

  it("小时内按分钟计", () => {
    expect(relativeTime(Date.now() - 5 * 60_000, t)).toBe(
      t("time.minutesAgo", { count: 5 }),
    );
  });

  it("一天内按小时计", () => {
    expect(relativeTime(Date.now() - 3 * 3_600_000, t)).toBe(
      t("time.hoursAgo", { count: 3 }),
    );
  });

  it("超过一天按天计 — 空闲卡片的「上次会话 2 天前」", () => {
    expect(relativeTime(Date.now() - 2 * 86_400_000, t)).toBe(
      t("time.daysAgo", { count: 2 }),
    );
  });

  // 边界各查一次:阈值写成 `<` 还是 `<=` 决定了整点那一刻显示「60 分钟前」
  // 还是「1 小时前」,而这正是相对时间最容易写错的地方。
  it("跨过阈值就进位", () => {
    expect(relativeTime(Date.now() - 60_000, t)).toBe(
      t("time.minutesAgo", { count: 1 }),
    );
    expect(relativeTime(Date.now() - 3_600_000, t)).toBe(
      t("time.hoursAgo", { count: 1 }),
    );
    expect(relativeTime(Date.now() - 86_400_000, t)).toBe(
      t("time.daysAgo", { count: 1 }),
    );
  });
});
