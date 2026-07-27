import { beforeEach, describe, expect, it, vi } from "vitest";
import { act, render } from "@testing-library/react";
import { useEffect, useRef } from "react";
import { useStore } from "./store";
import type { ProjectView, SessionView } from "./types";

vi.mock("./ipc", () => ({
  resolveTerminalPath: vi.fn(async () => "src/foo.ts"),
}));
vi.mock("@heroui/react", () => ({
  toast: { warning: vi.fn(), danger: vi.fn() },
}));

import { activateFilePath } from "./fileLinkProvider";

const initialState = useStore.getState();
const state = () => useStore.getState();

function project(id: string): ProjectView {
  return {
    id,
    name: id,
    repo_path: `/tmp/${id}`,
    created_at_ms: 1,
    session_count: 0,
    isolate_sessions: true,
  } as ProjectView;
}

function worktreeSession(id: string, projectId = "project-a"): SessionView {
  return {
    id,
    title: "",
    agent_profile: "shell-test",
    agent_session_id: null,
    agent_thread_name: null,
    project_id: projectId,
    status: { type: "Running" },
    created_at_ms: 1,
    updated_at_ms: 1,
    archived_at_ms: null,
    worktree_path: `/tmp/wt-${id}`,
    branch: `ycode/${id}`,
    base_branch: "main",
  } as SessionView;
}

// Stand-in for EditorPanel: its pending-goto request is instance-local state
// fed by a window listener, and RightPane remounts it via a workspace-scoped
// `key`. Only a listener that is still mounted can act on the event.
const received: Array<{ instance: number; path: string }> = [];
const alive = new Set<number>();
let seq = 0;

function FakeEditor() {
  const idRef = useRef(0);
  if (!idRef.current) idRef.current = ++seq;
  useEffect(() => {
    const id = idRef.current;
    alive.add(id);
    const onGoto = (event: Event) => {
      received.push({
        instance: id,
        path: (event as CustomEvent).detail.path,
      });
    };
    window.addEventListener("ycode:editor-goto", onGoto);
    return () => {
      alive.delete(id);
      window.removeEventListener("ycode:editor-goto", onGoto);
    };
  }, []);
  return null;
}

function Host() {
  const activeProjectId = useStore((s) => s.activeProjectId);
  const target = useStore((s) =>
    activeProjectId
      ? (s.workspaceSessionByProject[activeProjectId] ?? null)
      : null,
  );
  if (!activeProjectId) return null;
  return <FakeEditor key={`${activeProjectId}:${target ?? "main"}`} />;
}

describe("activateFilePath", () => {
  beforeEach(() => {
    localStorage.clear();
    useStore.setState(initialState, true);
    received.length = 0;
    alive.clear();
    seq = 0;
    state().setProjects([project("project-a")]);
    state().setActiveProjectId("project-a");
    state().setSessions([worktreeSession("s1")]);
  });

  it("delivers the goto to the editor that survives a workspace switch", async () => {
    render(<Host />);
    const before = [...alive][0];

    await act(async () => {
      await activateFilePath("project-a", "src/foo.ts", 42, undefined, "s1");
      // Let the post-remount dispatch run.
      await new Promise((resolve) => requestAnimationFrame(() => resolve(null)));
    });

    expect(state().workspaceSessionByProject["project-a"]).toBe("s1");
    const after = [...alive][0];
    expect(after).not.toBe(before);
    // Dispatching before the remount would deliver to the dead instance and
    // the jump-to-line would be silently lost.
    expect(received).toEqual([{ instance: after, path: "src/foo.ts" }]);
  });

  it("switches back to main for a shared-mode session's link", async () => {
    // Shared-mode sessions have no worktree — they run in the main checkout.
    const shared = { ...worktreeSession("s2"), worktree_path: null };
    state().setSessions([worktreeSession("s1"), shared]);
    state().setWorkspaceSessionId("project-a", "s1");
    render(<Host />);

    await act(async () => {
      await activateFilePath("project-a", "src/foo.ts", undefined, undefined, "s2");
      await new Promise((resolve) => requestAnimationFrame(() => resolve(null)));
    });

    // Leaving the editor pinned to s1's worktree would open a different file
    // at the same relative path — or nothing at all.
    expect(state().workspaceSessionByProject["project-a"]).toBeNull();
    expect(state().openFiles).toEqual(["src/foo.ts"]);
  });

  it("brings a background project forward before opening its file", async () => {
    state().setProjects([project("project-a"), project("project-b")]);
    state().setSessions([
      worktreeSession("s1"),
      { ...worktreeSession("sb"), project_id: "project-b" },
    ]);
    state().setActiveProjectId("project-a");
    state().openFile("a-main.ts");
    render(<Host />);

    await act(async () => {
      await activateFilePath("project-b", "src/foo.ts", undefined, undefined, "sb");
      await new Promise((resolve) => requestAnimationFrame(() => resolve(null)));
    });

    // Without the project switch the file lands in project-a's tab strip.
    expect(state().activeProjectId).toBe("project-b");
    expect(state().openFiles).toEqual(["src/foo.ts"]);
  });

  it("dispatches immediately when no workspace switch is needed", async () => {
    state().setWorkspaceSessionId("project-a", "s1");
    render(<Host />);
    const instance = [...alive][0];

    await act(async () => {
      await activateFilePath("project-a", "src/foo.ts", 7, undefined, "s1");
    });

    expect(received).toEqual([{ instance, path: "src/foo.ts" }]);
    expect([...alive]).toEqual([instance]);
  });
});
