import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { listFiles, searchSessions } from "../lib/ipc";
import { useStore } from "../lib/store";
import type {
  AgentProfileView,
  FileEntry,
  ProjectView,
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

function project(overrides: Partial<ProjectView> = {}): ProjectView {
  return {
    id: "project-a",
    name: "internal-portal-frontend",
    repo_path: "/tmp/project-a",
    created_at_ms: 0,
    session_count: 0,
    isolate_sessions: false,
    ...overrides,
  } as ProjectView;
}

function session(overrides: Partial<SessionView> = {}): SessionView {
  return {
    id: "session-a",
    project_id: "project-a",
    agent_profile: "codex",
    title: "修复登录问题",
    status: { type: "Running" },
    archived_at_ms: null,
    updated_at_ms: 1_700_000_000_000,
    ...overrides,
  } as SessionView;
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
    await user.type(screen.getByRole("textbox", { name: "搜索或执行命令" }), "cmd");
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

    await user.type(screen.getByRole("textbox", { name: "搜索或执行命令" }), ">tree");
    expect(screen.getByRole("textbox", { name: "搜索会话记录" })).toBeInTheDocument();
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
    screen.getByRole("textbox", { name: "搜索或执行命令" }).focus();

    await user.keyboard("{Escape}");

    expect(onClose).toHaveBeenCalledTimes(1);
    expect(onPick).not.toHaveBeenCalled();
  });

  it("shows Chinese status text for empty results and short history queries", async () => {
    const user = userEvent.setup();
    renderPalette();
    const input = screen.getByRole("textbox", { name: "搜索或执行命令" });

    // 默认模式无匹配 → 中文空态,提示可用前缀。
    await user.type(input, "zzzzzz不存在的东西qqq");
    expect(
      await screen.findByText("没有匹配项 —— 试试 > 历史、@ 会话"),
    ).toBeInTheDocument();

    // `>` 历史模式:不足 2 字符的提示也是中文。
    await user.clear(input);
    await user.type(input, ">a");
    expect(
      screen.getByText("至少输入 2 个字符才能搜索历史记录。"),
    ).toBeInTheDocument();
  });

  it("renders the footer hints", () => {
    useStore.setState({ projects: { "project-a": project() } });
    renderPalette();

    expect(screen.getByText("⌘⏎ 在新面板打开")).toBeInTheDocument();
    expect(screen.getByText("> 历史 · @ 会话")).toBeInTheDocument();
  });

  // 作用域标签只在搜索真的被限在当前项目里时出现。空查询的默认视图列的是
  // 全部项目的会话和全部项目本身,那时挂一个项目名是在说谎。
  it("hides the scope tag until the search is actually scoped", async () => {
    const user = userEvent.setup();
    useStore.setState({ projects: { "project-a": project() } });
    renderPalette();
    const input = screen.getByLabelText("搜索或执行命令");

    // 默认视图、空查询 —— 结果跨全部项目。
    expect(screen.queryByText("internal-portal-frontend")).toBeNull();

    // 开始输入:文件匹配参与结果,而文件列表只来自当前项目。
    await user.type(input, "src");
    expect(screen.getByText("internal-portal-frontend")).toBeInTheDocument();

    // `@` 会话列表跨全部项目,标签要重新消失。
    await user.clear(input);
    await user.type(input, "@a");
    expect(screen.queryByText("internal-portal-frontend")).toBeNull();
  });

  it("shows the scope tag in history mode, which is always project-scoped", async () => {
    const user = userEvent.setup();
    useStore.setState({ projects: { "project-a": project() } });
    renderPalette();

    await user.type(screen.getByLabelText("搜索或执行命令"), ">");
    expect(screen.getByText("internal-portal-frontend")).toBeInTheDocument();
  });

  it("opens a session in a new pane on ⌘⏎ instead of replacing the focused slot", async () => {
    const user = userEvent.setup();
    useStore.setState({
      projects: { "project-a": project() },
      sessions: {
        "session-a": session(),
        "session-b": session({
          id: "session-b",
          title: "另一个会话",
          updated_at_ms: 1_600_000_000_000,
        }),
      },
      // replace_focused 模式下普通 ⏎ 会替换当前槽;⌘⏎ 必须仍然新开面板。
      sessionOpenMode: "replace_focused",
      layout: { mode: "single", visibleIds: ["session-b"], focusSlot: 0 },
      activeId: "session-b",
    });
    renderPalette();

    // 空查询下会话组排最前;session-a 更新时间更晚排第一。
    await screen.findByText("修复登录问题");
    screen.getByRole("textbox", { name: "搜索或执行命令" }).focus();
    await user.keyboard("{Meta>}{Enter}{/Meta}");

    const state = useStore.getState();
    expect(state.layout.visibleIds).toEqual(["session-b", "session-a"]);
    expect(state.activeId).toBe("session-a");
  });

  it("filters to the session group with the @ prefix", async () => {
    const user = userEvent.setup();
    useStore.setState({
      projects: { "project-a": project() },
      sessions: { "session-a": session() },
    });
    renderPalette();

    await user.type(screen.getByRole("textbox", { name: "搜索或执行命令" }), "@");
    expect(
      screen.getByRole("textbox", { name: "过滤会话" }),
    ).toBeInTheDocument();
    // 只剩会话组:命令条目消失,会话条目还在。
    expect(screen.getByText("修复登录问题")).toBeInTheDocument();
    expect(screen.queryByText("新建会话")).not.toBeInTheDocument();

    // 继续输入按标题过滤。
    await user.type(
      screen.getByRole("textbox", { name: "过滤会话" }),
      "不存在的标题xyz",
    );
    expect(screen.getByText("没有匹配的会话。")).toBeInTheDocument();
  });

  it("switches the layout to columns via the palette command", async () => {
    const user = userEvent.setup();
    useStore.setState({
      layout: { mode: "stack", visibleIds: ["s1", "s2"], focusSlot: 0 },
    });
    const { onClose } = renderPalette();

    await user.type(
      screen.getByRole("textbox", { name: "搜索或执行命令" }),
      "并排两栏",
    );
    await screen.findByText("切换布局:并排两栏");
    await user.keyboard("{Enter}");

    expect(useStore.getState().layout.mode).toBe("columns");
    expect(onClose).toHaveBeenCalledTimes(1);
  });
});
