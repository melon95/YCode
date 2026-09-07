// 变更面板「跟随焦点 / 锁定」与卡片头计数的行为测试。
//
// 重型子面板(文件树 / 编辑器 / 终端 / todo)全部 mock 掉 —— 这里只关心
// RightPane 自己的绑定解析逻辑:变更卡片跟随 store.activeId,锁定后固定,
// 无焦点时回落到 workspace 手选目标;以及 count/actions 两个卡片头插槽。

import { cleanup, render, screen, waitFor } from "@testing-library/react";
import { i18next } from "../lib/i18n";
import userEvent from "@testing-library/user-event";
import { act, useEffect } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useStore } from "../lib/store";
import type { ProjectView, SessionView, TodoView } from "../lib/types";
import { RightPane } from "./RightPane";

vi.mock("./FileTreePanel", () => ({ FileTreePanel: () => <div /> }));
vi.mock("./EditorPanel", () => ({ EditorPanel: () => <div /> }));
vi.mock("./TodoPanel", () => ({ TodoPanel: () => <div /> }));
vi.mock("./WorkspaceTargetPicker", () => ({
  WorkspaceTargetPicker: () => <div />,
}));
vi.mock("./RightTerminalSplit", async () => {
  const real = await vi.importActual<object>("./RightTerminalSplit");
  return { ...real, RightTerminalSplit: () => <div /> };
});
// ChangesPanel 桩:回显收到的 sessionId,并上报一个固定的文件数,
// 这样测试既能断言绑定目标,也能断言 count 插槽的渲染。真组件在
// effect 里上报,这里保持一致(渲染期间写 store 会触发 React 告警)。
vi.mock("./ChangesPanel", () => ({
  ChangesPanel: ({
    sessionId,
    onFileCount,
  }: {
    sessionId?: string;
    onFileCount?: (n: number) => void;
  }) => {
    useEffect(() => {
      onFileCount?.(3);
    }, [onFileCount]);
    return <div data-testid="changes-panel">target:{sessionId ?? "main"}</div>;
  },
}));

const initialState = useStore.getState();

function project(id: string): ProjectView {
  return {
    id,
    name: id,
    repo_path: `/tmp/${id}`,
    created_at_ms: 1,
    session_count: 0,
    isolate_sessions: true,
  };
}

function session(
  id: string,
  projectId: string,
  worktree: boolean,
): SessionView {
  return {
    id,
    title: `会话 ${id}`,
    agent_profile: "claude-code",
    agent_session_id: null,
    agent_thread_name: null,
    project_id: projectId,
    status: { type: "Running" },
    created_at_ms: 1,
    updated_at_ms: 1,
    archived_at_ms: null,
    worktree_path: worktree ? `/tmp/wt/${id}` : null,
    branch: worktree ? `ycode/${id}` : null,
    base_branch: worktree ? "main" : null,
  };
}

function todo(id: string, status: string): TodoView {
  return {
    id,
    project_id: "p1",
    title: id,
    status,
    sort_order: 0,
    started_at_ms: null,
    done_at_ms: null,
    created_at_ms: 1,
    updated_at_ms: 1,
  };
}

function seedStore() {
  useStore.setState(initialState, true);
  useStore.setState({
    projects: { p1: project("p1"), p2: project("p2") },
    sessions: {
      s1: session("s1", "p1", true),
      s2: session("s2", "p1", true),
      other: session("other", "p2", true),
    },
    activeProjectId: "p1",
    openPanels: ["changes", "todos"],
    // 手选目标(右栏 target picker):s2 的 worktree。
    workspaceSessionByProject: { p1: "s2" },
    // 中栏焦点:s1。
    layout: { mode: "columns", visibleIds: ["s1", "s2"], focusSlot: 0 },
    activeId: "s1",
    todos: { p1: [todo("a", "todo"), todo("b", "doing"), todo("c", "done")] },
  });
}

describe("RightPane 变更面板绑定", () => {
  beforeEach(() => {
    localStorage.clear();
    seedStore();
  });
  afterEach(() => {
    cleanup();
    vi.clearAllMocks();
  });

  it("默认跟随中栏焦点会话(activeId),chip 显示其分支", () => {
    render(<RightPane />);
    expect(screen.getByTestId("changes-panel")).toHaveTextContent("target:s1");
    expect(screen.getAllByText("ycode/s1").length).toBeGreaterThan(0);
  });

  it("焦点切换时变更面板跟着切", () => {
    render(<RightPane />);
    act(() => {
      useStore.getState().focusLayoutSlot(1);
    });
    expect(screen.getByTestId("changes-panel")).toHaveTextContent("target:s2");
    // 文件卡与变更卡的 chip 都显示 checked-out 分支,同名出现两次是预期。
    expect(screen.getAllByText("ycode/s2").length).toBeGreaterThan(0);
  });

  it("无焦点会话时回落到 workspace 手选目标", () => {
    act(() => {
      useStore.setState({ activeId: null });
    });
    render(<RightPane />);
    expect(screen.getByTestId("changes-panel")).toHaveTextContent("target:s2");
  });

  it("焦点会话属于别的项目时也回落到手选目标", () => {
    act(() => {
      useStore.setState({ activeId: "other" });
    });
    render(<RightPane />);
    expect(screen.getByTestId("changes-panel")).toHaveTextContent("target:s2");
  });

  it("锁定后不再跟随焦点;解锁后恢复跟随", async () => {
    const user = userEvent.setup();
    render(<RightPane />);
    // 锁定在当前跟随目标 s1 上。
    await user.click(
      screen.getByRole("button", { name: i18next.t("panels.lockAria") }),
    );
    act(() => {
      useStore.getState().focusLayoutSlot(1); // 焦点 → s2
    });
    // 仍固定在 s1。
    expect(screen.getByTestId("changes-panel")).toHaveTextContent("target:s1");
    expect(
      screen.getByRole("button", { name: i18next.t("panels.unlockAria") }),
    ).toHaveAttribute("aria-pressed", "true");
    // 解锁 → 恢复跟随,立刻切到焦点会话 s2。
    await user.click(
      screen.getByRole("button", { name: i18next.t("panels.unlockAria") }),
    );
    expect(screen.getByTestId("changes-panel")).toHaveTextContent("target:s2");
  });

  it("锁定的会话被移除后自动失效,回到跟随逻辑", () => {
    render(<RightPane />);
    // 焦点默认在 s1;点击锁定即锁在 s1 上。
    const btn = screen.getByRole("button", { name: i18next.t("panels.lockAria") });
    act(() => {
      btn.click();
    });
    act(() => {
      useStore.getState().removeSession("s1");
      useStore.setState({ activeId: null });
    });
    // s1 没了、锁定失效、无焦点 → 回落到手选 s2。
    expect(screen.getByTestId("changes-panel")).toHaveTextContent("target:s2");
  });
});

describe("RightPane 卡片头计数", () => {
  beforeEach(() => {
    localStorage.clear();
    seedStore();
  });
  afterEach(() => {
    cleanup();
    vi.clearAllMocks();
  });

  it("变更卡片显示 diff 文件数(ChangesPanel 经 onFileCount 上报)", async () => {
    render(<RightPane />);
    await waitFor(() =>
      expect(screen.getByText(i18next.t("panels.fileCount", { count: 3 }))).toBeInTheDocument(),
    );
    // 工具条角标共用的 store 字段也被写入。
    expect(useStore.getState().changesFileCount).toBe(3);
  });

  it("待办卡片显示未完成 todo 数(不含 done)", () => {
    render(<RightPane />);
    const todosCard = screen.getByRole("region", { name: i18next.t("panels.todos") });
    expect(todosCard.querySelector(".pcard-count")).toHaveTextContent("2");
  });

  it("变更面板关闭后清空共享的文件数(角标随之消失)", async () => {
    render(<RightPane />);
    await waitFor(() =>
      expect(useStore.getState().changesFileCount).toBe(3),
    );
    act(() => {
      useStore.getState().togglePanelOpen("changes");
    });
    await waitFor(() =>
      expect(useStore.getState().changesFileCount).toBeNull(),
    );
  });
});
