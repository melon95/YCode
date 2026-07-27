import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import {
  gitApplyHunk,
  gitBranch,
  gitBranchDiffFile,
  gitBranchStatus,
  gitCheckpointDiffFile,
  gitCheckpointStatus,
  gitDiffFile,
  gitStatus,
  listReviewCheckpoints,
  listenSessionEvents,
} from "../lib/ipc";
import { useStore } from "../lib/store";
import type { GitFileChange } from "../lib/types";
import { ChangesPanel } from "./ChangesPanel";

vi.mock("../lib/ipc", () => ({
  gitApplyHunk: vi.fn(),
  gitBranch: vi.fn(),
  gitBranchDiffFile: vi.fn(),
  gitBranchStatus: vi.fn(),
  gitCheckpointDiffFile: vi.fn(),
  gitCheckpointStatus: vi.fn(),
  gitCheckoutBranch: vi.fn(),
  gitCommit: vi.fn(),
  gitDiffFile: vi.fn(),
  gitDiscardFile: vi.fn(),
  gitFetch: vi.fn(),
  gitListBranches: vi.fn(),
  gitPull: vi.fn(),
  gitPush: vi.fn(),
  gitStageFile: vi.fn(),
  gitStatus: vi.fn(),
  gitUnstageFile: vi.fn(),
  listReviewCheckpoints: vi.fn(),
  listenSessionEvents: vi.fn(),
}));

vi.mock("../lib/confirm", () => ({
  confirmDialog: vi.fn().mockResolvedValue(true),
}));

const PATCH = `diff --git a/src/app.ts b/src/app.ts
index 1111111..2222222 100644
--- a/src/app.ts
+++ b/src/app.ts
@@ -1 +1 @@
-old
+new
`;

const change: GitFileChange = {
  path: "src/app.ts",
  status: "modified",
  additions: 1,
  deletions: 1,
  staged: false,
};

const initialState = useStore.getState();

describe("ChangesPanel review workflow", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    localStorage.clear();
    useStore.setState(initialState, true);
    vi.mocked(gitStatus).mockResolvedValue([change]);
    vi.mocked(gitBranchStatus).mockResolvedValue([change]);
    vi.mocked(gitBranch).mockResolvedValue({
      head: "ycode/review",
      detached: false,
      upstream: null,
      ahead: 1,
      behind: 0,
    });
    vi.mocked(gitDiffFile).mockResolvedValue({
      patch: PATCH,
      source: "unstaged",
    });
    vi.mocked(gitBranchDiffFile).mockResolvedValue({
      patch: PATCH,
      source: "branch",
    });
    vi.mocked(gitCheckpointStatus).mockResolvedValue([change]);
    vi.mocked(gitCheckpointDiffFile).mockResolvedValue({
      patch: PATCH,
      source: "checkpoint",
    });
    vi.mocked(listReviewCheckpoints).mockResolvedValue([]);
    vi.mocked(listenSessionEvents).mockResolvedValue(vi.fn());
    vi.mocked(gitApplyHunk).mockResolvedValue();
  });

  afterEach(cleanup);

  it("stages only the displayed hunk in working-tree scope", async () => {
    const user = userEvent.setup();
    render(
      <ChangesPanel projectId="project-a" sessionId="session-a" baseBranch="main" />,
    );

    await user.click(await screen.findByRole("button", { name: "Stage hunk" }));

    await waitFor(() =>
      expect(gitApplyHunk).toHaveBeenCalledWith(
        "project-a",
        "src/app.ts",
        expect.stringContaining("@@ -1 +1 @@"),
        "stage",
        "session-a",
      ),
    );
  });

  it("switches to a read-only branch-vs-base review", async () => {
    const user = userEvent.setup();
    render(
      <ChangesPanel projectId="project-a" sessionId="session-a" baseBranch="main" />,
    );

    await user.click(
      screen.getByRole("tab", { name: "Branch vs base" }),
    );

    await waitFor(() =>
      expect(gitBranchStatus).toHaveBeenCalledWith("project-a", "session-a"),
    );
    expect(await screen.findByText("Committed change")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Stage hunk" })).toBeNull();
  });

  it("reviews a completed agent turn without exposing working-tree actions", async () => {
    vi.mocked(listReviewCheckpoints).mockResolvedValue([
      {
        id: "checkpoint-1",
        session_id: "session-a",
        session_title: "Polish review flow",
        agent_profile: "codex",
        sequence: 1,
        kind: "turn",
        source: "codex",
        event_kind: "turn_complete",
        body_preview: "Finished the review flow",
        created_at_ms: 1_721_332_800_000,
        has_previous: true,
      },
    ]);
    const user = userEvent.setup();
    render(
      <ChangesPanel projectId="project-a" sessionId="session-a" baseBranch="main" />,
    );

    const agentTurnTab = screen.getByRole("tab", { name: "Agent turn" });
    await waitFor(() => expect(agentTurnTab).toBeEnabled());
    await user.click(agentTurnTab);

    await waitFor(() =>
      expect(gitCheckpointStatus).toHaveBeenCalledWith(
        "project-a",
        "checkpoint-1",
      ),
    );
    await waitFor(() =>
      expect(gitCheckpointDiffFile).toHaveBeenCalledWith(
        "project-a",
        "checkpoint-1",
        "src/app.ts",
      ),
    );
    expect(await screen.findByText("Turn snapshot")).toBeInTheDocument();
    expect(screen.getByLabelText("Agent turn snapshot")).toHaveValue(
      "checkpoint-1",
    );
    expect(screen.queryByRole("button", { name: "Stage hunk" })).toBeNull();
    expect(screen.queryByLabelText("Commit message")).toBeNull();
  });
});
