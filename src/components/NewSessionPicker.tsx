// "New task" picker shown in the middle pane when the active project has no
// sessions. Clicking an agent immediately creates a session (no extra dialog
// or title prompt — the agent's display name becomes the session title).
//
// The agent list comes straight from the store (populated at startup from
// the backend's JSON config). No hardcoded filtering — every configured
// profile is shown, with `available: false` ones disabled so the user can
// see at a glance which CLIs they still need to install.

import { useMemo, useState } from "react";
import { Popover } from "@base-ui/react/popover";
import { useTranslation } from "react-i18next";
import {
  createSession,
  gitCheckoutBranch,
  gitListBranches,
  setProjectIsolateSessions,
} from "../lib/ipc";
import { useMainBranch } from "../lib/checkoutLabel";
import { useStore } from "../lib/store";
import type { AgentProfileView, GitBranchListView, ProjectView } from "../lib/types";
import { ProjectPickerMenu } from "./ui/ProjectPickerMenu";
import { MENU_ITEM_ON, MENU_ITEM_REST, MENU_POPUP, POPOVER_LAYER } from "./ui/menuStyles";
import { AgentIcon } from "./AgentIcon";

const COMPOSER_LABEL =
  "text-[9.5px] font-semibold tracking-caps uppercase text-subtle";

/// 卡内的可选项:内嵌元素不该有和外层卡一样强的投影,给一层极浅的贴底
/// 阴影就够 —— 它要表达的是「可点」,不是「浮在上面」。
///
/// agent 排成一行(而不是一个一个竖着堆):这张卡上真正要做的决定只有
/// 「用哪个 agent」,竖排把两三个等价选项拉成一列,读起来像清单而不像
/// 一次选择,还把下面的 worktree/分支挤出视线。
const CARD = `flex items-center gap-[11px] py-2.5 px-[13px] border-none rounded-xl
  bg-surface text-[inherit] text-left cursor-pointer
  shadow-[0_0_0_0.5px_rgba(0,0,0,0.04),0_1px_2px_rgba(0,0,0,0.05)]
  transition-[background-color,transform,box-shadow] duration-[var(--t-fast)] ease-smooth
  not-disabled:hover:bg-panel-raised
  not-disabled:hover:shadow-[0_0_0_0.5px_rgba(0,0,0,0.06),0_2px_6px_rgba(0,0,0,0.08)]
  not-disabled:active:scale-[0.985] disabled:opacity-45 disabled:cursor-not-allowed`
  .replace(/\s+/g, " ");

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
        <div className="flex flex-wrap gap-2">
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
              className={`${CARD} flex-1 basis-[46%] min-w-[150px]`}
              onClick={() => pick(agent)}
              disabled={!agent.available || creatingId !== null}
              // 命令名从卡面移进 title:一行里并排两三个 agent,名字下面再
              // 挂一行等宽的 `claude`/`codex` 会把每块撑到两倍高,而这个
              // 信息只在「装没装、指向哪个二进制」时才有人看。
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
                  size={20}
                />
              </span>
              <span className="flex-1 min-w-0 truncate text-[13px] font-semibold text-text">
                {agent.display_name}
              </span>
              {creatingId === agent.id && (
                <span className="flex-none font-mono text-[10px] text-st-working">
                  {t("common.starting")}
                </span>
              )}
            </button>
          ))}
        </div>

        {/* 分支与 worktree 合成一颗 pill:它们回答的是同一个问题 ——
            这次会话在哪儿落地。勾上就各自开一棵 worktree(从左边这根分支
            fork),不勾就直接在主仓库的这根分支上干活。两个控件挨在一起、
            共用一圈描边,比拆成两块各自带底色的卡更像「一个决定」。 */}
        <div className="flex items-center mt-3.5">
          <div className="inline-flex items-stretch h-[34px] rounded-[10px] border border-rule bg-surface overflow-hidden">
            <BranchPicker
              projectId={project.id}
              onError={setError}
              onSwitched={() => setError(null)}
            />
            <span className="self-center w-px h-[17px] bg-rule" aria-hidden />
            <label
              className="flex items-center gap-[7px] px-[11px] cursor-pointer
                transition-colors duration-[var(--t-fast)] ease-smooth hover:bg-panel-raised"
              title={t("picker.worktreeHint")}
            >
              <span className="relative flex-none inline-flex">
                <input
                  type="checkbox"
                  className="peer size-[14px] appearance-none rounded-[4px] border-[1.5px] border-rule-strong
                    bg-panel cursor-pointer transition-colors duration-[var(--t-fast)] ease-smooth
                    hover:border-accent checked:bg-accent checked:border-accent"
                  checked={project.isolate_sessions}
                  onChange={toggleIsolate}
                />
                <CheckGlyph />
              </span>
              <span className="text-[12px] text-text">worktree</span>
            </label>
          </div>
        </div>
      </div>
    </div>
  );
}

/// 勾。盖在 input 上方,跟着 `peer-checked` 显隐 —— input 自己
/// `appearance-none` 后没有对勾可用,而伪元素画的折线在缩放下容易糊。
function CheckGlyph() {
  return (
    <svg
      className="pointer-events-none absolute inset-0 m-auto size-[10px] text-white
        opacity-0 transition-opacity duration-[var(--t-fast)] peer-checked:opacity-100"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="3.4"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <path d="m5 13 4 4 10-10" />
    </svg>
  );
}

/// 主仓库的分支选择器。
///
/// 放在新建会话这张卡上,而不是变更卡的头部:切分支要求工作区干净,而
/// 变更卡的存在前提恰恰是「有改动」—— 在那儿点几乎注定失败。开一个新
/// 会话前才是工作区最可能干净、也最需要决定「从哪根分支出发」的时刻。
function BranchPicker({
  projectId,
  onError,
  onSwitched,
}: {
  projectId: string;
  onError: (message: string) => void;
  onSwitched: () => void;
}) {
  const { t } = useTranslation();
  const current = useMainBranch(projectId);
  const bumpBranchEpoch = useStore((s) => s.bumpBranchEpoch);
  const [open, setOpen] = useState(false);
  const [list, setList] = useState<GitBranchListView | null>(null);
  const [switching, setSwitching] = useState<string | null>(null);

  // 每次打开都重取:fetch、终端里的 checkout、别处新建的 worktree 都会
  // 改变这份清单,而它太小了,不值得为它常驻一个订阅。
  function openMenu() {
    setList(null);
    setOpen(true);
    gitListBranches(projectId)
      .then(setList)
      .catch(() => setList({ current: null, branches: [] }));
  }

  function choose(name: string) {
    if (name === list?.current) {
      setOpen(false);
      return;
    }
    setSwitching(name);
    gitCheckoutBranch(projectId, name)
      .then(() => {
        setOpen(false);
        onSwitched();
        // 「主仓库 (分支)」在状态栏、Files/变更卡的 chip、终端 picker 上
        // 各有一份,都靠这个 epoch 重新取值。
        bumpBranchEpoch();
      })
      .catch((err) => {
        const msg = String(err).replace(/^bad input:\s*/i, "");
        // git 拒绝切换时吐的是多行 stderr,换成一句能照做的。
        onError(
          /would be overwritten|commit your changes or stash/i.test(msg)
            ? t("picker.switchBlocked", { branch: name })
            : msg,
        );
      })
      .finally(() => setSwitching(null));
  }

  return (
    <Popover.Root open={open} onOpenChange={(next) => (next ? openMenu() : setOpen(false))}>
      <Popover.Trigger
        className="inline-flex items-center gap-[7px] px-[11px] max-w-[190px]
          border-none bg-transparent text-text cursor-pointer
          transition-colors duration-[var(--t-fast)] ease-smooth
          hover:bg-panel-raised data-[popup-open]:bg-panel-raised"
        title={t("picker.switchBranch")}
        aria-label={t("picker.switchBranch")}
      >
        <BranchGlyph />
        <span className="min-w-0 truncate font-mono text-[12px]">{current ?? "—"}</span>
        <ChevronGlyph />
      </Popover.Trigger>
      <Popover.Portal>
        <Popover.Positioner className={POPOVER_LAYER} sideOffset={6} align="start">
          <Popover.Popup className={`${MENU_POPUP} min-w-[200px] max-h-[50vh] overflow-y-auto`}>
            {list === null ? (
              <div className="py-[7px] px-[9px] font-mono text-[11px] text-muted">
                {t("common.loading")}
              </div>
            ) : list.branches.length === 0 ? (
              <div className="py-[7px] px-[9px] font-mono text-[11px] text-muted">
                {t("picker.noLocalBranch")}
              </div>
            ) : (
              list.branches.map((name) => (
                // 条目用普通 button 而不是 Popover.Close:后者点完立刻关,
                // 而切换要等 git 回来 —— 失败时(工作区不干净)菜单得留在
                // 原地,让人直接换一根,而不是重新点开。
                <button
                  key={name}
                  type="button"
                  className={`flex items-center gap-2 w-full py-[7px] px-[9px] border-none rounded-lg
                    bg-none font-mono text-[12px] text-left cursor-pointer
                    hover:bg-panel-raised disabled:opacity-40 disabled:cursor-default
                    ${name === list.current ? MENU_ITEM_ON : MENU_ITEM_REST}`}
                  disabled={switching !== null}
                  onClick={() => choose(name)}
                >
                  <span className="flex-1 min-w-0 truncate">{name}</span>
                  {switching === name && <span className="flex-none text-muted">…</span>}
                </button>
              ))
            )}
          </Popover.Popup>
        </Popover.Positioner>
      </Popover.Portal>
    </Popover.Root>
  );
}

function BranchGlyph() {
  return (
    <svg
      className="flex-none text-muted"
      width="13"
      height="13"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <circle cx="6" cy="6" r="2.5" />
      <circle cx="6" cy="18" r="2.5" />
      <circle cx="18" cy="8" r="2.5" />
      <path d="M6 8.5v7" />
      <path d="M18 10.5c0 4-4 3.5-6 5.5" />
    </svg>
  );
}

function ChevronGlyph() {
  return (
    <svg
      className="flex-none text-subtle"
      width="10"
      height="10"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <path d="m6 9 6 6 6-6" />
    </svg>
  );
}
