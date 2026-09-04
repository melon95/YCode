import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { UserEvent } from "@testing-library/user-event";
import { listFiles } from "../lib/ipc";
import { useStore } from "../lib/store";
import type {
  AgentProfileView,
  FileEntry,
  ProjectView,
  SessionView,
} from "../lib/types";
import { CommandPalette } from "./CommandPalette";

vi.mock("../lib/ipc", () => ({
  listFiles: vi.fn(),
}));

vi.mock("./AgentIcon", () => ({
  AgentIcon: ({ fallbackChar }: { fallbackChar?: string }) => (
    <span aria-hidden>{fallbackChar?.slice(0, 1) ?? "?"}</span>
  ),
}));

const listFilesMock = vi.mocked(listFiles);
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

function renderPalette(props: Partial<Parameters<typeof CommandPalette>[0]> = {}) {
  const onClose = vi.fn();
  render(<CommandPalette open onClose={onClose} {...props} />);
  return { onClose };
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

  it("closes on escape without selecting a hit", async () => {
    const user = userEvent.setup();
    const { onClose } = renderPalette();
    screen.getByRole("textbox", { name: "搜索或执行命令" }).focus();

    await user.keyboard("{Escape}");

    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("shows Chinese status text for empty results", async () => {
    const user = userEvent.setup();
    renderPalette();
    const input = screen.getByRole("textbox", { name: "搜索或执行命令" });

    // 默认模式无匹配 → 中文空态,提示可用前缀。
    await user.type(input, "zzzzzz不存在的东西qqq");
    expect(
      await screen.findByText("没有匹配项 —— 试试 @ 只看会话"),
    ).toBeInTheDocument();

    // `@` 模式的空态。
    await user.clear(input);
    await user.type(input, "@zzzz不存在qqq");
    expect(screen.getByText("没有匹配的会话。")).toBeInTheDocument();
  });

  it("renders the footer hints", () => {
    useStore.setState({ projects: { "project-a": project() } });
    renderPalette();

    expect(screen.getByText("↑↓ 选择")).toBeInTheDocument();
    expect(screen.getByText("@ 只看会话")).toBeInTheDocument();
  });

  // ⌘⏎ 只对会话条目有意义 —— 别的条目按了会回落成普通 ⏎。常驻一条按下去
  // 没反应的提示比不提示更糟,所以它跟着选中项走。
  it("shows the ⌘⏎ hint only while a session row is selected", async () => {
    const user = userEvent.setup();
    useStore.setState({
      projects: { "project-a": project(), "project-b": project({ id: "project-b", name: "另一个项目" }) },
      sessions: { "session-a": session() },
    });
    renderPalette();

    // 第一行是会话 —— 会话是唯一提供 runNewPane 的条目。
    expect(screen.getByText("⌘⏎ 在新面板打开")).toBeInTheDocument();

    // 移到项目行,提示要消失。
    await user.click(screen.getByLabelText("搜索或执行命令"));
    await user.keyboard("{ArrowDown}");
    expect(screen.queryByText("⌘⏎ 在新面板打开")).toBeNull();
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

  // 回归防线:文件行的基础 class 串一度同时写着 `bg-transparent`,而它在
  // 生成的样式表里排在 `bg-panel-raised` 之后、特异性又相同,于是把键盘选中
  // 的底色整个压掉了 —— 上下移动时只有图标那个自带底色的小方块在变,整行
  // 不着色;鼠标 hover 因为带伪类、特异性更高反而正常。两者不能共存。
  /// 命令/会话行(action)与文件行是两条独立的渲染分支,各自拼各自的
  /// class 串 —— 只测一条,另一条坏了照样绿。第一次修复就漏了 action 行。
  async function expectHighlightFollowsArrowKeys(user: UserEvent) {
    // 方向键挂在 input 的 onKeyDown 上,焦点必须在那儿。真实使用里
    // 面板一打开就自动聚焦,jsdom 里要自己点一下。
    await user.click(screen.getByLabelText("搜索或执行命令"));
    const rows = await screen.findAllByRole("option");
    expect(rows.length).toBeGreaterThan(1);

    expect(rows[0]).toHaveAttribute("aria-selected", "true");
    expect(rows[0].className).toContain("bg-panel-raised");
    expect(rows[0].className).not.toContain("bg-transparent");

    // 移开之后底色要交回去,不能两行同时亮着。
    await user.keyboard("{ArrowDown}");
    expect(rows[0]).toHaveAttribute("aria-selected", "false");
    expect(rows[0].className).toContain("bg-transparent");
    expect(rows[1]).toHaveAttribute("aria-selected", "true");
    expect(rows[1].className).toContain("bg-panel-raised");
  }

  it("moves the row highlight with the arrow keys — action rows", async () => {
    const user = userEvent.setup();
    // 空查询的默认视图就是会话/项目/命令这些 action 行。
    useStore.setState({
      projects: { "project-a": project() },
      sessions: {
        "session-a": session(),
        "session-b": session({ id: "session-b", title: "另一个会话" }),
      },
    });
    renderPalette();

    await expectHighlightFollowsArrowKeys(user);
  });

  it("moves the row highlight with the arrow keys — file rows", async () => {
    const user = userEvent.setup();
    renderPalette();
    await waitFor(() => expect(listFilesMock).toHaveBeenCalled());
    // 两个结果都能匹配 —— 需要至少两行才能验证高亮会移走。
    await user.type(screen.getByLabelText("搜索或执行命令"), "e");

    await expectHighlightFollowsArrowKeys(user);
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
