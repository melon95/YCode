import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen, waitFor, act } from "@testing-library/react";
import { useStore } from "../lib/store";
import type { ProjectView } from "../lib/types";
import { TopBar } from "./TopBar";

vi.mock("@tauri-apps/plugin-dialog", () => ({ open: vi.fn() }));
vi.mock("../lib/ipc", () => ({
  createProject: vi.fn(),
}));

const initialState = useStore.getState();

function project(id: string, createdAt: number): ProjectView {
  return {
    id,
    name: id,
    repo_path: `/tmp/${id}`,
    created_at_ms: createdAt,
    session_count: 0,
    isolate_sessions: false,
  };
}

describe("TopBar global entries", () => {
  beforeEach(() => {
    localStorage.clear();
    useStore.setState(initialState, true);
    useStore.getState().setProjects([project("alpha", 1)]);
  });

  afterEach(cleanup);

  it("renders global entries only — project tabs live in the sidebar now", () => {
    render(<TopBar />);

    // 项目 tab 条已迁入侧边栏。
    expect(document.querySelector(".project-tabs")).toBeNull();
    expect(screen.queryByText("alpha")).not.toBeInTheDocument();
    // 全局入口仍在:打开项目 / 总览 / 搜索 / 设置。
    expect(screen.getByRole("button", { name: "打开项目" })).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "全部项目总览 (⇧⌘P)" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "搜索或执行命令 (⌘K)" }),
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "设置" })).toBeInTheDocument();
  });

  it("dispatches the overview event from the grid button", () => {
    const handler = vi.fn();
    window.addEventListener("ycode:open-overview", handler);
    render(<TopBar />);

    fireEvent.click(screen.getByRole("button", { name: "全部项目总览 (⇧⌘P)" }));
    expect(handler).toHaveBeenCalledTimes(1);
    window.removeEventListener("ycode:open-overview", handler);
  });
});

describe("TopBar auto-hide", () => {
  beforeEach(() => {
    localStorage.clear();
    useStore.setState(initialState, true);
    useStore.getState().setProjects([project("alpha", 1)]);
  });

  afterEach(cleanup);

  it("stays laid out when the setting is off", () => {
    render(<TopBar />);
    const header = document.querySelector(".topbar");
    expect(header).not.toHaveClass("auto-hide");
    expect(header).not.toHaveClass("hidden");
  });

  it("collapses when enabled and reveals on a pointer at the top edge", async () => {
    useStore.getState().setAutoHideTopBar(true);
    render(<TopBar />);
    const header = document.querySelector(".topbar");
    expect(header).toHaveClass("auto-hide");
    expect(header).toHaveClass("hidden");

    // jsdom hands back an all-zero rect, so a move below the reveal zone
    // can't accidentally land "inside" the bar and keep it open.
    fireEvent.pointerMove(window, { clientX: 40, clientY: 2 });
    await waitFor(() => expect(header).not.toHaveClass("hidden"));

    fireEvent.pointerMove(window, { clientX: 40, clientY: 400 });
    await waitFor(() => expect(header).toHaveClass("hidden"));
  });

  it("peeks open on the peek event, then settles back", async () => {
    vi.useFakeTimers();
    useStore.getState().setAutoHideTopBar(true);
    render(<TopBar />);
    const header = document.querySelector(".topbar");
    expect(header).toHaveClass("hidden");

    await act(async () => {
      window.dispatchEvent(new CustomEvent("ycode:peek-topbar"));
    });
    expect(header).not.toHaveClass("hidden");

    await act(async () => {
      vi.advanceTimersByTime(1300);
    });
    expect(header).toHaveClass("hidden");
    vi.useRealTimers();
  });

  it("re-hides immediately when the setting is turned back off", async () => {
    useStore.getState().setAutoHideTopBar(true);
    render(<TopBar />);
    const header = document.querySelector(".topbar");
    fireEvent.pointerMove(window, { clientX: 40, clientY: 2 });
    await waitFor(() => expect(header).not.toHaveClass("hidden"));

    useStore.getState().setAutoHideTopBar(false);
    await waitFor(() => expect(header).not.toHaveClass("auto-hide"));
    expect(header).not.toHaveClass("hidden");
  });
});
