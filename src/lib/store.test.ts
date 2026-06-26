import { beforeEach, describe, expect, it } from "vitest";
import {
  DEFAULT_FONT_SIZES,
  displaySessionTitle,
  useStore,
} from "./store";
import type { SessionView } from "./types";

const initialState = useStore.getState();

function session(
  id: string,
  projectId = "project-a",
  status: SessionView["status"] = { type: "Running" },
): SessionView {
  return {
    id,
    title: "",
    agent_profile: "shell-test",
    agent_session_id: null,
    agent_thread_name: null,
    project_id: projectId,
    status,
    created_at_ms: 1,
    updated_at_ms: 1,
    archived_at_ms: null,
  };
}

function state() {
  return useStore.getState();
}

describe("layout store", () => {
  beforeEach(() => {
    localStorage.clear();
    useStore.setState(initialState, true);
  });

  it("appends sessions until the layout cap and focuses the newest pane", () => {
    state().appendSessionToLayout("s1");
    state().appendSessionToLayout("s2");
    state().appendSessionToLayout("s3");
    state().appendSessionToLayout("s4");
    state().appendSessionToLayout("s5");

    expect(state().layout.visibleIds).toEqual(["s1", "s2", "s3", "s5"]);
    expect(state().layout.focusSlot).toBe(3);
    expect(state().layout.mode).toBe("stack");
    expect(state().activeId).toBe("s5");
  });

  it("reuses a focused exited session slot when opening a new session", () => {
    state().setSessions([
      session("running"),
      session("exited", "project-a", { type: "Exited", code: 0 }),
    ]);
    state().appendSessionToLayout("running");
    state().appendSessionToLayout("exited");

    state().openSessionInLayout("replacement");

    expect(state().layout.visibleIds).toEqual(["running", "replacement"]);
    expect(state().layout.focusSlot).toBe(1);
    expect(state().activeId).toBe("replacement");
  });

  it("shows the new-session picker without removing sessions", () => {
    state().setSessions([session("s1"), session("s2")]);
    state().appendSessionToLayout("s1");
    state().appendSessionToLayout("s2");

    state().showNewSessionPicker();

    expect(state().layout.visibleIds).toEqual([]);
    expect(state().activeId).toBeNull();
    expect(Object.keys(state().sessions).sort()).toEqual(["s1", "s2"]);
  });

  it("resets editor and layout state when switching projects", () => {
    state().setSessions([
      { ...session("a1", "project-a"), updated_at_ms: 10 },
      { ...session("b1", "project-b"), updated_at_ms: 20 },
    ]);
    state().setActiveProjectId("project-a");
    state().openFile("src/a.ts");
    state().setFileDirty("src/a.ts", true);

    state().setActiveProjectId("project-b");

    expect(state().activeId).toBe("b1");
    expect(state().layout.visibleIds).toEqual(["b1"]);
    expect(state().openFiles).toEqual([]);
    expect(state().dirtyFiles).toEqual({});
    expect(state().previewFilePath).toBeNull();
  });

  it("restores each project's terminal layout when switching back", () => {
    state().setSessions([
      { ...session("a1", "project-a"), updated_at_ms: 10 },
      { ...session("a2", "project-a"), updated_at_ms: 20 },
      { ...session("b1", "project-b"), updated_at_ms: 30 },
    ]);

    state().setActiveProjectId("project-a");
    state().appendSessionToLayout("a1");
    state().appendSessionToLayout("a2");
    state().setLayoutMode("columns");
    const projectALayout = state().layout;
    const projectAActiveId = state().activeId;

    state().setActiveProjectId("project-b");

    expect(state().layout.visibleIds).toEqual(["b1"]);

    state().setActiveProjectId("project-a");

    expect(state().layout).toEqual(projectALayout);
    expect(state().activeId).toBe(projectAActiveId);
  });
});

describe("editor tab store", () => {
  beforeEach(() => {
    useStore.setState(initialState, true);
  });

  it("reuses the preview tab and clears stale dirty state", () => {
    state().openFile("src/one.ts", { preview: true });
    state().openFile("src/two.ts", { preview: true });

    expect(state().openFiles).toEqual(["src/two.ts"]);
    expect(state().selectedFilePath).toBe("src/two.ts");
    expect(state().previewFilePath).toBe("src/two.ts");
    expect(state().dirtyFiles).toEqual({});
  });

  it("promotes a preview tab when the file is edited", () => {
    state().openFile("src/one.ts", { preview: true });
    state().setFileDirty("src/one.ts", true);

    expect(state().previewFilePath).toBeNull();
    expect(state().dirtyFiles).toEqual({ "src/one.ts": true });
  });

  it("clamps invalid font sizes before storing them", () => {
    state().setFontSizes({ ui: 7.2, editor: 33, terminal: Number.NaN });

    expect(state().fontSizes).toEqual({
      ui: 8,
      editor: 32,
      terminal: DEFAULT_FONT_SIZES.terminal,
    });
  });
});

describe("session display title", () => {
  it("prefers explicit titles, then live titles, then the default label", () => {
    expect(displaySessionTitle({ ...session("s1"), title: "Named" }, {})).toBe("Named");
    expect(displaySessionTitle(session("s2"), { s2: "Shell title" })).toBe("Shell title");
    expect(displaySessionTitle(session("s3"), {})).toBe("New session");
  });
});
