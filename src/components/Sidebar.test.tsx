import { cleanup, fireEvent, render, screen } from "@testing-library/react";
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

  it("renders the agent switcher as icon-only tabs and keeps filtering accessible", () => {
    render(<Sidebar />);

    const claudeTab = screen.getByRole("tab", { name: "Claude Code" });
    const codexTab = screen.getByRole("tab", { name: "Codex" });

    expect(claudeTab).toHaveAttribute("aria-selected", "true");
    expect(claudeTab.querySelector("[data-agent-icon='Claude Code']")).not.toBeNull();
    expect(claudeTab.querySelector(".sidebar-agent-name")).toBeNull();
    expect(claudeTab.querySelector(".sidebar-agent-status")).toBeNull();

    fireEvent.click(codexTab);

    expect(codexTab).toHaveAttribute("aria-selected", "true");
    expect(screen.getByText("Codex")).toHaveClass("sidebar-section-context");
  });

  it("hides the shortcut while the main new-session picker is visible", () => {
    render(<Sidebar />);

    expect(
      screen.queryByRole("button", { name: "New Claude Code" }),
    ).not.toBeInTheDocument();
  });

  it("shows the shortcut for an active session and hides it for an added picker pane", () => {
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
      screen.getByRole("button", { name: "New Claude Code" }),
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
      screen.queryByRole("button", { name: "New Claude Code" }),
    ).not.toBeInTheDocument();
  });
});
