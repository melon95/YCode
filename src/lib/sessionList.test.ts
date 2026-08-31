import { describe, expect, it } from "vitest";
import { bucketSessions, mergeSessions } from "./sessionList";
import type {
  AgentProfileView,
  DiscoveredSessionView,
  SessionView,
} from "./types";

const claude: AgentProfileView = {
  id: "claude-code",
  display_name: "Claude Code",
  command: "claude",
  available: true,
  icon: "ClaudeCode",
  icon_variant: null,
  color: null,
  introspect: "claude",
};

const AGENTS = { "claude-code": claude };
const BY_INTROSPECT = { claude };

function live(over: Partial<SessionView> & { id: string }): SessionView {
  return {
    title: "",
    agent_profile: "claude-code",
    agent_session_id: null,
    agent_thread_name: null,
    project_id: "p1",
    status: { type: "Exited", code: 0 },
    created_at_ms: 0,
    updated_at_ms: 1_000,
    archived_at_ms: null,
    worktree_path: null,
    branch: null,
    base_branch: null,
    ...over,
  };
}

function found(
  over: Partial<DiscoveredSessionView> & { session_id: string },
): DiscoveredSessionView {
  return {
    agent: "claude",
    jsonl_path: `/tmp/${over.session_id}.jsonl`,
    size_bytes: 0,
    modified_at_ms: 1_000,
    title: null,
    ...over,
  };
}

function merge(
  liveRows: SessionView[],
  discovered: DiscoveredSessionView[],
  visibleIds: string[] = [],
) {
  return mergeSessions({
    live: liveRows,
    discovered,
    agentByProfileId: AGENTS,
    profileByIntrospect: BY_INTROSPECT,
    activityBySession: {},
    visibleIds,
  });
}

describe("mergeSessions", () => {
  it("collapses the extra DB rows a resume leaves behind", () => {
    // Resuming inserts a fresh row with a new window-local id and no title,
    // so one conversation was showing up as four sidebar entries.
    const rows = merge(
      [
        live({ id: "a", agent_session_id: "cli-1", title: "重构检查点", updated_at_ms: 100 }),
        live({ id: "b", agent_session_id: "cli-1", updated_at_ms: 200 }),
        live({ id: "c", agent_session_id: "cli-1", updated_at_ms: 300 }),
      ],
      [],
    );

    expect(rows).toHaveLength(1);
    // The newest row carries the state, but its title is empty — the title
    // has to survive from the row it replaced.
    expect(rows[0].title).toBe("重构检查点");
    expect(rows[0].updatedAtMs).toBe(300);
    expect(rows[0].live?.id).toBe("c");
  });

  it("joins a DB row to its transcript instead of listing both", () => {
    const rows = merge(
      [live({ id: "a", agent_session_id: "cli-1", updated_at_ms: 100 })],
      [found({ session_id: "cli-1", title: "调研 rust 桌面框架", modified_at_ms: 500 })],
    );

    expect(rows).toHaveLength(1);
    expect(rows[0].live?.id).toBe("a");
    expect(rows[0].discovered).not.toBeNull();
    // The untitled DB row inherits the transcript's title — this is what
    // stops the sidebar rendering a column of identical "Claude Code".
    expect(rows[0].title).toBe("调研 rust 桌面框架");
    expect(rows[0].updatedAtMs).toBe(500);
  });

  it("keeps a user's rename over the transcript's baked-in title", () => {
    const rows = merge(
      [live({ id: "a", agent_session_id: "cli-1", title: "我改的名字" })],
      [found({ session_id: "cli-1", title: "首条用户消息" })],
    );

    expect(rows[0].title).toBe("我改的名字");
  });

  it("shows transcripts ycode never started as resumable rows", () => {
    const rows = merge([], [found({ session_id: "cli-9", title: "外面跑的会话" })]);

    expect(rows).toHaveLength(1);
    expect(rows[0].live).toBeNull();
    expect(rows[0].light).toBeNull();
    expect(rows[0].title).toBe("外面跑的会话");
  });

  it("keeps a session with no CLI id — it can't be matched or rediscovered", () => {
    // Codex sessions often have no agent_session_id. Dropping them because
    // they don't join would lose the only record of them.
    const rows = merge([live({ id: "solo", title: "codex 会话" })], []);

    expect(rows).toHaveLength(1);
    expect(rows[0].key).toBe("solo");
  });

  it("falls back to the CLI thread name before the agent's product name", () => {
    const rows = merge(
      [live({ id: "a", agent_thread_name: "fix-the-parser" })],
      [],
    );

    expect(rows[0].title).toBe("fix-the-parser");
  });

  it("orders attention first, then recency", () => {
    const rows = merge(
      [
        live({ id: "old", agent_session_id: "c1", title: "旧", updated_at_ms: 100 }),
        live({ id: "new", agent_session_id: "c2", title: "新", updated_at_ms: 900 }),
        live({
          id: "run",
          agent_session_id: "c3",
          title: "在跑",
          status: { type: "Running" },
          updated_at_ms: 50,
        }),
      ],
      [],
    );

    expect(rows.map((r) => r.title)).toEqual(["在跑", "新", "旧"]);
  });

  it("points the pane badge at whichever duplicate is actually on canvas", () => {
    const rows = merge(
      [
        live({ id: "onCanvas", agent_session_id: "cli-1", updated_at_ms: 100 }),
        live({ id: "newer", agent_session_id: "cli-1", updated_at_ms: 200 }),
      ],
      [],
      ["onCanvas"],
    );

    expect(rows[0].paneIdx).toBe(0);
    expect(rows[0].live?.id).toBe("onCanvas");
  });

  it("skips transcripts too malformed to carry an id", () => {
    const rows = merge([], [
      { ...found({ session_id: "x" }), session_id: null },
    ]);

    expect(rows).toHaveLength(0);
  });
});

describe("bucketSessions", () => {
  const now = 10 * 86_400_000;

  it("splits live work from recent and older history", () => {
    const rows = merge(
      [
        live({ id: "a", agent_session_id: "c1", title: "在跑", status: { type: "Running" }, updated_at_ms: 0 }),
        live({ id: "b", agent_session_id: "c2", title: "本周", updated_at_ms: now - 86_400_000 }),
        live({ id: "c", agent_session_id: "c3", title: "很久以前", updated_at_ms: now - 60 * 86_400_000 }),
      ],
      [],
    );
    const buckets = bucketSessions(rows, now);

    // A running session stays at the top regardless of how stale its
    // timestamp is — it's the one thing actually happening.
    expect(buckets.active.map((r) => r.title)).toEqual(["在跑"]);
    expect(buckets.recent.map((r) => r.title)).toEqual(["本周"]);
    expect(buckets.older.map((r) => r.title)).toEqual(["很久以前"]);
  });
});
