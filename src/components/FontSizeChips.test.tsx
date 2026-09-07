// 字号 chips 对预设之外取值的处理。
//
// store 仍接受 8–32,老配置里可能存着 16 这类不在预设(12/13/14/15)里的
// 值。UI 必须把当前值显示成一个选中的「16(当前)」chip,而不是四个预设
// 全部未选中 —— 后者会让用户看不到当前值,一碰就被静默压回 12–15。
// 外观页(ui/editor/terminal 三条)与终端页(terminal)都要覆盖。

import { afterEach, describe, expect, it, vi } from "vitest";
import { i18next } from "../lib/i18n";
import { cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import type { ConfigView } from "../lib/types";
import { AppearanceSettings } from "./AppearanceSettings";
import { TerminalSettings } from "./TerminalSettings";

// 终端页启动时读一次平台来显示 shell;测试环境没有 Tauri,mock 掉。
vi.mock("@tauri-apps/plugin-os", () => ({ platform: () => "macos" }));

function makeConfig(fontSizes: ConfigView["font_sizes"]): ConfigView {
  return {
    agents: [],
    font_sizes: fontSizes,
    notifications: { enabled: true, only_when_unfocused: true },
    theme: "atelier",
  locale: "system",
    auto_hide_top_bar: false,
    startup: "resume",
    worktree: {
      isolate_by_default: false,
      branch_prefix: "ycode/",
      close_action: "ask",
    },
    checkpoints: { enabled: true, keep: 50 },
    session_open_mode: "replace_focused",
  };
}

afterEach(cleanup);

describe("外观页字号 chips", () => {
  it("预设内的值正常选中,不追加多余 chip", () => {
    render(
      <AppearanceSettings
        config={makeConfig({ ui: 13, editor: 14, terminal: 15 })}
        onChange={vi.fn()}
      />,
    );

    const uiGroup = screen.getByRole("radiogroup", { name: i18next.t("settings.appearance.laneFontSize", { lane: i18next.t("settings.appearance.laneUi") }) });
    expect(within(uiGroup).getAllByRole("radio")).toHaveLength(4);
    expect(within(uiGroup).getByRole("radio", { name: "13" })).toBeChecked();
  });

  it("预设外的值(16)显示为末尾的选中态 chip,不静默丢值", () => {
    render(
      <AppearanceSettings
        config={makeConfig({ ui: 16, editor: 13, terminal: 13 })}
        onChange={vi.fn()}
      />,
    );

    const uiGroup = screen.getByRole("radiogroup", { name: i18next.t("settings.appearance.laneFontSize", { lane: i18next.t("settings.appearance.laneUi") }) });
    const chips = within(uiGroup).getAllByRole("radio");
    expect(chips).toHaveLength(5);
    const current = within(uiGroup).getByRole("radio", { name: i18next.t("settings.appearance.currentValue", { value: 16 }) });
    expect(current).toBeChecked();
    expect(chips[chips.length - 1]).toBe(current);

    // 只有 ui 这条超出预设;editor 那条保持四个预设 chip。
    const editorGroup = screen.getByRole("radiogroup", { name: i18next.t("settings.appearance.laneFontSize", { lane: i18next.t("settings.appearance.laneEditor") }) });
    expect(within(editorGroup).getAllByRole("radio")).toHaveLength(4);
    expect(within(editorGroup).getByRole("radio", { name: "13" })).toBeChecked();
  });

  it("点其他 chip 才切换,当前值 chip 本身不触发变更丢值", () => {
    const onChange = vi.fn();
    render(
      <AppearanceSettings
        config={makeConfig({ ui: 16, editor: 13, terminal: 13 })}
        onChange={onChange}
      />,
    );

    const uiGroup = screen.getByRole("radiogroup", { name: i18next.t("settings.appearance.laneFontSize", { lane: i18next.t("settings.appearance.laneUi") }) });
    fireEvent.click(within(uiGroup).getByRole("radio", { name: "14" }));
    expect(onChange).toHaveBeenCalledTimes(1);
    expect(onChange.mock.calls[0][0].font_sizes.ui).toBe(14);
  });
});

describe("终端页字号 chips", () => {
  it("预设外的值(16)显示为末尾的选中态 chip", () => {
    render(
      <TerminalSettings
        config={makeConfig({ ui: 13, editor: 13, terminal: 16 })}
        onChange={vi.fn()}
      />,
    );

    const group = screen.getByRole("radiogroup", { name: i18next.t("settings.terminal.terminalFontSize") });
    expect(within(group).getAllByRole("radio")).toHaveLength(5);
    expect(
      within(group).getByRole("radio", { name: i18next.t("settings.appearance.currentValue", { value: 16 }) }),
    ).toBeChecked();
  });

  it("预设内的值不追加多余 chip", () => {
    render(
      <TerminalSettings
        config={makeConfig({ ui: 13, editor: 13, terminal: 12 })}
        onChange={vi.fn()}
      />,
    );

    const group = screen.getByRole("radiogroup", { name: i18next.t("settings.terminal.terminalFontSize") });
    expect(within(group).getAllByRole("radio")).toHaveLength(4);
    expect(within(group).getByRole("radio", { name: "12" })).toBeChecked();
  });
});
