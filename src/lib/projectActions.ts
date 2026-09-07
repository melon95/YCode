// 项目级动作,被侧栏分组头和项目总览共用 —— 两处的删除必须是同一个
// 行为,否则「从哪删的」会决定发生什么,那是最难查的一类不一致。

import { toast } from "./toast";
import { i18next } from "./i18n";
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
    i18next.t("project.repoUntouched", { path: project.repo_path }),
  ];
  if (live.length > 0) {
    // worktree 那半句作为 `suffix` 插进整句里,而不是在外面拼字符串 ——
    // 中文的「,其中 N 个…」挂在句末,英文的从句位置未必相同,交给词条
    // 自己决定往哪儿放。
    const suffix =
      worktrees > 0
        ? i18next.t("project.worktreesTornDown", { count: worktrees })
        : "";
    lines.push(
      i18next.t("project.sessionsClosed", { count: live.length, suffix }),
    );
  }
  lines.push(i18next.t("project.reAddHint"));

  const ok = await confirmDialog({
    title: i18next.t("project.deleteTitle", { name: project.name }),
    message: lines.join("\n"),
    confirmLabel: i18next.t("common.delete"),
    destructive: true,
  });
  if (!ok) return;

  try {
    await deleteProject(projectId);
    useStore.getState().removeProject(projectId);
    toast.success(i18next.t("project.deleted", { name: project.name }));
  } catch (err) {
    toast.danger(i18next.t("project.deleteFailed", { error: err }));
  }
}
