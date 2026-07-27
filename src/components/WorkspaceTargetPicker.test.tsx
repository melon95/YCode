import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { toast } from "@heroui/react";
import { useStore } from "../lib/store";
import type { SessionView } from "../lib/types";
import { WorkspaceTargetPicker } from "./WorkspaceTargetPicker";

vi.mock("@heroui/react", () => ({
  toast: { warning: vi.fn() },
}));

const initialState = useStore.getState();
const warningMock = vi.mocked(toast.warning);

function worktreeSession(): SessionView {
  return {
    id: "session-a",
    title: "Workspace task",
    agent_profile: "shell-test",
    agent_session_id: null,
    agent_thread_name: null,
    project_id: "project-a",
    status: { type: "Running" },
    created_at_ms: 1,
    updated_at_ms: 2,
    archived_at_ms: null,
    worktree_path: "/tmp/project-a-worktree",
    branch: "ycode/workspace-task",
    base_branch: "main",
  };
}

describe("WorkspaceTargetPicker", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    localStorage.clear();
    useStore.setState(initialState, true);
    useStore.getState().setSessions([worktreeSession()]);
  });

  afterEach(cleanup);

  it("keeps the control compact without a redundant workspace prefix", () => {
    render(<WorkspaceTargetPicker projectId="project-a" />);

    expect(screen.queryByText("Workspace")).toBeNull();
    expect(
      screen.getByRole("combobox", { name: "Workspace target" }),
    ).toHaveDisplayValue("Main checkout");
  });

  it("switches the shared workspace target", async () => {
    const user = userEvent.setup();
    render(<WorkspaceTargetPicker projectId="project-a" />);

    await user.selectOptions(
      screen.getByRole("combobox", { name: "Workspace target" }),
      "session-a",
    );

    expect(useStore.getState().workspaceSessionByProject["project-a"]).toBe(
      "session-a",
    );
  });

  it("keeps the current target while an editor buffer is dirty", async () => {
    const user = userEvent.setup();
    // The dirty guard only considers the *viewed* project's buffers, so this
    // project has to be the active one for its edits to block the switch.
    useStore.setState({ activeProjectId: "project-a" });
    useStore.getState().setWorkspaceSessionId("project-a", "session-a");
    useStore.getState().setFileDirty("src/app.ts", true);
    render(<WorkspaceTargetPicker projectId="project-a" />);

    await user.selectOptions(
      screen.getByRole("combobox", { name: "Workspace target" }),
      "",
    );

    expect(useStore.getState().workspaceSessionByProject["project-a"]).toBe(
      "session-a",
    );
    expect(warningMock).toHaveBeenCalledTimes(1);
  });

  it("is not blocked by unsaved edits belonging to another project", async () => {
    const user = userEvent.setup();
    // `dirtyFiles` holds the *active* project's buffers. A different project
    // being mid-edit must not freeze this project's workspace switcher.
    useStore.setState({ activeProjectId: "project-b" });
    useStore.getState().setFileDirty("src/other-project.ts", true);
    render(<WorkspaceTargetPicker projectId="project-a" />);

    await user.selectOptions(
      screen.getByRole("combobox", { name: "Workspace target" }),
      "session-a",
    );

    expect(useStore.getState().workspaceSessionByProject["project-a"]).toBe(
      "session-a",
    );
    expect(warningMock).not.toHaveBeenCalled();
  });
});
