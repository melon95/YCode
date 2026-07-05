import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, render } from "@testing-library/react";
import { useRef } from "react";
import type { PanelImperativeHandle } from "react-resizable-panels";
import { useHotkeys } from "./hotkeys";
import { createSession } from "./ipc";
import { PICKER_SLOT, useStore } from "./store";
import type { ProjectView } from "./types";

vi.mock("@heroui/react", () => ({
  toast: {
    danger: vi.fn(),
    warning: vi.fn(),
  },
}));

vi.mock("./ipc", () => ({
  archiveSession: vi.fn(),
  createSession: vi.fn(),
  listAgents: vi.fn(),
}));

vi.mock("./confirm", () => ({
  confirmDialog: vi.fn(),
}));

const initialState = useStore.getState();

function project(id: string, createdAt: number): ProjectView {
  return {
    id,
    name: id,
    repo_path: `/tmp/${id}`,
    created_at_ms: createdAt,
    session_count: 0,
    isolate_sessions: true,
  };
}

function HotkeyHost() {
  const panel = {
    collapse: vi.fn(),
    expand: vi.fn(),
    isCollapsed: vi.fn(() => false),
  } as unknown as PanelImperativeHandle;
  const sidebarRef = useRef<PanelImperativeHandle | null>(panel);
  const rightPaneRef = useRef<PanelImperativeHandle | null>(panel);
  useHotkeys({
    sidebarRef,
    rightPaneRef,
    openCommandPalette: vi.fn(),
  });
  return null;
}

function press(key: string, opts: Partial<KeyboardEventInit> = {}) {
  window.dispatchEvent(
    new KeyboardEvent("keydown", {
      key,
      metaKey: true,
      bubbles: true,
      cancelable: true,
      ...opts,
    }),
  );
}

describe("useHotkeys", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    localStorage.clear();
    useStore.setState(initialState, true);
  });

  afterEach(() => {
    cleanup();
  });

  it("switches every right-pane tab with command number shortcuts", () => {
    render(<HotkeyHost />);

    press("1");
    expect(useStore.getState().rightTab).toBe("terminal");

    press("2");
    expect(useStore.getState().rightTab).toBe("files");

    press("3");
    expect(useStore.getState().rightTab).toBe("changes");

    press("4");
    expect(useStore.getState().rightTab).toBe("todos");
  });

  it("routes command 2 to the editor when a file is open", () => {
    useStore.setState({ openFiles: ["src/main.ts"] });
    render(<HotkeyHost />);

    press("2");
    expect(useStore.getState().rightTab).toBe("editor");
  });

  it("switches projects with shift command brackets (braces when shifted)", () => {
    const project = (id: string, createdAt: number) => ({
      id,
      name: id,
      repo_path: `/repo/${id}`,
      created_at_ms: createdAt,
      session_count: 0,
      isolate_sessions: true,
    });
    useStore.setState({
      projects: { a: project("a", 1), b: project("b", 2) },
      activeProjectId: "a",
    });
    render(<HotkeyHost />);

    // Shift+] arrives as "}" on macOS/US layouts — next project.
    press("}", { shiftKey: true });
    expect(useStore.getState().activeProjectId).toBe("b");

    // Shift+[ arrives as "{" — previous project (wraps back to a).
    press("{", { shiftKey: true });
    expect(useStore.getState().activeProjectId).toBe("a");
  });

  it("focuses visible agent panes with shift command number shortcuts", () => {
    useStore.setState({
      activeId: "s1",
      layout: {
        mode: "grid2x2",
        visibleIds: ["s1", "s2", "s3", "s4"],
        focusSlot: 0,
      },
    });
    render(<HotkeyHost />);

    press("3", { shiftKey: true });

    expect(useStore.getState().layout.focusSlot).toBe(2);
    expect(useStore.getState().activeId).toBe("s3");
  });

  it("opens the agent picker as a new pane with shift command n", () => {
    useStore.setState({
      activeProjectId: "project-a",
      activeId: "s1",
      layout: {
        mode: "columns",
        visibleIds: ["s1", "s2"],
        focusSlot: 0,
      },
    });
    render(<HotkeyHost />);

    press("n", { shiftKey: true });

    // Existing panes stay; the picker is appended as a new focused slot.
    expect(useStore.getState().layout.visibleIds).toEqual(["s1", "s2", PICKER_SLOT]);
    expect(useStore.getState().layout.focusSlot).toBe(2);
    expect(useStore.getState().activeId).toBeNull();
  });

  it("ignores command n while the agent picker is on screen", () => {
    // Empty project → the fullscreen picker is showing.
    useStore.setState({
      activeProjectId: "project-a",
      layout: { mode: "single", visibleIds: [], focusSlot: 0 },
    });
    render(<HotkeyHost />);

    press("n");
    expect(createSession).not.toHaveBeenCalled();

    // An open ⇧⌘N picker pane should block ⌘N too.
    useStore.setState({
      layout: { mode: "columns", visibleIds: ["s1", PICKER_SLOT], focusSlot: 1 },
    });
    press("n");
    expect(createSession).not.toHaveBeenCalled();
  });

  it("switches projects with shift command brackets", () => {
    useStore.setState({
      projects: {
        "project-a": project("project-a", 1),
        "project-b": project("project-b", 2),
        "project-c": project("project-c", 3),
      },
      activeProjectId: "project-b",
    });
    render(<HotkeyHost />);

    press("]", { shiftKey: true });
    expect(useStore.getState().activeProjectId).toBe("project-c");

    press("[", { shiftKey: true });
    expect(useStore.getState().activeProjectId).toBe("project-b");
  });

  it("dispatches a new-project event with command o", () => {
    const handler = vi.fn();
    window.addEventListener("ycode:new-project", handler);
    render(<HotkeyHost />);

    press("o");

    expect(handler).toHaveBeenCalledTimes(1);
    window.removeEventListener("ycode:new-project", handler);
  });
});
