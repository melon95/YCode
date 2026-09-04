import { useEffect, useMemo, useState } from "react";
import { Popover } from "@base-ui/react/popover";
import { useStore } from "../lib/store";
import { sessionLight, type SessionView } from "../lib/types";
import { StatusDot } from "./ui/StatusDot";
import { AgentIcon } from "./AgentIcon";
import { POPOVER_LAYER } from "./ui/menuStyles";

/// 等待项与「刚刚完成」项共用一套行几何,差别只在左侧竖条的颜色和整体
/// 声量 —— 完成项是背景信息,压低存在感,别和红色的等待项抢注意力。
///
/// `inbox-item` 作为选择器钩子留着:前几行的入场动画是错开的
/// (`:nth-child`),元素自己数不出「我是第几个」。
const ITEM = `inbox-item w-full flex items-center gap-2.5 py-[11px] px-3.5
  border-none border-t border-t-rule border-l-2 bg-transparent text-[inherit] text-left cursor-pointer
  transition-colors duration-[var(--t-fast)] ease-smooth hover:bg-panel-raised`
  .replace(/\s+/g, " ");

const TITLE =
  "text-[12.5px] text-text whitespace-nowrap overflow-hidden text-ellipsis";
const META =
  "font-mono text-[10.5px] text-subtle whitespace-nowrap overflow-hidden text-ellipsis";

/// The inbox answers one question: *which session is waiting on me right now?*
///
/// It deliberately stops there. The approval prompt itself lives in the
/// agent's own TUI — reproducing its Yes/No affordances here would mean
/// parsing terminal output to guess the options and injecting keystrokes to
/// answer them, which breaks the moment a CLI changes its prompt and quietly
/// takes a decision out of the user's hands. So the inbox routes you to the
/// session and gets out of the way.
export function AttentionInbox() {
  const sessions = useStore((s) => s.sessions);
  const projects = useStore((s) => s.projects);
  const agents = useStore((s) => s.agents);
  const activityBySession = useStore((s) => s.activityBySession);
  const setActiveProjectId = useStore((s) => s.setActiveProjectId);
  const openSessionInLayout = useStore((s) => s.openSessionInLayout);
  const [open, setOpen] = useState(false);

  // Sessions carry `agent_profile` (the launch-profile id), so index by id.
  const agentByProfileId = useMemo(() => {
    const out: Record<string, (typeof agents)[number]> = {};
    for (const a of agents) out[a.id] = a;
    return out;
  }, [agents]);

  const { waiting, done } = useMemo(() => {
    const waiting: { session: SessionView; projectName: string }[] = [];
    const done: { session: SessionView; projectName: string }[] = [];
    // 「刚刚完成」只收最近一小时:更早的完成不再是「刚刚」,而收件箱的
    // 语义就是此刻需要或值得看一眼的东西。
    const doneCutoff = Date.now() - 3_600_000;
    for (const s of Object.values(sessions)) {
      if (s.archived_at_ms != null) continue;
      const light = sessionLight(s.status, activityBySession[s.id]);
      const row = { session: s, projectName: projects[s.project_id]?.name ?? "" };
      if (light === "waiting") waiting.push(row);
      else if (light === "done" && s.updated_at_ms >= doneCutoff) done.push(row);
    }
    const byRecency = (
      a: { session: SessionView },
      b: { session: SessionView },
    ) => b.session.updated_at_ms - a.session.updated_at_ms;
    return {
      waiting: waiting.sort(byRecency),
      done: done.sort(byRecency).slice(0, 5),
    };
  }, [sessions, projects, activityBySession]);

  const count = waiting.length;

  // ⇧⌘A opens the inbox — the counterpart to the badge, so the queue is
  // reachable without leaving the keyboard.
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key.toLowerCase() === "a") {
        e.preventDefault();
        setOpen((v) => !v);
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  function jump(row: { session: SessionView }) {
    setActiveProjectId(row.session.project_id);
    openSessionInLayout(row.session.id);
    setOpen(false);
  }

  return (
    <Popover.Root open={open} onOpenChange={setOpen}>
      <Popover.Trigger
        // 徽章自己会脉动;按钮本体保持安静 —— 一个等待项不该让整条顶栏
        // 变成警报器。`topbar-inbox` 作为钩子留着:徽章的 status-ring
        // 动画由它选中(`.topbar-inbox .count-badge-float`),而
        // `count-badge*` 是和画布工具条共用的。
        className={`topbar-inbox relative flex-none size-control inline-flex items-center justify-center
          rounded-md border border-transparent bg-transparent cursor-pointer
          transition-[background-color,color,border-color] duration-[var(--t-fast)] ease-smooth
          hover:bg-panel-raised hover:border-rule hover:text-text
          data-[popup-open]:bg-panel-raised data-[popup-open]:border-rule data-[popup-open]:text-text
          ${count > 0 ? "text-st-blocked" : "text-muted"}`
          .replace(/\s+/g, " ")
          .trim()}
        aria-label={
          count > 0 ? `${count} 个会话等你处理 (⇧⌘A)` : "没有等待处理的会话 (⇧⌘A)"
        }
        title={
          count > 0 ? `${count} 个会话等你处理 (⇧⌘A)` : "没有等待处理的会话 (⇧⌘A)"
        }
      >
        <InboxIcon />
        {count > 0 && (
          <span className="count-badge count-badge-hot count-badge-float">
            {count}
          </span>
        )}
      </Popover.Trigger>
      <Popover.Portal>
        <Popover.Positioner className={POPOVER_LAYER} sideOffset={8} align="end">
          <Popover.Popup className="w-[380px] max-h-[60vh] overflow-y-auto bg-panel border border-rule-strong rounded-[14px] shadow-menu animate-pop-in origin-top-right">
            <div className="flex items-center pt-3 px-3.5 pb-2">
              <span className="text-[10px] font-semibold tracking-caps uppercase text-st-blocked">
                等你处理{count > 0 ? ` · ${count}` : ""}
              </span>
              <span className="ml-auto font-mono text-[10px] text-whisper">
                ⇧⌘A
              </span>
            </div>
            {count === 0 && done.length === 0 ? (
              <div className="pt-[22px] px-4 pb-[26px] text-center text-[12.5px] text-subtle">
                所有 agent 都在忙自己的事 —— 没有等你的会话。
              </div>
            ) : (
              <>
                {waiting.map((row) => (
                  <button
                    key={row.session.id}
                    type="button"
                    className={`${ITEM} group border-l-st-blocked`}
                    onClick={() => jump(row)}
                  >
                    <StatusDot status="blocked" labelled={false} />
                    <span className="flex-none flex">
                      <AgentIcon
                        icon={agentByProfileId[row.session.agent_profile]?.icon}
                        variant={agentByProfileId[row.session.agent_profile]?.icon_variant}
                        fallbackChar={row.session.title}
                        size={16}
                      />
                    </span>
                    <span className="flex-1 min-w-0 flex flex-col gap-[3px]">
                      <span className={TITLE}>{row.session.title}</span>
                      <span className={META}>
                        {row.projectName}
                        {" · "}
                        {relativeTime(row.session.updated_at_ms)}
                      </span>
                    </span>
                    <ArrowIcon />
                  </button>
                ))}
                {done.length > 0 && (
                  <div className="pt-2 px-3.5 pb-1 border-t border-rule mt-1">
                    <span className="text-[10px] font-semibold tracking-caps uppercase text-st-blocked">
                      刚刚完成
                    </span>
                  </div>
                )}
                {done.map((row) => (
                  <button
                    key={row.session.id}
                    type="button"
                    className={`${ITEM} group border-l-st-blocked opacity-75 hover:opacity-100`}
                    onClick={() => jump(row)}
                  >
                    <StatusDot status="done" labelled={false} />
                    <span className="flex-none flex">
                      <AgentIcon
                        icon={agentByProfileId[row.session.agent_profile]?.icon}
                        variant={agentByProfileId[row.session.agent_profile]?.icon_variant}
                        fallbackChar={row.session.title}
                        size={16}
                      />
                    </span>
                    <span className="flex-1 min-w-0 flex flex-col gap-[3px]">
                      <span className={TITLE}>{row.session.title}</span>
                      <span className={META}>
                        {row.projectName}
                        {" · "}
                        {relativeTime(row.session.updated_at_ms)}
                      </span>
                    </span>
                    <ArrowIcon />
                  </button>
                ))}
              </>
            )}
            <div className="py-[9px] px-3.5 border-t border-rule text-[10.5px]/[1.5] text-whisper">
              ycode 只告诉你谁在等 —— 批准仍在 agent 自己的终端里完成
            </div>
          </Popover.Popup>
        </Popover.Positioner>
      </Popover.Portal>
    </Popover.Root>
  );
}

function relativeTime(ms: number): string {
  const diff = Date.now() - ms;
  if (diff < 60_000) return "刚刚";
  if (diff < 3_600_000) return `${Math.floor(diff / 60_000)} 分钟前`;
  if (diff < 86_400_000) return `${Math.floor(diff / 3_600_000)} 小时前`;
  return `${Math.floor(diff / 86_400_000)} 天前`;
}

function InboxIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M22 12h-6l-2 3h-4l-2-3H2" />
      <path d="M5.5 5h13l3.5 7v5a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2v-5z" />
    </svg>
  );
}

function ArrowIcon() {
  return (
    <svg className="flex-none text-whisper group-hover:text-text" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M5 12h14" />
      <path d="m13 6 6 6-6 6" />
    </svg>
  );
}
