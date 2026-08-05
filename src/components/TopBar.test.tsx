import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { useStore } from "../lib/store";
import type { ProjectView } from "../lib/types";
import { TopBar } from "./TopBar";

vi.mock("@tauri-apps/plugin-dialog", () => ({ open: vi.fn() }));
vi.mock("../lib/ipc", () => ({
  createProject: vi.fn(),
  createSession: vi.fn(),
  deleteProject: vi.fn(),
  listAgents: vi.fn(),
}));
vi.mock("../lib/confirm", () => ({ confirmDialog: vi.fn() }));
vi.mock("../lib/multiWindow", () => ({ openProjectInNewWindow: vi.fn() }));
vi.mock("./LayoutSwitcher", () => ({ LayoutSwitcher: () => null }));
vi.mock("./ContextMenu", () => ({ ContextMenu: () => null }));

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

describe("TopBar project reorder", () => {
  beforeEach(() => {
    localStorage.clear();
    useStore.setState(initialState, true);
    useStore.getState().setProjects([
      project("alpha", 1),
      project("beta", 2),
      project("gamma", 3),
    ]);
  });

  afterEach(cleanup);

  it("starts with project tabs instead of a product brand block", () => {
    render(<TopBar />);

    expect(screen.queryByLabelText("ycode workspace")).not.toBeInTheDocument();
    expect(document.querySelector(".topbar-brand")).toBeNull();
    expect(screen.getByText("alpha")).toBeInTheDocument();
  });

  it("moves a project after the tab whose right half receives the drop", async () => {
    render(<TopBar />);
    const source = screen.getByText("alpha");
    const targetName = screen.getByText("gamma");
    const target = targetName.closest(".project-tab");
    expect(target).not.toBeNull();
    Object.defineProperty(target, "getBoundingClientRect", {
      value: () => ({ left: 0, width: 100 }),
    });
    const originalElementFromPoint = document.elementFromPoint;
    document.elementFromPoint = vi.fn(() => target);

    fireEvent.pointerDown(source, {
      button: 0,
      pointerId: 1,
      clientX: 10,
      clientY: 10,
    });
    fireEvent.pointerMove(source, {
      pointerId: 1,
      clientX: 80,
      clientY: 10,
    });
    expect(target).toHaveClass("drop-after");
    fireEvent.pointerUp(source, {
      pointerId: 1,
      clientX: 80,
      clientY: 10,
    });
    document.elementFromPoint = originalElementFromPoint;

    await waitFor(() =>
      expect(useStore.getState().projectOrder).toEqual([
        "beta",
        "gamma",
        "alpha",
      ]),
    );
    expect(
      screen
        .getAllByTitle(/^Drag to reorder/)
        .map((element) => element.textContent),
    ).toEqual(["beta", "gamma", "alpha"]);
  });

  it("does not reorder when the pointer gesture is cancelled", () => {
    render(<TopBar />);
    const source = screen.getByText("alpha");
    const target = screen.getByText("gamma").closest(".project-tab");
    expect(target).not.toBeNull();
    Object.defineProperty(target, "getBoundingClientRect", {
      value: () => ({ left: 0, width: 100 }),
    });
    const originalElementFromPoint = document.elementFromPoint;
    document.elementFromPoint = vi.fn(() => target);

    fireEvent.pointerDown(source, {
      button: 0,
      pointerId: 1,
      clientX: 10,
      clientY: 10,
    });
    fireEvent.pointerMove(source, {
      pointerId: 1,
      clientX: 80,
      clientY: 10,
    });
    fireEvent.pointerCancel(source, { pointerId: 1 });
    document.elementFromPoint = originalElementFromPoint;

    expect(useStore.getState().projectOrder).toEqual([
      "alpha",
      "beta",
      "gamma",
    ]);
    expect(target).not.toHaveClass("drop-after");
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

  it("peeks open on a keyboard project switch, then settles back", async () => {
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
