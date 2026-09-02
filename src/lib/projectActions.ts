// 项目级动作,被侧栏分组头和项目总览共用 —— 两处的删除必须是同一个
// 行为,否则「从哪删的」会决定发生什么,那是最难查的一类不一致。

import { toast } from "./toast";
import { deleteProject } from "./ipc";
import { confirmDialog } from "./confirm";
import { useStore } from "./store";

/// 把项目从 ycode 移除。
///
/// 只动 ycode 自己的记录:会话行被归档、项目行被删。仓库本身、分支和
/// 工作区文件都不碰 —— 这是「从列表里拿掉」,不是「删代码」。后端仍会
/// 拆掉 ycode 自己建的 worktree(那是它的东西),所以确认文案要把这件
/// 事说清楚,而不是笼统地说「不会影响仓库」。
export async function removeProjectWithConfirm(projectId: string): Promise<void> {
  const { projects, sessions } = useStore.getState();
  const project = projects[projectId];
  if (!project) return;

  const live = Object.values(sessions).filter(
    (s) => s.project_id === projectId && s.archived_at_ms == null,
  );
  const worktrees = live.filter((s) => s.worktree_path).length;

  const lines = [
    `仓库目录 ${project.repo_path} 不会被删除,里面的文件和分支都保持原样。`,
  ];
  if (live.length > 0) {
    lines.push(
      `${live.length} 个会话会被结束并归档${
        worktrees > 0
          ? `,其中 ${worktrees} 个的 worktree 会被拆掉(未提交的改动会丢失)`
          : ""
      }。`,
    );
  }
  lines.push("之后可以用「打开项目」重新加回来。");

  const ok = await confirmDialog({
    title: `删除「${project.name}」?`,
    message: lines.join("\n"),
    confirmLabel: "删除",
    destructive: true,
  });
  if (!ok) return;

  try {
    await deleteProject(projectId);
    useStore.getState().removeProject(projectId);
    toast.success(`已删除「${project.name}」`);
  } catch (err) {
    toast.danger(`删除失败:${err}`);
  }
}
