import { describe, expect, it } from "vitest";
import { projectActivity, type SessionActivity, type SessionView } from "./types";

function session(
  id: string,
  status: SessionView["status"] = { type: "Running" },
  archived = false,
): SessionView {
  return {
    id,
    title: "",
    agent_profile: "shell-test",
    agent_session_id: null,
    agent_thread_name: null,
    project_id: "project-a",
    status,
    created_at_ms: 1,
    updated_at_ms: 1,
    archived_at_ms: archived ? 1 : null,
    worktree_path: null,
    base_branch: null,
  };
}

describe("projectActivity", () => {
  it("returns null when there are no live sessions", () => {
    expect(projectActivity([], {})).toBeNull();
    // A lone archived session doesn't count.
    expect(projectActivity([session("a", { type: "Running" }, true)], {})).toBeNull();
  });

  it("marks the project running while any agent is still working", () => {
    const sessions = [session("a"), session("b")];
    // b finished its turn, a is still running → project is running.
    const activity: Record<string, SessionActivity> = { b: "waiting" };
    const a = projectActivity(sessions, activity)!;
    expect(a.light).toBe("running");
    expect(a.counts).toMatchObject({ running: 1, waiting: 1 });
    expect(a.total).toBe(2);
  });

  it("is waiting once every agent has finished its turn", () => {
    const sessions = [session("a"), session("b")];
    const activity: Record<string, SessionActivity> = { a: "waiting", b: "waiting" };
    expect(projectActivity(sessions, activity)!.light).toBe("waiting");
  });

  it("surfaces error over waiting when nothing is running", () => {
    const sessions = [
      session("a", { type: "Exited", code: 1 } as SessionView["status"]),
      session("b"),
    ];
    const activity: Record<string, SessionActivity> = { b: "waiting" };
    // Exited(code) maps to "done" via sessionLight, not error — use Error.
    const withError = [session("a", { type: "Error", message: "boom" } as SessionView["status"]), session("b")];
    expect(projectActivity(withError, activity)!.light).toBe("error");
    // Sanity: a plain exit with a waiting peer is waiting, not error.
    expect(projectActivity(sessions, activity)!.light).toBe("waiting");
  });

  it("is done when every session's process has exited", () => {
    const sessions = [
      session("a", { type: "Exited", code: 0 } as SessionView["status"]),
      session("b", { type: "Exited", code: 0 } as SessionView["status"]),
    ];
    expect(projectActivity(sessions, {})!.light).toBe("done");
  });
});
