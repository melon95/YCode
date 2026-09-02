import type { ReactNode } from "react";
import { Menu } from "@base-ui/react/menu";

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
        className={"overflow-menu-trigger" + (hoverOnly ? " is-hover-only" : "")}
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
        <Menu.Positioner className="popover-layer" sideOffset={4} align="end">
          <Menu.Popup className="overflow-menu">
            {actions.map((a, i) => (
              <Menu.Item
                key={a.label}
                className={
                  "overflow-menu-item" +
                  (a.destructive ? " is-destructive" : "") +
                  // 破坏性动作与上面的常规动作之间拉一道线,免得手滑
                  // 从「重命名」直接划到「删除」。
                  (a.destructive && i > 0 && !actions[i - 1].destructive
                    ? " has-rule"
                    : "")
                }
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
