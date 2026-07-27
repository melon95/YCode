import { beforeEach, describe, expect, it } from "vitest";
import {
  captureProjectUiSnapshot,
  DEFAULT_FONT_SIZES,
  displaySessionTitle,
  PICKER_SLOT,
  useStore,
} from "./store";
import type { ProjectView, SessionView } from "./types";

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

describe("project tab order", () => {
  beforeEach(() => {
    localStorage.clear();
    useStore.setState(initialState, true);
  });

  it("moves a project before or after another project and persists the order", () => {
    state().setProjects([project("b", 2), project("a", 1), project("c", 3)]);
    expect(state().projectOrder).toEqual(["a", "b", "c"]);

    state().moveProject("a", "c", "after");
    expect(state().projectOrder).toEqual(["b", "c", "a"]);

    useStore.setState(initialState, true);
    state().setProjects([project("a", 1), project("b", 2), project("c", 3)]);
    expect(state().projectOrder).toEqual(["b", "c", "a"]);
  });

  it("keeps persisted projects in order while appending newly discovered ones", () => {
    state().setProjects([project("a", 1), project("b", 2)]);
    state().moveProject("b", "a", "before");

    state().setProjects([project("a", 1), project("b", 2), project("c", 3)]);
    expect(state().projectOrder).toEqual(["b", "a", "c"]);
  });
});

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

  it("round-trips the shared workspace target and clears it with its session", () => {
    const isolated = {
      ...session("s1"),
      worktree_path: "/tmp/worktrees/s1",
      branch: "ycode/s1",
    };
    state().setSessions([isolated]);
    useStore.setState({ activeProjectId: "project-a" });
    state().appendSessionToLayout("s1");
    state().setWorkspaceSessionId("project-a", "s1");

    const snap = captureProjectUiSnapshot("project-a");
    useStore.setState(initialState, true);
    state().setSessions([isolated]);
    state().setLockedProjectId("project-a");
    state().hydrateLockedWindow(snap);
    expect(state().workspaceSessionByProject["project-a"]).toBe("s1");

    state().removeSession("s1");
    expect(state().workspaceSessionByProject["project-a"]).toBeNull();
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

describe("workspace target routing", () => {
  beforeEach(() => {
    useStore.setState(initialState, true);
    state().setProjects([project("project-a", 1)]);
    state().setActiveProjectId("project-a");
  });

  it("gives each checkout its own editor tabs instead of re-resolving paths", () => {
    state().openFile("src/main.ts");
    state().setFileDirty("src/main.ts", true);

    // The same repo-relative path names a different file in the worktree, so
    // the tab strip must not carry over.
    state().setWorkspaceSessionId("project-a", "sess-1");
    expect(state().openFiles).toEqual([]);
    expect(state().selectedFilePath).toBeNull();
    expect(state().dirtyFiles).toEqual({});

    state().openFile("src/worktree-only.ts");
    expect(state().openFiles).toEqual(["src/worktree-only.ts"]);

    // Switching back restores the main checkout's tabs, dirty flag included.
    state().setWorkspaceSessionId("project-a", null);
    expect(state().openFiles).toEqual(["src/main.ts"]);
    expect(state().selectedFilePath).toBe("src/main.ts");
    expect(state().dirtyFiles).toEqual({ "src/main.ts": true });

    state().setWorkspaceSessionId("project-a", "sess-1");
    expect(state().openFiles).toEqual(["src/worktree-only.ts"]);
  });

  it("keeps per-workspace tabs separate across a project switch", () => {
    state().setProjects([project("project-a", 1), project("project-b", 2)]);
    state().openFile("a-main.ts");
    state().setWorkspaceSessionId("project-a", "sess-1");
    state().openFile("a-worktree.ts");

    state().setActiveProjectId("project-b");
    expect(state().openFiles).toEqual([]);

    // Returning lands on the workspace project-a was last left on.
    state().setActiveProjectId("project-a");
    expect(state().openFiles).toEqual(["a-worktree.ts"]);
    state().setWorkspaceSessionId("project-a", null);
    expect(state().openFiles).toEqual(["a-main.ts"]);
  });

  it("ignores target changes for a project the user isn't viewing", () => {
    state().openFile("a-main.ts");

    state().setWorkspaceSessionId("project-b", "sess-9");

    // project-a's live editor fields must be untouched.
    expect(state().openFiles).toEqual(["a-main.ts"]);
    expect(state().workspaceSessionByProject["project-b"]).toBe("sess-9");
  });

  it("restores the main checkout's tabs when the targeted session is closed", () => {
    state().setSessions([session("sess-1")]);
    state().openFile("main-file.ts");
    state().setWorkspaceSessionId("project-a", "sess-1");
    state().openFile("worktree-file.ts");
    expect(state().openFiles).toEqual(["worktree-file.ts"]);

    state().removeSession("sess-1");

    // The worktree is gone, so its tabs must go with it — leaving them would
    // silently re-resolve those paths against the main checkout.
    expect(state().workspaceSessionByProject["project-a"]).toBeNull();
    expect(state().openFiles).toEqual(["main-file.ts"]);
    // The dead workspace's stash is unreachable now; it must not linger.
    expect(Object.keys(state().rightUiByProject)).not.toContain(
      "project-a:sess-1",
    );
  });

  it("drops a vanished target when a session list refresh omits it", () => {
    state().setSessions([session("sess-1")]);
    state().openFile("main-file.ts");
    state().setWorkspaceSessionId("project-a", "sess-1");
    state().openFile("worktree-file.ts");

    // Backend no longer reports the session (archived elsewhere).
    state().setSessions([]);

    expect(state().workspaceSessionByProject["project-a"]).toBeNull();
    expect(state().openFiles).toEqual(["main-file.ts"]);
    expect(Object.keys(state().rightUiByProject)).not.toContain(
      "project-a:sess-1",
    );
  });

  it("leaves the viewed project alone when another project's target dies", () => {
    state().setProjects([project("project-a", 1), project("project-b", 2)]);
    state().setSessions([session("sess-b", "project-b")]);
    state().setWorkspaceSessionId("project-b", "sess-b");
    state().setActiveProjectId("project-a");
    state().openFile("a-main.ts");

    state().removeSession("sess-b");

    expect(state().workspaceSessionByProject["project-b"]).toBeNull();
    // project-a is what's on screen; its tabs must not be disturbed.
    expect(state().openFiles).toEqual(["a-main.ts"]);
  });

  it("stashes the detached project's tabs and dirty flags", () => {
    state().setProjects([project("project-a", 1), project("project-b", 2)]);
    state().setActiveProjectId("project-a");
    state().openFile("a-main.ts");
    state().setFileDirty("a-main.ts", true);

    // Another window takes over project-a; this window jumps to project-b.
    state().addLockedByOther("project-a");
    expect(state().activeProjectId).toBe("project-b");

    state().setActiveProjectId("project-a");
    expect(state().openFiles).toEqual(["a-main.ts"]);
    // The dirty flag drives the unsaved badge and the discard confirm; losing
    // it silently removes that guard.
    expect(state().dirtyFiles).toEqual({ "a-main.ts": true });
  });

  it("reclaims stashes for worktrees de-selected before their session died", () => {
    state().setProjects([project("project-a", 1)]);
    state().setActiveProjectId("project-a");
    for (const id of ["s0", "s1", "s2"]) {
      state().setSessions([session(id)]);
      state().setWorkspaceSessionId("project-a", id);
      state().openFile(`${id}.ts`);
      // The picker falls back to Main when a worktree finishes, so the target
      // is already de-selected by the time the session is archived.
      state().setWorkspaceSessionId("project-a", null);
      state().removeSession(id);
    }

    expect(Object.keys(state().rightUiByProject)).toEqual(["project-a:main"]);
  });

  it("seeds a detached window's stash so its tabs survive a round trip", () => {
    useStore.setState(initialState, true);
    state().setProjects([project("project-a", 1)]);
    state().setLockedProjectId("project-a");
    state().setSessions([session("sess-1")]);
    state().hydrateLockedWindow(
      JSON.stringify({
        layout: { mode: "single", visibleIds: ["sess-1"], focusSlot: 0 },
        rightTab: "editor",
        openFiles: ["wt.ts"],
        selectedFilePath: "wt.ts",
        previewFilePath: null,
        workspaceSessionId: "sess-1",
      }),
    );
    expect(state().openFiles).toEqual(["wt.ts"]);

    // The live fields and their stash entry must start in sync. Anything that
    // restores from the stash without a prior stash-on-exit — a project switch
    // driven by `addLockedByOther`, or a session teardown — would otherwise
    // read a missing entry and fall back to empty defaults.
    expect(state().rightUiByProject["project-a:sess-1"]).toMatchObject({
      openFiles: ["wt.ts"],
      selectedFilePath: "wt.ts",
      rightTab: "editor",
    });

    // And the ordinary round trip still works.
    state().setWorkspaceSessionId("project-a", null);
    state().setWorkspaceSessionId("project-a", "sess-1");
    expect(state().openFiles).toEqual(["wt.ts"]);
  });

  it("drops every workspace entry when its project is removed", () => {
    state().openFile("a-main.ts");
    state().setWorkspaceSessionId("project-a", "sess-1");
    state().openFile("a-worktree.ts");
    expect(Object.keys(state().rightUiByProject).length).toBeGreaterThan(0);

    state().removeProject("project-a");

    const leftover = Object.keys(state().rightUiByProject).filter((key) =>
      key.startsWith("project-a:"),
    );
    expect(leftover).toEqual([]);
  });
});

describe("session display title", () => {
  it("prefers explicit titles, then live titles, then the default label", () => {
    expect(displaySessionTitle({ ...session("s1"), title: "Named" }, {})).toBe("Named");
    expect(displaySessionTitle(session("s2"), { s2: "Shell title" })).toBe("Shell title");
    expect(displaySessionTitle(session("s3"), {})).toBe("New session");
  });
});
