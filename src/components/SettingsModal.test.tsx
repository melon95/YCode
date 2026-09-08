import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { i18next } from "../lib/i18n";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import type { ConfigView } from "../lib/types";
import { getConfig, saveConfig } from "../lib/ipc";
import { SettingsScreen } from "./SettingsModal";

vi.mock("../lib/ipc", () => ({
  getConfig: vi.fn(),
  resetConfig: vi.fn(),
  saveConfig: vi.fn(),
  // Agent 目录的 PATH 探测:测试环境里什么都探不到,「已检测到」分组不出现。
  probeCommand: vi.fn(() => Promise.resolve(false)),
  // 「集成」角标的轻量状态查询。都返回已接入 → 角标不出现,
  // 各条测试不用惦记它。
  cliStatus: vi.fn(() =>
    Promise.resolve({ kind: "installed", path: "/usr/local/bin/ycode", target: "/x" }),
  ),
  agentHookStatus: vi.fn(() =>
    Promise.resolve({ agent: "codex", kind: "installed" }),
  ),
  mcpStatus: vi.fn(() => Promise.resolve("installed")),
}));
vi.mock("../lib/confirm", () => ({ confirmDialog: vi.fn(() => true) }));
vi.mock("./AgentIcon", () => ({
  AgentIcon: ({ fallbackChar }: { fallbackChar: string }) => (
    <span aria-hidden>{fallbackChar.slice(0, 1)}</span>
  ),
}));
vi.mock("./AppearanceSettings", () => ({
  AppearanceSettings: () => <div>Appearance panel</div>,
}));
vi.mock("./LanguagesSettings", () => ({
  LanguagesSettings: () => <div>Languages panel</div>,
}));
vi.mock("./NotificationsSettings", () => ({
  NotificationsSettings: () => <div>Notifications panel</div>,
}));
vi.mock("./UsageSettings", () => ({ UsageSettings: () => <div>Usage panel</div> }));
vi.mock("./UpdatesSettings", () => ({
  UpdatesSettings: () => <div>Updates panel</div>,
}));

const config: ConfigView = {
  agents: [
    {
      id: "codex",
      display_name: "Codex",
      command: "codex",
      args: [],
      env: {},
      icon: "Codex",
      icon_variant: null,
      color: null,
      introspect: "codex",
    },
  ],
  font_sizes: { ui: 13, editor: 13, terminal: 13 },
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
  proxy: { mode: "system", url: "", no_proxy: "" },
  session_open_mode: "replace_focused",
};

describe("SettingsScreen", () => {
  beforeEach(() => {
    vi.mocked(getConfig).mockResolvedValue(structuredClone(config));
    vi.mocked(saveConfig).mockResolvedValue([]);
  });

  afterEach(() => {
    cleanup();
    vi.clearAllMocks();
  });

  it("renders as a dialog over the workspace and switches sections", async () => {
    render(<SettingsScreen onClose={vi.fn()} />);

    expect(await screen.findByRole("dialog", { name: i18next.t("settings.shell.title") })).toBeVisible();
    expect(screen.getByRole("button", { name: i18next.t("settings.shell.closeAria") })).toBeVisible();
    expect(screen.getByText(i18next.t("settings.agents.configured", { count: 1 }))).toBeVisible();

    fireEvent.click(screen.getByRole("button", { name: i18next.t("settings.nav.appearance") }));
    expect(screen.getByText("Appearance panel")).toBeVisible();
  });

  // Was driven by the "add Gemini CLI" button in the known-agent catalogue.
  // That catalogue is gone (a static list of thirteen mostly-uninstalled
  // CLIs), so the same staging path is exercised through the custom form —
  // which is now the only way to add one.
  it("stages a custom agent and saves it through the existing config flow", async () => {
    const onClose = vi.fn();
    render(<SettingsScreen onClose={onClose} />);

    fireEvent.click(
      await screen.findByRole("button", { name: i18next.t("settings.agents.addCustom") }),
    );
    fireEvent.change(screen.getByLabelText(i18next.t("common.command")), {
      target: { value: "gemini" },
    });
    fireEvent.click(screen.getByRole("button", { name: i18next.t("settings.agents.confirmAdd") }));
    expect(screen.getByText(i18next.t("settings.shell.dirty"))).toBeVisible();

    fireEvent.click(screen.getByRole("button", { name: i18next.t("common.save") }));
    await waitFor(() => expect(saveConfig).toHaveBeenCalledTimes(1));
    const savedAgents = vi.mocked(saveConfig).mock.calls[0][0].agents;
    expect(savedAgents).toHaveLength(2);
    // gemini 没有对应的 introspect 解析器,保持 null。
    expect(savedAgents[1].introspect).toBeNull();
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  // 用户删掉默认的 Claude Code 配置后再手动加回来时,introspect 绑定
  // 必须按命令名自动补上 —— 否则 transcript 历史与 resume 都会失效。
  it("re-adding claude by command restores its introspect binding", async () => {
    render(<SettingsScreen onClose={vi.fn()} />);

    fireEvent.click(
      await screen.findByRole("button", { name: i18next.t("settings.agents.addCustom") }),
    );
    fireEvent.change(screen.getByLabelText(i18next.t("common.command")), {
      target: { value: "claude" },
    });
    fireEvent.click(screen.getByRole("button", { name: i18next.t("settings.agents.confirmAdd") }));

    fireEvent.click(screen.getByRole("button", { name: i18next.t("common.save") }));
    await waitFor(() => expect(saveConfig).toHaveBeenCalledTimes(1));
    const savedAgents = vi.mocked(saveConfig).mock.calls[0][0].agents;
    expect(savedAgents).toHaveLength(2);
    expect(savedAgents[1].command).toBe("claude");
    expect(savedAgents[1].introspect).toBe("claude");
  });
});
