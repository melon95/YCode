import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { i18next } from "../lib/i18n";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { PICKER_SLOT, useStore } from "../lib/store";
import type { AgentProfileView, ProjectView, SessionView } from "../lib/types";
import { Sidebar } from "./Sidebar";

vi.mock("../lib/ipc", () => ({
  createSession: vi.fn(),
  listenSessionEvents: vi.fn(async () => () => {}),
  scanWorkspaceSessions: vi.fn(async () => []),
}));

vi.mock("./AgentIcon", () => ({
  AgentIcon: ({ fallbackChar }: { fallbackChar?: string }) => (
    <svg data-agent-icon={fallbackChar} aria-hidden />
  ),
}));

const initialState = useStore.getState();

function agent(id: string, displayName: string): AgentProfileView {
  return {
    id,
    display_name: displayName,
    command: id,
    available: true,
    icon: null,
    icon_variant: null,
    color: null,
    introspect: id,
  };
}

const project: ProjectView = {
  id: "project-a",
  name: "Project A",
  repo_path: "/tmp/project-a",
  created_at_ms: 1,
  session_count: 0,
  isolate_sessions: false,
};

const runningSession: SessionView = {
  id: "session-a",
  title: "Working session",
  agent_profile: "claude",
  agent_session_id: null,
  agent_thread_name: null,
  project_id: project.id,
  status: { type: "Running" },
  created_at_ms: 1,
  updated_at_ms: 1,
  archived_at_ms: null,
  worktree_path: null,
  branch: null,
  base_branch: null,
};

describe("Sidebar agent filter", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    localStorage.clear();
    useStore.setState(initialState, true);
    useStore.setState({
      activeProjectId: project.id,
      projects: { [project.id]: project },
      agents: [agent("claude", "Claude Code"), agent("codex", "Codex")],
      sessions: {},
      activityBySession: {},
    });
  });

  afterEach(cleanup);

  // 过滤器从一行图标 pill 换成了下拉:pill 每多一个 agent 就多占一格
  // 宽度,窄侧栏下会横向滚动。触发器的可访问名字带着当前选中项,所以
  // 「现在筛的是谁」不用打开菜单就能读到。
  it("filters by agent through the dropdown and defaults to ALL", () => {
    render(<Sidebar />);

    const trigger = screen.getByRole("button", {
      name: i18next.t("ui.filterAgentAria", {
        label: i18next.t("ui.allAgents"),
      }),
    });

    fireEvent.click(trigger);
    fireEvent.click(screen.getByRole("button", { name: /Codex/ }));

    expect(
      screen.getByRole("button", {
        name: i18next.t("ui.filterAgentAria", { label: "Codex" }),
      }),
    ).toBeInTheDocument();
  });

  it("keeps the new-session shortcut available even with no sessions yet", () => {
    render(<Sidebar />);

    // The button used to hide whenever the canvas showed the agent picker.
    // It no longer does: it is the fast path (start with the active agent,
    // no picker round-trip), and whether it exists shouldn't depend on what
    // the middle column happens to be rendering.
    expect(
      screen.getByRole("button", { name: i18next.t("sidebar.newSession") }),
    ).toBeInTheDocument();
  });

  it("keeps the shortcut visible for an active session and an added picker pane", () => {
    useStore.setState({
      sessions: { [runningSession.id]: runningSession },
      layout: {
        mode: "single",
        visibleIds: [runningSession.id],
        focusSlot: 0,
      },
    });
    const { rerender } = render(<Sidebar />);

    expect(
      screen.getByRole("button", { name: i18next.t("sidebar.newSession") }),
    ).toBeInTheDocument();

    useStore.setState({
      layout: {
        mode: "stack",
        visibleIds: [runningSession.id, PICKER_SLOT],
        focusSlot: 1,
      },
    });
    rerender(<Sidebar />);

    expect(
      screen.getByRole("button", { name: i18next.t("sidebar.newSession") }),
    ).toBeInTheDocument();
  });
});
