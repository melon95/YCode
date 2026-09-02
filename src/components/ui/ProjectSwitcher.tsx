import { Popover } from "@base-ui/react/popover";
import type { ProjectView } from "../../lib/types";

interface Props {
  projects: ProjectView[];
  activeProjectId: string | null;
  onPick: (projectId: string) => void;
}

/// 当前项目的切换器,坐在侧栏头部下方。
///
/// 下面的分组列表仍然列出所有项目(可以不切项目就翻别人的历史),这里
/// 回答的是另一个问题:「新建会话会落在哪」。那个答案原本只能从状态栏
/// 反推,或者靠点某个会话行顺带改掉 —— 空项目因此根本切不过去。
export function ProjectSwitcher({
  projects,
  activeProjectId,
  onPick,
}: Props) {
  const active = projects.find((p) => p.id === activeProjectId);
  if (projects.length === 0) return null;

  return (
    <Popover.Root>
      <Popover.Trigger
        className="project-switcher"
        title={active ? active.repo_path : "选择项目"}
        aria-label={`当前项目 ${active?.name ?? "未选择"} —— 点击切换`}
      >
        <span className="project-switcher-name">
          {active?.name ?? "选择项目"}
        </span>
        <ChevronIcon />
      </Popover.Trigger>
      <Popover.Portal>
        <Popover.Positioner className="popover-layer" sideOffset={6} align="start">
          <Popover.Popup className="project-menu">
            {projects.map((p) => (
              <Popover.Close
                key={p.id}
                className={
                  "project-menu-item" + (p.id === activeProjectId ? " is-on" : "")
                }
                onClick={() => onPick(p.id)}
                title={p.repo_path}
              >
                <span className="project-menu-name">{p.name}</span>
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
      className="project-switcher-chevron"
      width="11"
      height="11"
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
