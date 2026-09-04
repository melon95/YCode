import type { ReactNode } from "react";
import { Menu } from "@base-ui/react/menu";
import { useStore } from "../../lib/store";
import {
  MENU_ITEM,
  MENU_ITEM_ON,
  MENU_ITEM_REST,
  MENU_POPUP,
  POPOVER_LAYER,
} from "./menuStyles";

interface Props {
  /// 触发器的可见内容 —— 通常就是那处原本已经在显示项目名的文本。
  children: ReactNode;
  className?: string;
  /// 渲染成 <span role="button">,给已经在 <button> 里的位置用。
  asSpan?: boolean;
}

/// 把「已经在显示项目名的地方」变成可点的项目选择器。
///
/// 状态栏和 composer 标题本来就各写着一次当前项目名,却都只是死文本 ——
/// 看得到、点不动。与其另加一个控件(那会让同一个名字在相邻两行出现
/// 两次),不如让这两处文本自己可点。
export function ProjectPickerMenu({ children, className, asSpan }: Props) {
  const projects = useStore((s) => s.projects);
  const projectOrder = useStore((s) => s.projectOrder);
  const activeProjectId = useStore((s) => s.activeProjectId);
  const setActiveProjectId = useStore((s) => s.setActiveProjectId);
  const lockedProjectId = useStore((s) => s.lockedProjectId);
  const lockedByOtherWindows = useStore((s) => s.lockedByOtherWindows);

  // 与侧栏同一套可见性规则:分离窗口只看锁定项目,主窗口隐藏被其他
  // 窗口占用的。
  const orderById = new Map(projectOrder.map((id, i) => [id, i]));
  const list = Object.values(projects)
    .slice()
    .sort((a, b) => {
      const ao = orderById.get(a.id) ?? Number.MAX_SAFE_INTEGER;
      const bo = orderById.get(b.id) ?? Number.MAX_SAFE_INTEGER;
      return ao - bo || a.created_at_ms - b.created_at_ms;
    })
    .filter((p) =>
      lockedProjectId ? p.id === lockedProjectId : !lockedByOtherWindows[p.id],
    );

  // 锁定窗口里切不了项目,那就别把文本伪装成可点的。
  if (lockedProjectId || list.length < 2) return <>{children}</>;

  return (
    <Menu.Root>
      <Menu.Trigger
        // 触发器保持成原来那行文字的样子:继承所在位置的排版(状态栏是
        // 10px 等宽,composer eyebrow 是 9.5px 字距放开的小型大写),只在
        // hover 时透出一点底色 —— 让它可点,但不要在版面上多出一个控件。
        className={`group inline-flex items-center gap-[3px] py-px px-1 -my-px -mx-0.5
          border-none rounded-[5px] bg-none font-[inherit] tracking-[inherit]
          [text-transform:inherit] text-[inherit] cursor-pointer
          transition-colors duration-[var(--t-fast)] ease-smooth
          hover:bg-panel-raised data-[popup-open]:bg-panel-raised
          ${className ?? ""}`
          .replace(/\s+/g, " ")
          .trim()}
        aria-label="切换项目"
        nativeButton={!asSpan}
        render={asSpan ? <span role="button" tabIndex={0} /> : undefined}
        onClick={(e) => e.stopPropagation()}
      >
        {children}
        <ChevronIcon />
      </Menu.Trigger>
      <Menu.Portal>
        <Menu.Positioner className={POPOVER_LAYER} sideOffset={6} align="start">
          <Menu.Popup className={`${MENU_POPUP} min-w-[190px]`}>
            {list.map((p) => (
              <Menu.Item
                key={p.id}
                className={`${MENU_ITEM} ${
                  p.id === activeProjectId ? MENU_ITEM_ON : MENU_ITEM_REST
                }`}
                onClick={() => setActiveProjectId(p.id)}
              >
                {p.name}
              </Menu.Item>
            ))}
          </Menu.Popup>
        </Menu.Positioner>
      </Menu.Portal>
    </Menu.Root>
  );
}

/// 箭头平时几乎看不见,hover 才实起来 —— 常驻一个实心箭头会让这行文字
/// 看着像个下拉框控件,而它首先是一句话。
function ChevronIcon() {
  return (
    <svg
      className="flex-none opacity-0 transition-opacity duration-[var(--t-fast)] ease-smooth
        group-hover:opacity-55 group-data-[popup-open]:opacity-55"
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
