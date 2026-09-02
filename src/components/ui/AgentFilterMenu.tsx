import { Popover } from "@base-ui/react/popover";
import { AgentIcon } from "../AgentIcon";
import type { AgentProfileView } from "../../lib/types";

interface Props {
  agents: AgentProfileView[];
  /// null = 不过滤,显示全部 agent 的会话。
  value: string | null;
  onChange: (agentId: string | null) => void;
}

/// Agent 过滤器。
///
/// 原本是一行图标 pill,每装一个 agent 就多占一格宽 —— 侧栏被压窄时
/// 先是溢出、再是整条横向滚动,而侧栏宽度是用户拖出来的,不该被一个
/// 过滤器绑架。收进下拉后触发器宽度恒定,agent 再多也只是菜单变长。
export function AgentFilterMenu({ agents, value, onChange }: Props) {
  const current = value ? agents.find((a) => a.id === value) : null;
  const label = current?.display_name ?? "全部 agent";

  return (
    <Popover.Root>
      <Popover.Trigger
        className="agent-filter-trigger"
        title={`筛选:${label}`}
        aria-label={`筛选 agent —— 当前 ${label}`}
      >
        {current ? (
          <AgentIcon
            icon={current.icon}
            variant={current.icon_variant}
            fallbackChar={current.display_name}
            size={16}
          />
        ) : (
          <span className="agent-filter-all">ALL</span>
        )}
        <ChevronIcon />
      </Popover.Trigger>
      <Popover.Portal>
        <Popover.Positioner className="popover-layer" sideOffset={6} align="start">
          <Popover.Popup className="agent-filter-menu">
            <Popover.Close
              className={"agent-filter-item" + (value === null ? " is-on" : "")}
              onClick={() => onChange(null)}
            >
              <span className="agent-filter-all">ALL</span>
              <span className="agent-filter-name">全部 agent</span>
            </Popover.Close>
            {agents.map((profile) => (
              <Popover.Close
                key={profile.id}
                className={
                  "agent-filter-item" + (value === profile.id ? " is-on" : "")
                }
                onClick={() => onChange(profile.id)}
              >
                <AgentIcon
                  icon={profile.icon}
                  variant={profile.icon_variant}
                  fallbackChar={profile.display_name}
                  size={16}
                />
                <span className="agent-filter-name">{profile.display_name}</span>
              </Popover.Close>
            ))}
          </Popover.Popup>
        </Popover.Positioner>
      </Popover.Portal>
    </Popover.Root>
  );
}

function ChevronIcon() {
  return (
    <svg
      className="agent-filter-chevron"
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
