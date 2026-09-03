import type { ReactNode } from "react";
import { Menu } from "@base-ui/react/menu";
import { useStore } from "../../lib/store";

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
        className={`project-picker-trigger${className ? ` ${className}` : ""}`}
        aria-label="切换项目"
        nativeButton={!asSpan}
        render={asSpan ? <span role="button" tabIndex={0} /> : undefined}
        onClick={(e) => e.stopPropagation()}
      >
        {children}
        <ChevronIcon />
      </Menu.Trigger>
      <Menu.Portal>
        <Menu.Positioner className="popover-layer" sideOffset={6} align="start">
          <Menu.Popup className="overflow-menu project-picker-menu">
            {list.map((p) => (
              <Menu.Item
                key={p.id}
                className={
                  "overflow-menu-item" + (p.id === activeProjectId ? " is-on" : "")
                }
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

function ChevronIcon() {
  return (
    <svg
      className="project-picker-chevron"
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
