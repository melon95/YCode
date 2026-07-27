import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import type { ConfigView } from "../lib/types";
import { getConfig, saveConfig } from "../lib/ipc";
import { SettingsScreen } from "./SettingsModal";

vi.mock("../lib/ipc", () => ({
  getConfig: vi.fn(),
  resetConfig: vi.fn(),
  saveConfig: vi.fn(),
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

  it("renders as a standalone settings workspace and switches sections", async () => {
    render(<SettingsScreen onClose={vi.fn()} />);

    expect(await screen.findByRole("heading", { name: "Settings" })).toBeVisible();
    expect(screen.getByRole("button", { name: "Back to workspace" })).toBeVisible();
    expect(screen.getByText("1 configured")).toBeVisible();

    fireEvent.click(screen.getByRole("button", { name: "Appearance" }));
    expect(screen.getByText("Appearance panel")).toBeVisible();
  });

  it("stages catalog edits and saves them through the existing config flow", async () => {
    const onClose = vi.fn();
    render(<SettingsScreen onClose={onClose} />);

    fireEvent.click(await screen.findByTitle("Add Gemini CLI"));
    expect(screen.getByText("Unsaved changes")).toBeVisible();

    fireEvent.click(screen.getByRole("button", { name: "Save" }));
    await waitFor(() => expect(saveConfig).toHaveBeenCalledTimes(1));
    expect(vi.mocked(saveConfig).mock.calls[0][0].agents).toHaveLength(2);
    expect(onClose).toHaveBeenCalledTimes(1);
  });
});
