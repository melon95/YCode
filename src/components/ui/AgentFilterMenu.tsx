import { Popover } from "@base-ui/react/popover";
import { useTranslation } from "react-i18next";
import { AgentIcon } from "../AgentIcon";
import type { AgentProfileView } from "../../lib/types";
import { MENU_ITEM_ON, MENU_ITEM_REST, MENU_POPUP, POPOVER_LAYER } from "./menuStyles";

/// ALL 用等宽小字,和 agent 图标同宽 —— 触发器不会在两种状态间跳宽。
const ALL_BADGE = "font-mono text-[9px] font-bold tracking-[0.04em]";

/// 这里的条目比 MENU_ITEM 多一个图标列,gap 和 MENU_ITEM 不同,所以没走
/// 共享常量。
const ITEM = `flex items-center gap-[9px] w-full py-[7px] px-[9px] border-none rounded-lg
  bg-none text-[12.5px] text-left cursor-pointer
  transition-colors duration-[var(--t-fast)] ease-smooth hover:bg-panel-raised`
  .replace(/\s+/g, " ");

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
  const { t } = useTranslation();
  const current = value ? agents.find((a) => a.id === value) : null;
  const label = current?.display_name ?? t("ui.allAgents");

  return (
    <Popover.Root>
      <Popover.Trigger
        className="group flex-none ml-auto inline-flex items-center gap-[5px]
          h-control pr-[7px] pl-2 border border-rule rounded-lg bg-none text-muted cursor-pointer
          transition-[background-color,border-color,color] duration-[var(--t-fast)] ease-smooth
          hover:border-rule-strong hover:text-text
          data-[popup-open]:border-rule-strong data-[popup-open]:text-text"
        title={t("ui.filterBy", { label })}
        aria-label={t("ui.filterAgentAria", { label })}
      >
        {current ? (
          <AgentIcon
            icon={current.icon}
            variant={current.icon_variant}
            fallbackChar={current.display_name}
            size={16}
          />
        ) : (
          <span className={ALL_BADGE}>ALL</span>
        )}
        <ChevronIcon />
      </Popover.Trigger>
      <Popover.Portal>
        <Popover.Positioner className={POPOVER_LAYER} sideOffset={6} align="start">
          <Popover.Popup
            className={`${MENU_POPUP} min-w-[180px] max-h-[60vh] overflow-y-auto`}
          >
            <Popover.Close
              className={`${ITEM} ${value === null ? MENU_ITEM_ON : MENU_ITEM_REST}`}
              onClick={() => onChange(null)}
            >
              <span className={ALL_BADGE}>ALL</span>
              <span className="flex-1 min-w-0 overflow-hidden text-ellipsis whitespace-nowrap">
                {t("ui.allAgents")}
              </span>
            </Popover.Close>
            {agents.map((profile) => (
              <Popover.Close
                key={profile.id}
                className={`${ITEM} ${value === profile.id ? MENU_ITEM_ON : MENU_ITEM_REST}`}
                onClick={() => onChange(profile.id)}
              >
                <AgentIcon
                  icon={profile.icon}
                  variant={profile.icon_variant}
                  fallbackChar={profile.display_name}
                  size={16}
                />
                <span className="flex-1 min-w-0 overflow-hidden text-ellipsis whitespace-nowrap">
                  {profile.display_name}
                </span>
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
      // 不写死字色 —— 触发器自己就是 text-muted、hover/展开时转
      // text-text。whisper 会把那份状态反馈整个挡掉,箭头还只剩 1.4
      // 的对比度;继承之后它跟着触发器一起走。
      className="flex-none"
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
