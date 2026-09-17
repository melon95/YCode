import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { i18next } from "../lib/i18n";
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import {
  gitApplyHunk,
  gitBranch,
  gitDiffFile,
  gitStatus,
} from "../lib/ipc";
import { useStore } from "../lib/store";
import type { GitFileChange } from "../lib/types";
import { ChangesPanel } from "./ChangesPanel";

vi.mock("../lib/ipc", () => ({
  gitApplyHunk: vi.fn(),
  gitBranch: vi.fn(),
  gitCommit: vi.fn(),
  gitDiffFile: vi.fn(),
  gitDiscardFile: vi.fn(),
  gitFetch: vi.fn(),
  gitPull: vi.fn(),
  gitPush: vi.fn(),
  gitStageFile: vi.fn(),
  gitStatus: vi.fn(),
  gitUnstageFile: vi.fn(),
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

describe("ChangesPanel working-tree review", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    localStorage.clear();
    useStore.setState(initialState, true);
    vi.mocked(gitStatus).mockResolvedValue([change]);
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
    vi.mocked(gitApplyHunk).mockResolvedValue();
  });

  afterEach(cleanup);

  it("stages only the displayed hunk", async () => {
    const user = userEvent.setup();
    render(
      <ChangesPanel projectId="project-a" sessionId="session-a" />,
    );

    await user.click(await screen.findByRole("button", { name: i18next.t("changes.stageHunk") }));

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
});
