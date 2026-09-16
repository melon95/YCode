import { useMemo } from "react";
import { useTranslation } from "react-i18next";
import { checkoutLabel, useMainBranch, worktreeLabel } from "../lib/checkoutLabel";
import { toast } from "../lib/toast";
import { useStore } from "../lib/store";
import type { SessionView } from "../lib/types";

/**
 * Shared workspace switcher for every repo-facing surface in the right pane.
 * Choosing a session worktree here changes Files, Editor, Changes, LSP,
 * terminal links, and the manual terminal as one atomic UI context.
 */
export function WorkspaceTargetPicker({ projectId }: { projectId: string }) {
  const { t } = useTranslation();
  const sessions = useStore((s) => s.sessions);
  const selectedSessionId = useStore(
    (s) => s.workspaceSessionByProject[projectId] ?? null,
  );
  // Only this project's own unsaved edits should block its switch. The live
  // `dirtyFiles` map belongs to the active project, so a background project's
  // stash must never gate us — and vice versa.
  const dirtyCount = useStore((s) =>
    s.activeProjectId === projectId ? Object.keys(s.dirtyFiles).length : 0,
  );
  const setWorkspaceSessionId = useStore((s) => s.setWorkspaceSessionId);
  // 下拉里「主仓库」那一项要带分支,所以无论当前选中的是不是 worktree
  // 都得查 —— 这跟状态栏(只描述当前目标)不同。
  const mainBranch = useMainBranch(projectId);

  const worktrees = useMemo(
    () =>
      Object.values(sessions)
        .filter(
          (session): session is SessionView =>
            session.project_id === projectId && !!session.worktree_path,
        )
        .sort((a, b) => b.updated_at_ms - a.updated_at_ms),
    [sessions, projectId],
  );

  const validSelection = worktrees.some(
    (session) => session.id === selectedSessionId,
  );
  const value = validSelection ? selectedSessionId ?? "" : "";

  return (
    // `workspace-target-picker` 留作钩子:嵌在 canvas 工具条和 panel-card
    // 绑定标签里时要去掉 margin,那两处宿主还没迁移。
    <label
      // 上限从 150px 放宽到 190px:「主仓库」这项带上分支后(`main repo
      // (feat/AM-1241)`)在 150px 里会被截掉右半个括号,读不出分支名。
      className="workspace-target-picker h-8 min-w-0 max-w-[190px] px-2 inline-flex items-center
        flex-[0_1_190px] max-[1200px]:max-w-[150px] max-[1200px]:flex-[0_1_150px]
        border border-rule rounded-sm bg-panel-sunken text-muted
        focus-within:border-accent-half focus-within:shadow-[0_0_0_2px_var(--color-accent-ring)]"
    >
      <select
        className="min-w-0 w-full pr-3.5 pl-0.5 py-0 border-0 outline-0 bg-transparent
          text-text-soft text-[10.5px] font-[560] text-ellipsis cursor-pointer"
        value={value}
        onChange={(event) => {
          const next = event.target.value || null;
          if (dirtyCount > 0) {
            toast.warning(t("editor.saveBeforeSwitch"));
            event.currentTarget.value = value;
            return;
          }
          setWorkspaceSessionId(projectId, next);
        }}
        title={t("ui.workspaceTargetHint")}
        aria-label={t("ui.workspaceTarget")}
      >
        {/* 「主仓库」这一项也带上它 checked-out 的分支 —— 与状态栏、
            其余卡片的绑定 chip 是同一句话。 */}
        <option value="">{checkoutLabel(t, null, mainBranch)}</option>
        {worktrees.map((session) => (
          <option key={session.id} value={session.id}>
            {worktreeLabel(session)}
          </option>
        ))}
      </select>
    </label>
  );
}
