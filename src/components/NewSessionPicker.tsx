// "New task" picker shown in the middle pane when the active project has no
// sessions. Clicking an agent immediately creates a session (no extra dialog
// or title prompt — the agent's display name becomes the session title).
//
// The agent list comes straight from the store (populated at startup from
// the backend's JSON config). No hardcoded filtering — every configured
// profile is shown, with `available: false` ones disabled so the user can
// see at a glance which CLIs they still need to install.

import { useMemo, useState } from "react";
import { createSession, setProjectIsolateSessions } from "../lib/ipc";
import { useStore } from "../lib/store";
import type { AgentProfileView, ProjectView } from "../lib/types";
import { AgentIcon } from "./AgentIcon";

export function NewSessionPicker({ project }: { project: ProjectView }) {
  const agents = useStore((s) => s.agents);
  const [creatingId, setCreatingId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const upsertSession = useStore((s) => s.upsertSession);
  const upsertProject = useStore((s) => s.upsertProject);
  const openSessionInLayout = useStore((s) => s.openSessionInLayout);

  // Toggle per-project worktree isolation. Optimistic: flip the store copy
  // first (so the checkbox responds instantly), roll back on failure.
  async function toggleIsolate() {
    const next = !project.isolate_sessions;
    upsertProject({ ...project, isolate_sessions: next });
    try {
      await setProjectIsolateSessions(project.id, next);
    } catch (err) {
      upsertProject({ ...project, isolate_sessions: !next });
      setError(String(err));
    }
  }

  // Show only agents whose command resolved on PATH (per user request —
  // unavailable agents are noise in the picker; Settings is where they
  // surface). Within the available set, introspect-bound profiles go first
  // (they integrate with the history sidebar), then PTY-only ones; config
  // order preserved within each group.
  const sorted = useMemo(() => {
    const available = agents.filter((a) => a.available);
    const introspectable = available.filter((a) => !!a.introspect);
    const ptyOnly = available.filter((a) => !a.introspect);
    return [...introspectable, ...ptyOnly];
  }, [agents]);

  async function pick(agent: AgentProfileView) {
    if (!agent.available || creatingId) return;
    setCreatingId(agent.id);
    setError(null);
    try {
      const view = await createSession({
        agent_profile_id: agent.id,
        project_id: project.id,
        // Empty — SessionRow shows the live CLI title (or "New session")
        // until the user double-clicks to rename.
        title: "",
      });
      upsertSession(view);
      openSessionInLayout(view.id);
    } catch (err) {
      setError(String(err));
    } finally {
      setCreatingId(null);
    }
  }

  return (
    <div className="new-session-picker-host">
      <div className="composer">
        <div className="composer-eyebrow">新建会话 · {project.name}</div>
        {/* No task field here on purpose: the agent CLI has its own input,
            and pre-typing a prompt would mean injecting it into the PTY —
            timing-fragile, and it throws away the CLI's own affordances
            (slash commands, @file, history). Say what you want in the
            terminal once the agent is up. */}
        <div className="composer-lede">选一个 agent 启动,任务在终端里直接说</div>

        {error && <div className="form-error">{error}</div>}

        <div className="composer-label">Agent</div>
        <div className="composer-agents">
          {sorted.length === 0 && !error && (
            <div className="empty" style={{ padding: 12 }}>
              没有配置任何 agent。编辑
              <code> ~/.config/ycode/config.json</code> 添加一个。
            </div>
          )}
          {sorted.map((agent) => (
            <button
              key={agent.id}
              type="button"
              className={
                "composer-agent" +
                (agent.available ? "" : " unavailable") +
                (creatingId === agent.id ? " creating" : "")
              }
              onClick={() => pick(agent)}
              disabled={!agent.available || creatingId !== null}
              title={
                agent.available ? agent.command : `${agent.command} — 不在 PATH 中`
              }
            >
              <span className="composer-agent-icon">
                <AgentIcon
                  icon={agent.icon}
                  variant={agent.icon_variant}
                  fallbackChar={agent.display_name}
                  size={24}
                />
              </span>
              <span className="composer-agent-main">
                <span className="composer-agent-name">{agent.display_name}</span>
                <span className="composer-agent-meta">
                  <code>{agent.command}</code>
                  {agent.introspect && <span className="chip-ok">历史可读</span>}
                  {!agent.available && <span className="chip-warn">未安装</span>}
                </span>
              </span>
              {creatingId === agent.id && (
                <span className="composer-agent-busy">启动中…</span>
              )}
            </button>
          ))}
        </div>

        <button
          type="button"
          className={"composer-opt" + (project.isolate_sessions ? " on" : "")}
          onClick={toggleIsolate}
          aria-pressed={project.isolate_sessions}
        >
          <span className="composer-switch" aria-hidden>
            <span className="composer-knob" />
          </span>
          <span className="composer-opt-main">
            <span className="composer-opt-title">隔离到独立 worktree</span>
            <span className="composer-opt-desc">
              每个 agent 拿到自己的分支与工作目录,并行时互不覆盖
            </span>
          </span>
        </button>

        {/* 预览稿 .modal-foot 的提示行。「开始 ⏎」主按钮不适用 —— 这里点
            agent 即启动,没有独立的确认步骤。 */}
        <div className="composer-foot">
          <span>
            <kbd>点击</kbd> 启动会话
          </span>
          <span>
            <kbd>⇧⌘N</kbd> 唤起本界面
          </span>
        </div>
      </div>
    </div>
  );
}
