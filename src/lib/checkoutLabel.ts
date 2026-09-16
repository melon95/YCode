// 「当前指向哪个 checkout」这句话的唯一写法。
//
// 状态栏、Files 卡、变更卡、终端卡的 target picker —— 四处问的是同一个
// 问题,之前各自拼各自的字符串,于是状态栏说 `main repo/feat/sno`、卡片
// chip 说 `main repo`,同一时刻同一目标读起来像两回事。分支名本身带斜杠
// (`feat/sno`),用斜杠再拼一层会让整串读成一条路径,所以主仓库的分支
// 放进括号:`main repo (feat/sno)`。

import { useEffect, useState } from "react";
import type { TFunction } from "i18next";
import { gitBranch } from "./ipc";
import type { SessionView } from "./types";

/// worktree 会话显示 checked-out 的分支(`branch`),不是它分叉自的
/// `base_branch` —— 用户正在浏览的是前者,标成后者会让人以为在改主干。
/// 两者都缺时回落到会话 id 的尾段,至少能把两个 worktree 区分开。
export function worktreeLabel(session: SessionView): string {
  return (
    session.branch ?? session.base_branch ?? `ycode/${session.id.slice(-8)}`
  );
}

/// 完整的 checkout 标签。`session` 为空(或不是 worktree 会话)时表示主
/// 仓库,此时 `mainBranch` 若已知就补在括号里;未知(还没查到 / 非 git
/// 目录)就只说「主仓库」,不显示一个空括号。
export function checkoutLabel(
  t: TFunction,
  session: SessionView | null | undefined,
  mainBranch?: string | null,
): string {
  if (session?.worktree_path) return worktreeLabel(session);
  return mainBranch
    ? t("statusBar.mainRepoOn", { branch: mainBranch })
    : t("statusBar.mainRepo");
}

/// 主仓库当前 checked-out 的分支。切项目 / 切回主仓库时取一次;失败
/// (非 git 目录等)静默返回 null,调用方回落到不带分支的「主仓库」。
///
/// 不做轮询 —— 一根分支名不值得常驻开销,而 checkout 切换本身就是这里
/// 唯一会让答案变化的入口。
///
/// `skip` 给只有一个目标的调用方(状态栏)省掉无谓的一次 IPC:指向
/// worktree 时标签用的是会话自己的分支,主仓库在哪根分支上与显示无关。
/// 右栏有好几张卡各指各的,任一张落在主仓库就需要这个值,那边不传。
export function useMainBranch(
  projectId: string | null | undefined,
  skip = false,
): string | null {
  const [mainBranch, setMainBranch] = useState<string | null>(null);
  useEffect(() => {
    setMainBranch(null);
    if (!projectId || skip) return;
    let cancelled = false;
    gitBranch(projectId)
      .then((info) => {
        if (!cancelled) setMainBranch(info.head);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [projectId, skip]);
  return mainBranch;
}
