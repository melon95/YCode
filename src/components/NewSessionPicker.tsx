// "New task" picker shown in the middle pane when the active project has no
// sessions. Clicking an agent immediately creates a session (no extra dialog
// or title prompt — the agent's display name becomes the session title).
//
// The agent list comes straight from the store (populated at startup from
// the backend's JSON config). No hardcoded filtering — every configured
// profile is shown, with `available: false` ones disabled so the user can
// see at a glance which CLIs they still need to install.

import { useMemo, useState } from "react";
import { useTranslation } from "react-i18next";
import { createSession, setProjectIsolateSessions } from "../lib/ipc";
import { useStore } from "../lib/store";
import type { AgentProfileView, ProjectView } from "../lib/types";
import { ProjectPickerMenu } from "./ui/ProjectPickerMenu";
import { ToggleTrack } from "./ui/SettingControls";
import { AgentIcon } from "./AgentIcon";

const COMPOSER_LABEL =
  "text-[9.5px] font-semibold tracking-caps uppercase text-subtle";

/// 卡内的可选项:内嵌元素不该有和外层卡一样强的投影,给一层极浅的贴底
/// 阴影就够 —— 它要表达的是「可点」,不是「浮在上面」。
const CARD = `flex items-center gap-[11px] w-full py-2.5 px-[13px] border-none rounded-xl
  bg-surface text-[inherit] text-left cursor-pointer
  shadow-[0_0_0_0.5px_rgba(0,0,0,0.04),0_1px_2px_rgba(0,0,0,0.05)]
  transition-[background-color,transform,box-shadow] duration-[var(--t-fast)] ease-smooth
  not-disabled:hover:bg-panel-raised
  not-disabled:hover:shadow-[0_0_0_0.5px_rgba(0,0,0,0.06),0_2px_6px_rgba(0,0,0,0.08)]
  not-disabled:active:scale-[0.985] disabled:opacity-45 disabled:cursor-not-allowed`
  .replace(/\s+/g, " ");

const CHIP = "font-mono text-[9.5px] rounded-[5px] py-px px-1.5";

export function NewSessionPicker({ project }: { project: ProjectView }) {
  const { t } = useTranslation();
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
    <div className="flex-1 min-h-0 flex items-center justify-center p-7 overflow-y-auto">
      {/* 卡片语言:去描边、改阴影。 */}
      <div className="w-[460px] max-w-full pt-5 pr-[22px] pb-[18px] pl-[22px] rounded-2xl bg-panel animate-card-in shadow-[0_0_0_0.5px_rgba(0,0,0,0.05),0_1px_3px_rgba(0,0,0,0.06),0_6px_18px_rgba(0,0,0,0.08)]">
        <div className={COMPOSER_LABEL}>
          {t("picker.newSessionIn")}
          <ProjectPickerMenu>{project.name}</ProjectPickerMenu>
        </div>
        {/* No task field here on purpose: the agent CLI has its own input,
            and pre-typing a prompt would mean injecting it into the PTY —
            timing-fragile, and it throws away the CLI's own affordances
            (slash commands, @file, history). Say what you want in the
            terminal once the agent is up. */}

        {error && <div className="form-error">{error}</div>}

        <div className={`${COMPOSER_LABEL} mt-[18px] mb-2`}>Agent</div>
        <div className="flex flex-col gap-2">
          {sorted.length === 0 && !error && (
            <div className="empty" style={{ padding: 12 }}>
              {t("picker.noAgents")}
              <code> ~/.config/ycode/config.json</code> {t("picker.noAgentsAdd")}
            </div>
          )}
          {sorted.map((agent) => (
            <button
              key={agent.id}
              type="button"
              className={CARD}
              onClick={() => pick(agent)}
              disabled={!agent.available || creatingId !== null}
              title={
                agent.available
                        ? agent.command
                        : t("picker.notOnPath", { command: agent.command })
              }
            >
              <span className="flex-none flex">
                <AgentIcon
                  icon={agent.icon}
                  variant={agent.icon_variant}
                  fallbackChar={agent.display_name}
                  size={24}
                />
              </span>
              <span className="flex-1 min-w-0 flex flex-col gap-1">
                <span className="text-[13px] font-semibold text-text">
                  {agent.display_name}
                </span>
                {/* 「历史可读」的 chip 不在这里出现:选 agent 时要判断的是
                    「用哪个」,而 introspect 能力对这个决定没有影响 —— 它是
                    agent 的固有属性,不是此刻的选项差异。真要查它,设置页的
                    Agent 目录里那份带 tooltip 的更合适。 */}
                <span className="flex items-center gap-1.5 flex-wrap [&_code]:font-mono [&_code]:text-[10px] [&_code]:text-subtle">
                  <code>{agent.command}</code>
                  {!agent.available && (
                    <span className={`${CHIP} text-st-working bg-st-working-tint`}>
                      {t("picker.notInstalled")}
                    </span>
                  )}
                </span>
              </span>
              {creatingId === agent.id && (
                <span className="flex-none font-mono text-[10px] text-st-working">
                  {t("common.starting")}
                </span>
              )}
            </button>
          ))}
        </div>

        <button
          type="button"
          className={`${CARD} items-start bg-transparent mt-3.5 py-[11px]`}
          onClick={toggleIsolate}
          aria-pressed={project.isolate_sessions}
        >
          {/* 与设置页同一套开关外观 —— 组件级统一,别再各处自绘。 */}
          <ToggleTrack checked={project.isolate_sessions} />
          <span className="flex-1 min-w-0 flex flex-col gap-[3px]">
            <span
              className="text-[12.5px] font-medium text-text"
              title={t("picker.worktreeHint")}
            >
              Worktree
            </span>
          </span>
        </button>
      </div>
    </div>
  );
}
