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
import { useStore } from "./store";
import type { SessionView } from "./types";

/// worktree 会话显示 checked-out 的分支(`branch`),不是它分叉自的
/// `base_branch` —— 用户正在浏览的是前者,标成后者会让人以为在改主干。
///
/// 所以兜底**不**走 `base_branch`(合并两处旧实现时一度混进来过):后端
/// 建会话时 `worktree_path` 与 `branch` 是一起写的,缺 `branch` 的 worktree
/// 会话根本不存在,那一档是死代码;而万一真走到,一个标着 `main` 的选项
/// 会紧挨着「主仓库 (main)」出现,两行看着一样却指向不同的 checkout。
/// 宁可回落到会话 id 的尾段 —— 丑,但至少不骗人。
export function worktreeLabel(session: SessionView): string {
  return session.branch ?? `ycode/${session.id.slice(-8)}`;
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

/// 主仓库当前 checked-out 的分支。失败(非 git 目录等)静默返回 null,
/// 调用方回落到不带分支的「主仓库」。
///
/// 不做轮询 —— 一根分支名不值得常驻开销。会让答案变化的入口有两个:切
/// 项目,以及在变更面板里切分支;后者靠 store 的 `branchEpoch` 通知过来
/// (见 ChangesPanel 的 doCheckout)。漏掉它的话 picker 里那行「主仓库
/// (xxx)」会一直标着旧分支 —— 它是个控件,标错等于骗人。
///
/// `skip` 给只有一个目标的调用方(状态栏)省掉无谓的一次 IPC:指向
/// worktree 时标签用的是会话自己的分支,主仓库在哪根分支上与显示无关。
/// 右栏有好几张卡各指各的,任一张落在主仓库就需要这个值,那边不传。
export function useMainBranch(
  projectId: string | null | undefined,
  skip = false,
): string | null {
  const [mainBranch, setMainBranch] = useState<string | null>(null);
  const branchEpoch = useStore((s) => s.branchEpoch);
  useEffect(() => {
    setMainBranch(null);
    if (!projectId || skip) return;
    let cancelled = false;
    gitBranch(projectId)
      .then((info) => {
        // detached 时 `head` 是一段短 SHA,照原样放进「主仓库 (xxx)」会被
        // 读成分支名。这个括号只表达「在哪根分支上」,答案是「不在任何
        // 分支上」时就不说 —— 退回不带括号的「主仓库」。真要看 HEAD,
        // 变更面板有完整的 detached 提示。
        if (!cancelled) setMainBranch(info.detached ? null : info.head);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [projectId, skip, branchEpoch]);
  return mainBranch;
}
