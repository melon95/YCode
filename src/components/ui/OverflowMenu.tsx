import type { ReactNode } from "react";
import { Menu } from "@base-ui/react/menu";
import {
  MENU_ITEM,
  MENU_ITEM_DANGER,
  MENU_ITEM_REST,
  MENU_ITEM_RULE,
  MENU_POPUP,
  POPOVER_LAYER,
} from "./menuStyles";

export interface MenuAction {
  label: string;
  onClick: () => void;
  /// 红色文字 + 与上一组之间的分隔线。留给会真正丢东西的动作。
  destructive?: boolean;
  disabled?: boolean;
}

interface Props {
  actions: MenuAction[];
  /// 无障碍名字,例如「stepLang 的更多操作」—— 一行里可能有好几个 ⋮,
  /// 光说「更多」读屏时分不清是哪一个的。
  label: string;
  /// 行内的 ⋮ 平时隐身,hover 或菜单打开时才显形;总览卡片那种常驻的
  /// 传 false。
  hoverOnly?: boolean;
  /// 触发器渲染成 <span role="button"> 而不是 <button>。给本身已经是
  /// <button> 的容器用(总览卡片)—— button 嵌 button 是无效 HTML,浏览器
  /// 会把内层拆出去,点击行为随之乱掉。
  asSpan?: boolean;
  children?: ReactNode;
}

/// 行尾的 ⋮ 溢出菜单。
///
/// 归档/删除这类低频又不可逆的动作不该常驻在行里:常驻就得给它们留
/// 位置,挤掉标题;而且越顺手越容易误触。收进 ⋮ 后一行只多一个 20px
/// 的图标,且必须两步才能触发。
export function OverflowMenu({
  actions,
  label,
  hoverOnly = true,
  asSpan = false,
  children,
}: Props) {
  if (actions.length === 0) return null;
  return (
    <Menu.Root>
      <Menu.Trigger
        // 平时隐身,鼠标落在所在的那一行(侧栏项目头 / 会话行 / 总览卡,
        // 都标了 `group`)时才浮出来。隐身用 opacity 而不是 display:none
        // —— 后者会让行在 hover 时突然变宽,文字跟着抖一下。
        className={`flex-none inline-flex items-center justify-center
          size-[22px] p-0 border-none rounded-md bg-none text-subtle cursor-pointer
          transition-[opacity,background-color,color] duration-[var(--t-fast)] ease-smooth
          hover:bg-panel-raised hover:text-text
          data-[popup-open]:bg-panel-raised data-[popup-open]:text-text
          data-[popup-open]:opacity-100 focus-visible:opacity-100
          ${hoverOnly ? "opacity-0 group-hover:opacity-100" : ""}`
          .replace(/\s+/g, " ")
          .trim()}
        aria-label={label}
        title={label}
        nativeButton={!asSpan}
        render={asSpan ? <span role="button" tabIndex={0} /> : undefined}
        // 行本身通常也是个按钮(点了会打开项目/会话),别让点 ⋮ 顺带把
        // 行也点了。
        onClick={(e) => e.stopPropagation()}
        onMouseDown={(e) => e.stopPropagation()}
      >
        {children ?? <DotsIcon />}
      </Menu.Trigger>
      <Menu.Portal>
        <Menu.Positioner className={POPOVER_LAYER} sideOffset={4} align="end">
          <Menu.Popup className={`${MENU_POPUP} min-w-[168px]`}>
            {actions.map((a, i) => (
              <Menu.Item
                key={a.label}
                className={[
                  MENU_ITEM,
                  a.destructive ? MENU_ITEM_DANGER : MENU_ITEM_REST,
                  a.destructive &&
                    i > 0 &&
                    !actions[i - 1].destructive &&
                    MENU_ITEM_RULE,
                ]
                  .filter(Boolean)
                  .join(" ")}
                disabled={a.disabled}
                onClick={a.onClick}
              >
                {a.label}
              </Menu.Item>
            ))}
          </Menu.Popup>
        </Menu.Positioner>
      </Menu.Portal>
    </Menu.Root>
  );
}

function DotsIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor" aria-hidden>
      <circle cx="12" cy="5" r="1.7" />
      <circle cx="12" cy="12" r="1.7" />
      <circle cx="12" cy="19" r="1.7" />
    </svg>
  );
}
