import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { listFiles, searchSessions } from "../lib/ipc";
import { useStore } from "../lib/store";
import type {
  AgentProfileView,
  FileEntry,
  SearchHit,
  SessionView,
} from "../lib/types";
import { CommandPalette } from "./CommandPalette";

vi.mock("../lib/ipc", () => ({
  listFiles: vi.fn(),
  searchSessions: vi.fn(),
}));

vi.mock("./AgentIcon", () => ({
  AgentIcon: ({ fallbackChar }: { fallbackChar?: string }) => (
    <span aria-hidden>{fallbackChar?.slice(0, 1) ?? "?"}</span>
  ),
}));

const listFilesMock = vi.mocked(listFiles);
const searchSessionsMock = vi.mocked(searchSessions);
const initialState = useStore.getState();

function file(path: string, isDir = false): FileEntry {
  return {
    path,
    is_dir: isDir,
    size: null,
    modified_at_ms: null,
  } as FileEntry;
}

function agent(overrides: Partial<AgentProfileView> = {}): AgentProfileView {
  return {
    id: "codex",
    display_name: "Codex",
    command: "codex",
    args: [],
    env: {},
    icon: null,
    icon_variant: null,
    introspect: "codex",
    available: true,
    version: null,
    cwd: null,
    bundled: false,
    ...overrides,
  } as AgentProfileView;
}

function searchHit(overrides: Partial<SearchHit> = {}): SearchHit {
  return {
    agent: "codex",
    session_id: "session-123456789",
    jsonl_path: "/tmp/codex.jsonl",
    seq: 7,
    ts_ms: 1_700_000_000_000,
    role: "assistant",
    preview: "Implemented the file tree",
    ...overrides,
  } as SearchHit;
}

function renderPalette(props: Partial<Parameters<typeof CommandPalette>[0]> = {}) {
  const onClose = vi.fn();
  const onPick = vi.fn();
  render(
    <CommandPalette
      open
      onClose={onClose}
      onPick={onPick}
      {...props}
    />,
  );
  return { onClose, onPick };
}

describe("CommandPalette", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    localStorage.clear();
    useStore.setState(initialState, true);
    useStore.setState({
      activeProjectId: "project-a",
      agents: [agent()],
    });
    listFilesMock.mockResolvedValue([
      file("src/components/CommandPalette.tsx"),
      file("src/components", true),
      file("README.md"),
    ]);
  });

  afterEach(() => {
    vi.useRealTimers();
    cleanup();
  });

  it("opens the selected file in preview mode and switches to the editor tab", async () => {
    const user = userEvent.setup();
    const { onClose } = renderPalette();

    await waitFor(() =>
      expect(listFilesMock).toHaveBeenCalledWith("project-a", undefined),
    );
    await user.type(screen.getByRole("textbox", { name: "Search files" }), "cmd");
    await user.keyboard("{Enter}");

    const state = useStore.getState();
    expect(state.openFiles).toEqual(["src/components/CommandPalette.tsx"]);
    expect(state.selectedFilePath).toBe("src/components/CommandPalette.tsx");
    expect(state.previewFilePath).toBe("src/components/CommandPalette.tsx");
    expect(state.rightTab).toBe("editor");
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("loads files from the selected workspace checkout", async () => {
    useStore.setState({
      workspaceSessionByProject: { "project-a": "session-a" },
      sessions: {
        "session-a": {
          id: "session-a",
          project_id: "project-a",
          worktree_path: "/tmp/project-a-worktree",
        } as SessionView,
      },
    });

    renderPalette();

    await waitFor(() =>
      expect(listFilesMock).toHaveBeenCalledWith("project-a", "session-a"),
    );
  });

  it("debounces session history search and returns the picked hit", async () => {
    const user = userEvent.setup();
    const hit = searchHit();
    searchSessionsMock.mockResolvedValue([hit]);
    const { onClose, onPick } = renderPalette();

    await user.type(screen.getByRole("textbox", { name: "Search files" }), ">tree");
    expect(screen.getByRole("textbox", { name: "Search sessions" })).toBeInTheDocument();
    expect(searchSessionsMock).not.toHaveBeenCalled();

    await waitFor(() =>
      expect(searchSessionsMock).toHaveBeenCalledWith("project-a", "tree", 50),
    );
    await screen.findByText("Implemented the file tree");
    await user.keyboard("{Enter}");

    expect(onPick).toHaveBeenCalledWith(hit);
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("closes on escape without selecting a hit", async () => {
    const user = userEvent.setup();
    const { onClose, onPick } = renderPalette();
    screen.getByRole("textbox", { name: "Search files" }).focus();

    await user.keyboard("{Escape}");

    expect(onClose).toHaveBeenCalledTimes(1);
    expect(onPick).not.toHaveBeenCalled();
  });
});
