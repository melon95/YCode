import { useEffect, useMemo, useState } from "react";
import { Popover } from "@base-ui/react/popover";
import { useStore } from "../lib/store";
import { sessionLight, type SessionView } from "../lib/types";
import { StatusDot } from "./ui/StatusDot";
import { AgentIcon } from "./AgentIcon";

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
        className={`topbar-inbox${count > 0 ? " has-waiting" : ""}`}
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
        <Popover.Positioner className="popover-layer" sideOffset={8} align="end">
          <Popover.Popup className="inbox-popup">
            <div className="inbox-head">
              <span className="eyebrow">等你处理{count > 0 ? ` · ${count}` : ""}</span>
              <span className="inbox-hint">⇧⌘A</span>
            </div>
            {count === 0 && done.length === 0 ? (
              <div className="inbox-empty">
                所有 agent 都在忙自己的事 —— 没有等你的会话。
              </div>
            ) : (
              <>
                {waiting.map((row) => (
                  <button
                    key={row.session.id}
                    type="button"
                    className="inbox-item"
                    onClick={() => jump(row)}
                  >
                    <StatusDot status="blocked" labelled={false} />
                    <span className="inbox-agent">
                      <AgentIcon
                        icon={agentByProfileId[row.session.agent_profile]?.icon}
                        variant={agentByProfileId[row.session.agent_profile]?.icon_variant}
                        fallbackChar={row.session.title}
                        size={16}
                      />
                    </span>
                    <span className="inbox-body">
                      <span className="inbox-title">{row.session.title}</span>
                      <span className="inbox-meta">
                        {row.projectName}
                        {" · "}
                        {relativeTime(row.session.updated_at_ms)}
                      </span>
                    </span>
                    <ArrowIcon />
                  </button>
                ))}
                {done.length > 0 && (
                  <div className="inbox-done-head">
                    <span className="eyebrow">刚刚完成</span>
                  </div>
                )}
                {done.map((row) => (
                  <button
                    key={row.session.id}
                    type="button"
                    className="inbox-item inbox-item-done"
                    onClick={() => jump(row)}
                  >
                    <StatusDot status="done" labelled={false} />
                    <span className="inbox-agent">
                      <AgentIcon
                        icon={agentByProfileId[row.session.agent_profile]?.icon}
                        variant={agentByProfileId[row.session.agent_profile]?.icon_variant}
                        fallbackChar={row.session.title}
                        size={16}
                      />
                    </span>
                    <span className="inbox-body">
                      <span className="inbox-title">{row.session.title}</span>
                      <span className="inbox-meta">
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
            <div className="inbox-foot">
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
    <svg className="inbox-arrow" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M5 12h14" />
      <path d="m13 6 6 6-6 6" />
    </svg>
  );
}
