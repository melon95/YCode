import { beforeEach, describe, expect, it } from "vitest";
import {
  captureProjectUiSnapshot,
  DEFAULT_FONT_SIZES,
  displaySessionTitle,
  PICKER_SLOT,
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
    worktree_path: null,
    branch: null,
    base_branch: null,
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

  it("adds the picker as a new pane beside existing sessions", () => {
    state().setSessions([session("s1"), session("s2")]);
    state().appendSessionToLayout("s1");
    state().appendSessionToLayout("s2");

    state().showNewSessionPicker();

    // Existing panes stay; the picker is appended as a focused extra slot.
    expect(state().layout.visibleIds).toEqual(["s1", "s2", PICKER_SLOT]);
    expect(state().layout.focusSlot).toBe(2);
    // The picker slot isn't a session, so nothing is "active".
    expect(state().activeId).toBeNull();
    expect(Object.keys(state().sessions).sort()).toEqual(["s1", "s2"]);
  });

  it("fills the picker slot in place when an agent is chosen", () => {
    state().setSessions([session("s1"), session("s2")]);
    state().appendSessionToLayout("s1");
    state().appendSessionToLayout("s2");
    state().showNewSessionPicker();

    // Simulate the picker creating + opening a session.
    state().openSessionInLayout("s3");

    expect(state().layout.visibleIds).toEqual(["s1", "s2", "s3"]);
    expect(state().layout.focusSlot).toBe(2);
    expect(state().activeId).toBe("s3");
  });

  it("re-focuses an open picker instead of adding a second one", () => {
    state().setSessions([session("s1")]);
    state().appendSessionToLayout("s1");
    state().showNewSessionPicker();
    state().focusLayoutSlot(0);
    state().showNewSessionPicker();

    expect(state().layout.visibleIds).toEqual(["s1", PICKER_SLOT]);
    expect(state().layout.focusSlot).toBe(1);
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

  it("remembers each project's right-pane tab and open files across switches", () => {
    state().setSessions([
      { ...session("a1", "project-a"), updated_at_ms: 10 },
      { ...session("b1", "project-b"), updated_at_ms: 20 },
    ]);

    // Project A: terminal tab + an open file.
    state().setActiveProjectId("project-a");
    state().setRightTab("terminal");
    state().openFile("src/a.ts");

    // Switch to B — it starts on defaults, not A's state.
    state().setActiveProjectId("project-b");
    expect(state().rightTab).toBe("files");
    expect(state().openFiles).toEqual([]);
    state().setRightTab("changes");

    // Back to A — its tab and open file return.
    state().setActiveProjectId("project-a");
    expect(state().rightTab).toBe("terminal");
    expect(state().openFiles).toEqual(["src/a.ts"]);

    // B kept its own tab independently.
    state().setActiveProjectId("project-b");
    expect(state().rightTab).toBe("changes");
    expect(state().openFiles).toEqual([]);
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

  it("keeps the picker (does not revive a session) after the user closes every pane and switches back", () => {
    state().setSessions([
      { ...session("a1", "project-a"), updated_at_ms: 10 },
      { ...session("b1", "project-b"), updated_at_ms: 20 },
    ]);

    // Project A auto-opens its latest session on first visit.
    state().setActiveProjectId("project-a");
    expect(state().layout.visibleIds).toEqual(["a1"]);

    // User closes the only pane (× keeps the PTY alive) → sitting on the picker.
    state().closeLayoutSlot(0);
    expect(state().layout.visibleIds).toEqual([]);
    expect(state().activeId).toBeNull();

    // Round-trip through another project and back must NOT re-open a1.
    state().setActiveProjectId("project-b");
    state().setActiveProjectId("project-a");

    expect(state().layout.visibleIds).toEqual([]);
    expect(state().activeId).toBeNull();
  });
});

describe("detached-window UI snapshot", () => {
  beforeEach(() => {
    localStorage.clear();
    useStore.setState(initialState, true);
  });

  it("round-trips panes and editor tabs into a fresh detached window", () => {
    // Source window: project-a active with a two-pane columns layout, the
    // Changes tab open, and a file in the editor.
    state().setSessions([session("s1"), session("s2")]);
    useStore.setState({ activeProjectId: "project-a" });
    state().appendSessionToLayout("s1");
    state().appendSessionToLayout("s2");
    state().setLayoutMode("columns");
    state().setRightTab("changes");
    state().openFile("src/a.ts");

    const snap = captureProjectUiSnapshot("project-a");
    expect(snap).toBeTruthy();

    // Fresh detached window: same sessions on disk, locked to project-a.
    useStore.setState(initialState, true);
    state().setSessions([session("s1"), session("s2")]);
    state().setLockedProjectId("project-a");
    state().hydrateLockedWindow(snap);

    expect(state().layout.visibleIds).toEqual(["s1", "s2"]);
    expect(state().layout.mode).toBe("columns");
    expect(state().activeId).toBe("s2");
    expect(state().rightTab).toBe("changes");
    expect(state().openFiles).toEqual(["src/a.ts"]);
    expect(state().selectedFilePath).toBe("src/a.ts");
  });

  it("captures a backgrounded project's stashed right-pane state on detach", () => {
    state().setSessions([
      { ...session("a1", "project-a"), updated_at_ms: 10 },
      { ...session("b1", "project-b"), updated_at_ms: 20 },
    ]);
    state().setActiveProjectId("project-a");
    state().appendSessionToLayout("a1");
    state().setRightTab("terminal");
    state().openFile("src/a.ts");

    // Switch away: project-a is now backgrounded, its right-pane UI stashed.
    state().setActiveProjectId("project-b");

    // Detaching the backgrounded project must carry its own state, not the
    // active project's nor a reset-to-Files default.
    const snap = captureProjectUiSnapshot("project-a");
    expect(snap).toBeTruthy();
    const parsed = JSON.parse(snap!);
    expect(parsed.rightTab).toBe("terminal");
    expect(parsed.openFiles).toEqual(["src/a.ts"]);
  });

  it("drops panes whose session no longer exists in the new window", () => {
    state().setSessions([session("s1"), session("s2")]);
    useStore.setState({ activeProjectId: "project-a" });
    state().appendSessionToLayout("s1");
    state().appendSessionToLayout("s2");
    const snap = captureProjectUiSnapshot("project-a");

    // s2 was archived between detach and load — only s1 remains.
    useStore.setState(initialState, true);
    state().setSessions([session("s1")]);
    state().setLockedProjectId("project-a");
    state().hydrateLockedWindow(snap);

    expect(state().layout.visibleIds).toEqual(["s1"]);
    expect(state().activeId).toBe("s1");
  });

  it("returns null when the project is sitting at the picker", () => {
    state().setSessions([session("s1")]);
    useStore.setState({ activeProjectId: "project-a" });
    // No panes opened — nothing worth handing off.
    expect(captureProjectUiSnapshot("project-a")).toBeNull();
  });

  it("is a no-op in the main window and on malformed payloads", () => {
    state().setSessions([session("s1")]);
    useStore.setState({ activeProjectId: "project-a" });
    state().appendSessionToLayout("s1");
    const before = state().layout;

    // No lock → main window: hydration must not touch the layout.
    state().hydrateLockedWindow('{"layout":{"mode":"single","visibleIds":["s1"],"focusSlot":0}}');
    expect(state().layout).toBe(before);

    // Locked but the payload is garbage → still a no-op.
    state().setLockedProjectId("project-a");
    state().hydrateLockedWindow("not json");
    expect(state().layout).toBe(before);
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
