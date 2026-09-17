// Unstaged working-tree changes for the active project. Two-column layout:
// left lists files (flat list OR collapsible tree, user-toggled), right
// renders the selected file's unified diff via react-diff-view. Refreshes on
// tab open + manual refresh button. We deliberately don't auto-refresh on fs
// change yet — git index churn during a `npm install` could re-render dozens
// of times a second.

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { TFunction } from "i18next";
import { useTranslation } from "react-i18next";
import {
  Decoration,
  Diff,
  Hunk,
  parseDiff,
  type FileData,
  type HunkData,
} from "react-diff-view";
import "react-diff-view/style/index.css";
import {
  gitApplyHunk,
  gitBranch,
  gitCommit,
  gitDiffFile,
  gitDiscardFile,
  gitFetch,
  gitPull,
  gitPush,
  gitStageFile,
  gitStatus,
  gitUnstageFile,
} from "../lib/ipc";
import { confirmDialog } from "../lib/confirm";
import { extractHunkPatch, hunkTotals } from "../lib/diffReview";
import { useStore } from "../lib/store";
import type {
  GitBranchInfo,
  GitDiffSource,
  GitFileDiff,
  GitFileChange,
  GitFileStatus,
  GitHunkAction,
} from "../lib/types";

type ViewMode = "list" | "tree";
type DiffLayout = "unified" | "split";

const EMPTY_DIFF: GitFileDiff = { patch: "", source: "unstaged" };

// Strip the internal "bad input:" prefix that IpcError::BadInput serializes
// with, so the panel surfaces only the actionable git message.
function cleanError(e: unknown): string {
  return String(e).replace(/^bad input:\s*/i, "");
}

export function ChangesPanel({
  projectId,
  sessionId,
  onFileCount,
}: {
  projectId: string;
  sessionId?: string;
  /// 变更文件数上报回调:文件列表每次刷新都通知宿主(RightPane),
  /// 供卡片头计数与画布工具条角标使用 —— 数字只在面板挂载期间可信。
  onFileCount?: (count: number) => void;
}) {
  const { t } = useTranslation();
  const [changes, setChanges] = useState<GitFileChange[]>([]);
  const [branch, setBranch] = useState<GitBranchInfo | null>(null);
  const [selected, setSelected] = useState<string | null>(null);
  const [fileDiff, setFileDiff] = useState<GitFileDiff>(EMPTY_DIFF);
  const [diffLayout, setDiffLayout] = useState<DiffLayout>("unified");
  const [diffRevision, setDiffRevision] = useState(0);
  const [hunkOp, setHunkOp] = useState<string | null>(null);
  const [loadingList, setLoadingList] = useState(false);
  const [loadingDiff, setLoadingDiff] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [viewMode, setViewMode] = useState<ViewMode>("tree");
  // Set of directory paths that are *collapsed*. Default empty = all expanded.
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());
  const [committing, setCommitting] = useState(false);
  // Remote/branch state. `remoteOp` gates the Fetch/Pull/Push cluster so only
  // one network op runs at a time; the branch menu lazy-loads its list on open.
  const [remoteOp, setRemoteOp] = useState<null | "fetch" | "pull" | "push">(
    null,
  );
  // The target is owned by RightPane's shared Workspace picker. Every git
  // operation therefore reads the same checkout as Files, Editor, and LSP.
  const treeSid = sessionId;
  const openFile = useStore((s) => s.openFile);
  const setRightTab = useStore((s) => s.setRightTab);

  // Monotonic id for the in-flight refresh. Switching trees fires a new refresh
  // before the previous one's async git calls resolve; without this guard a
  // slower earlier response (e.g. a worktree under Application Support, which is
  // slower than the main repo) can land *after* the newer one and clobber it —
  // showing the old tree's branch/files. Each result checks it's still current.
  const reqSeq = useRef(0);

  // 每次文件列表变化就把数量上报给宿主(onFileCount 见 props 注释)。
  useEffect(() => {
    onFileCount?.(changes.length);
  }, [changes.length, onFileCount]);

  const refresh = useCallback(() => {
    const my = ++reqSeq.current;
    const fresh = () => my === reqSeq.current;
    setLoadingList(true);
    setError(null);
    gitStatus(projectId, treeSid)
      .then((rows) => {
        if (!fresh()) return;
        setChanges(rows);
        setSelected((cur) => {
          if (cur && rows.some((r) => r.path === cur)) return cur;
          return rows[0]?.path ?? null;
        });
        setDiffRevision((revision) => revision + 1);
      })
      .catch((e) => {
        if (fresh()) setError(cleanError(e));
      })
      .finally(() => {
        if (fresh()) setLoadingList(false);
      });
    // Branch context is independent of the file list — fetch it alongside,
    // and don't let its failure (e.g. not a git repo) clobber the file view.
    gitBranch(projectId, treeSid)
      .then((b) => {
        if (fresh()) setBranch(b);
      })
      .catch(() => {
        if (fresh()) setBranch(null);
      });
  }, [projectId, treeSid]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  useEffect(() => {
    if (!selected) {
      setFileDiff(EMPTY_DIFF);
      return;
    }
    let cancelled = false;
    setLoadingDiff(true);
    gitDiffFile(projectId, selected, treeSid)
      .then((detail) => {
        if (!cancelled) setFileDiff(detail);
      })
      .catch((e) => {
        if (!cancelled) {
          setFileDiff(EMPTY_DIFF);
          setError(cleanError(e));
        }
      })
      .finally(() => {
        if (!cancelled) setLoadingDiff(false);
      });
    return () => {
      cancelled = true;
    };
  }, [diffRevision, projectId, selected, treeSid]);

  const files: FileData[] = useMemo(() => {
    if (!fileDiff.patch) return [];
    try {
      return parseDiff(fileDiff.patch);
    } catch {
      return [];
    }
  }, [fileDiff.patch]);

  // Binary/unsupported files (images, etc.) come back as a patch with no
  // hunks — react-diff-view renders nothing, leaving the pane blank. Detect
  // "we have a diff but nothing to render" so we can show a notice instead.
  const hasRenderableDiff = useMemo(
    () => files.some((f) => f.hunks.length > 0),
    [files],
  );

  const tree = useMemo(() => buildTree(changes), [changes]);

  const toggleDir = (path: string) =>
    setCollapsed((prev) => {
      const next = new Set(prev);
      if (next.has(path)) next.delete(path);
      else next.add(path);
      return next;
    });

  /// 返回 true 表示提交成功,CommitBox 据此清空自己的输入框。
  const doCommit = async (message: string) => {
    if (changes.length === 0 || committing) return false;
    setCommitting(true);
    setError(null);
    try {
      await gitCommit(projectId, message, treeSid);
      refresh();
      return true;
    } catch (e) {
      setError(cleanError(e));
      return false;
    } finally {
      setCommitting(false);
    }
  };

  // Run one remote op (fetch/pull/push), refreshing the panel on success so the
  // header's ahead/behind counts reflect the new state. `remoteOp` blocks the
  // whole cluster meanwhile.
  const runRemote = (op: "fetch" | "pull" | "push", fn: () => Promise<void>) => {
    if (remoteOp) return;
    setRemoteOp(op);
    setError(null);
    fn()
      .then(refresh)
      .catch((e) => setError(cleanError(e)))
      .finally(() => setRemoteOp(null));
  };

  // Aggregate +/− across every change — mirrors the header total in the
  // reference design.
  const totals = useMemo(
    () =>
      changes.reduce(
        (acc, c) => {
          acc.additions += c.additions;
          acc.deletions += c.deletions;
          return acc;
        },
        { additions: 0, deletions: 0 },
      ),
    [changes],
  );

  // Stage/unstage flip the index for one file. The checkbox is controlled by
  // `change.staged`, so we optimistically flip it locally *before* the async
  // git call — otherwise React snaps the box back to its old value until the
  // refresh lands, which reads as a flicker. On success we refresh to reconcile
  // counts; on failure we roll the flag back and surface the error.
  const toggleStage = (change: GitFileChange) => {
    const nextStaged = !change.staged;
    setChanges((prev) =>
      prev.map((c) =>
        c.path === change.path ? { ...c, staged: nextStaged } : c,
      ),
    );
    const op = nextStaged
      ? gitStageFile(projectId, change.path, treeSid)
      : gitUnstageFile(projectId, change.path, treeSid);
    op.then(refresh).catch((e) => {
      setChanges((prev) =>
        prev.map((c) =>
          c.path === change.path ? { ...c, staged: change.staged } : c,
        ),
      );
      setError(String(e));
    });
  };

  const discardFile = async (change: GitFileChange) => {
    const ok = await confirmDialog({
      title: t("changes.discardFileTitle", { name: basename(change.path) }),
      message:
        change.status === "untracked" || change.status === "added"
          ? t("changes.discardUntrackedBody")
          : t("changes.discardTrackedBody"),
      confirmLabel: t("changes.discard"),
      destructive: true,
    });
    if (!ok) return;
    gitDiscardFile(projectId, change.path, treeSid)
      .then(refresh)
      .catch((e) => setError(cleanError(e)));
  };

  const applyHunk = async (
    hunk: HunkData,
    hunkIndex: number,
    action: GitHunkAction,
  ) => {
    if (
      !selected ||
      fileDiff.source === "branch" ||
      fileDiff.source === "checkpoint"
    ) {
      return;
    }
    if (action === "discard") {
      const ok = await confirmDialog({
        title: t("changes.discardHunkTitle", { name: basename(selected) }),
        message: t("changes.discardHunkBody"),
        confirmLabel: t("changes.discardHunk"),
        destructive: true,
      });
      if (!ok) return;
    }
    const operationKey = `${selected}:${hunk.content}:${action}`;
    setHunkOp(operationKey);
    setError(null);
    try {
      await gitApplyHunk(
        projectId,
        selected,
        extractHunkPatch(fileDiff.patch, hunkIndex),
        action,
        treeSid,
      );
      refresh();
    } catch (e) {
      setError(cleanError(e));
    } finally {
      setHunkOp(null);
    }
  };

  const openSelectedFile = () => {
    if (!selected) return;
    openFile(selected);
    setRightTab("editor");
  };

  return (
    <div className="changes-panel">
      <div className="changes-panel-header">
        {/* 分支名不在这里重复:卡片标题那行的绑定 chip 已经写着「主仓库
            (分支)」。文件数和 +/− 是同一句话的两半,一起放在这行。领先/
            落后也不单列 —— pull / push 按钮上的角标就是它。 */}
        {/* detached 是唯一一条卡片标题说不出来的状态:那边的 chip 在
            detached 时只会退回不带括号的「主仓库」。别的都不重复。 */}
        {branch?.detached && (
          <span className="changes-panel-detached">
            {t("changes.detachedHead", { head: branch.head })}
          </span>
        )}
        <span className="changes-panel-count">
          {changes.length === 0
            ? t("changes.noChanges")
            : t("panels.fileCount", { count: changes.length })}
          {changes.length > 0 &&
            (totals.additions > 0 || totals.deletions > 0) && (
              <span className="changes-panel-totals">
                {totals.additions > 0 && (
                  <span className="diff-add">+{totals.additions}</span>
                )}
                {totals.deletions > 0 && (
                  <span className="diff-del">−{totals.deletions}</span>
                )}
              </span>
            )}
        </span>
        <div className="changes-panel-remote" role="group" aria-label={t("changes.remoteOps")}>
          <button
            type="button"
            className="changes-panel-remote-btn"
            onClick={() => runRemote("fetch", () => gitFetch(projectId, treeSid))}
            disabled={!branch || remoteOp !== null}
            aria-label={t("changes.fetch")}
            title={t("changes.fetchHint")}
          >
            <span className={remoteOp === "fetch" ? "spin" : undefined}>
              <FetchIcon />
            </span>
          </button>
          <button
            type="button"
            className="changes-panel-remote-btn"
            onClick={() => runRemote("pull", () => gitPull(projectId, treeSid))}
            disabled={
              !branch || branch.detached || !branch.upstream || remoteOp !== null
            }
            aria-label={t("changes.pull")}
            title={
              branch && !branch.detached && !branch.upstream
                ? t("changes.noUpstreamToPull")
                : t("changes.pullHint")
            }
          >
            <span className={remoteOp === "pull" ? "spin" : undefined}>
              <PullIcon />
            </span>
            {branch && branch.behind > 0 && (
              <span className="changes-panel-remote-badge">{branch.behind}</span>
            )}
          </button>
          <button
            type="button"
            className="changes-panel-remote-btn"
            onClick={() => runRemote("push", () => gitPush(projectId, treeSid))}
            disabled={!branch || branch.detached || remoteOp !== null}
            aria-label={t("changes.push")}
            title={
              branch && !branch.detached && !branch.upstream
                ? t("changes.publishBranch")
                : t("changes.pushHint")
            }
          >
            <span className={remoteOp === "push" ? "spin" : undefined}>
              <PushIcon />
            </span>
            {branch && branch.ahead > 0 && (
              <span className="changes-panel-remote-badge">{branch.ahead}</span>
            )}
          </button>
        </div>
        <div className="changes-panel-mode" role="tablist" aria-label={t("changes.viewMode")}>
          <button
            type="button"
            className={
              "changes-panel-mode-btn" + (viewMode === "list" ? " active" : "")
            }
            onClick={() => setViewMode("list")}
            aria-label={t("changes.listView")}
            aria-selected={viewMode === "list"}
            role="tab"
            title={t("changes.listView")}
          >
            <ListIcon />
          </button>
          <button
            type="button"
            className={
              "changes-panel-mode-btn" + (viewMode === "tree" ? " active" : "")
            }
            onClick={() => setViewMode("tree")}
            aria-label={t("changes.treeView")}
            aria-selected={viewMode === "tree"}
            role="tab"
            title={t("changes.treeView")}
          >
            <TreeIcon />
          </button>
        </div>
        <button
          type="button"
          className="changes-panel-refresh"
          onClick={refresh}
          aria-label={t("common.refresh")}
          title={t("common.refresh")}
        >
          <RefreshIcon />
        </button>
      </div>
      <CommitBox
        canCommit={changes.length > 0}
        committing={committing}
        branch={branch}
        onCommit={doCommit}
      />
      <div className="changes-panel-body">
        <div className="changes-file-pane">
          {loadingList && changes.length === 0 && (
            <div className="changes-empty">{t("common.loading")}</div>
          )}
          {!loadingList && changes.length === 0 && !error && (
            <div className="changes-empty">
              {t("changes.workingTreeClean")}
            </div>
          )}
          {error && <div className="changes-empty error">{error}</div>}
          {changes.length > 0 && viewMode === "list" && (
            <ul className="changes-file-list" role="listbox" aria-label={t("changes.changedFiles")}>
              {changes.map((c) => (
                <li key={c.path}>
                  <FileRow
                    change={c}
                    active={c.path === selected}
                    onClick={() => setSelected(c.path)}
                    onToggleStage={() => toggleStage(c)}
                    onDiscard={() => discardFile(c)}
                    showDir
                    indent={0}
                  />
                </li>
              ))}
            </ul>
          )}
          {changes.length > 0 && viewMode === "tree" && (
            <ul className="changes-file-tree" role="tree" aria-label={t("changes.changedFiles")}>
              {tree.map((node) => (
                <TreeRow
                  key={nodeKey(node)}
                  node={node}
                  depth={0}
                  selected={selected}
                  collapsed={collapsed}
                  onToggleDir={toggleDir}
                  onSelectFile={setSelected}
                  onToggleStage={toggleStage}
                  onDiscard={discardFile}
                />
              ))}
            </ul>
          )}
        </div>
        <div className="changes-diff-pane">
          <div className="changes-diff-header">
            <div className="changes-diff-title">
              <span>{selected ? basename(selected) : t("changes.review")}</span>
              {selected && dirname(selected) && (
                <span className="changes-diff-directory">{dirname(selected)}</span>
              )}
              {selected && (
                <span className={`changes-diff-source source-${fileDiff.source}`}>
                  {diffSourceLabel(fileDiff.source, t)}
                </span>
              )}
            </div>
            <div className="changes-diff-actions">
              <div className="changes-diff-layout" role="group" aria-label={t("changes.diffLayout")}>
                <button
                  type="button"
                  className={diffLayout === "unified" ? "active" : ""}
                  onClick={() => setDiffLayout("unified")}
                  aria-label={t("changes.unified")}
                  title={t("changes.unified")}
                >
                  <UnifiedDiffIcon />
                </button>
                <button
                  type="button"
                  className={diffLayout === "split" ? "active" : ""}
                  onClick={() => setDiffLayout("split")}
                  aria-label={t("changes.sideBySide")}
                  title={t("changes.sideBySide")}
                >
                  <SplitDiffIcon />
                </button>
              </div>
              <button
                type="button"
                className="changes-open-file"
                onClick={openSelectedFile}
                disabled={!selected}
              >
                {t("changes.openFile")}
              </button>
            </div>
          </div>
          <div className="changes-diff-view">
            {loadingDiff && <div className="changes-empty">{t("changes.loadingDiff")}</div>}
            {!loadingDiff && !selected && (
              <div className="changes-empty">{t("changes.pickAFile")}</div>
            )}
            {!loadingDiff && selected && !hasRenderableDiff && (
              <div className="changes-empty">
                {fileDiff.patch
                  ? t("changes.previewUnsupported")
                  : t("changes.nothingToShow")}
              </div>
            )}
            {!loadingDiff &&
              hasRenderableDiff &&
              files.map((file, fileIndex) => (
                <Diff
                  key={`${file.oldPath}:${file.newPath}:${fileIndex}`}
                  viewType={diffLayout}
                  diffType={file.type}
                  hunks={file.hunks}
                >
                  {(hunks) =>
                    hunks.flatMap((hunk, hunkIndex) => [
                      <Decoration key={`toolbar:${hunk.content}`}>
                        <HunkToolbar
                          hunk={hunk}
                          source={fileDiff.source}
                          busy={hunkOp !== null}
                          onAction={(action) =>
                            applyHunk(hunk, hunkIndex, action)
                          }
                        />
                      </Decoration>,
                      <Hunk key={hunk.content} hunk={hunk} />,
                    ])
                  }
                </Diff>
              ))}
          </div>
        </div>
      </div>
    </div>
  );
}

function HunkToolbar({
  hunk,
  source,
  busy,
  onAction,
}: {
  hunk: HunkData;
  source: GitDiffSource;
  busy: boolean | undefined;
  onAction: (action: GitHunkAction) => void;
}) {
  const { t } = useTranslation();
  const totals = hunkTotals(hunk);
  return (
    <div className="changes-hunk-toolbar">
      <span className="changes-hunk-location">{hunk.content}</span>
      <span className="changes-hunk-totals">
        {totals.additions > 0 && <span className="diff-add">+{totals.additions}</span>}
        {totals.deletions > 0 && <span className="diff-del">−{totals.deletions}</span>}
      </span>
      <span className="changes-hunk-spacer" />
      {source === "unstaged" && (
        <>
          <button type="button" disabled={busy} onClick={() => onAction("discard")}>
            {t("changes.discardHunk")}
          </button>
          <button
            type="button"
            className="primary"
            disabled={busy}
            onClick={() => onAction("stage")}
          >
            {busy ? t("changes.applying") : t("changes.stageHunk")}
          </button>
        </>
      )}
      {source === "staged" && (
        <button
          type="button"
          className="primary"
          disabled={busy}
          onClick={() => onAction("unstage")}
        >
          {busy ? t("changes.applying") : t("changes.unstageHunk")}
        </button>
      )}
      {source === "branch" && (
        <span className="changes-hunk-readonly">{t("changes.committedChange")}</span>
      )}
      {source === "checkpoint" && (
        <span className="changes-hunk-readonly">{t("changes.turnSnapshot")}</span>
      )}
    </div>
  );
}

function diffSourceLabel(source: GitDiffSource, t: TFunction): string {
  switch (source) {
    case "staged":
      return t("changes.sourceStaged");
    case "branch":
      return t("changes.sourceBranch");
    case "checkpoint":
      return t("changes.sourceTurn");
    default:
      return t("changes.sourceUnstaged");
  }
}

/// 提交框自带输入状态。
///
/// 它原先是 ChangesPanel 的一个 `commitMsg` state —— 每敲一个字符,整张
/// 面板跟着重渲染一次,包括那棵上千行的文件树和右边的 diff 视图;文件一多
/// 打字就一顿一顿的。把输入圈在这个组件里,击键只重渲染它自己。
function CommitBox({
  canCommit,
  committing,
  branch,
  onCommit,
}: {
  /// 有没有可提交的改动(消息是否为空由这里自己判断)。
  canCommit: boolean;
  committing: boolean;
  branch: GitBranchInfo | null;
  onCommit: (message: string) => Promise<boolean>;
}) {
  const { t } = useTranslation();
  const [msg, setMsg] = useState("");
  const trimmed = msg.trim();
  const ready = canCommit && trimmed.length > 0 && !committing;

  const commit = () => {
    if (!ready) return;
    void onCommit(trimmed).then((ok) => {
      if (ok) setMsg("");
    });
  };

  return (
    <div className="changes-commit-box">
      <textarea
        className="changes-commit-input"
        value={msg}
        onChange={(e) => setMsg(e.target.value)}
        onKeyDown={(e) => {
          // ⌘/Ctrl+Enter commits, matching the VS Code affordance.
          if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
            e.preventDefault();
            commit();
          }
        }}
        placeholder={t("changes.commitMessage")}
        // 快捷键提示挂 title 而不是 placeholder:输入框只有一行高,
        // 英文的「Commit message · ⌘⏎ to commit to main」会换行,
        // 第二行被 min-height 裁掉。
        title={
          branch && !branch.detached
            ? t("changes.commitHintTo", { branch: branch.head })
            : t("changes.commitHint")
        }
        rows={1}
        aria-label={t("changes.commitMessageAria")}
      />
      <button
        type="button"
        className="changes-commit-btn"
        onClick={commit}
        disabled={!ready}
        title={
          !canCommit
            ? t("changes.nothingToCommit")
            : trimmed.length === 0
              ? t("changes.needCommitMessage")
              : t("changes.commitAll")
        }
      >
        <CommitIcon />
        <span>{committing ? t("changes.committing") : t("common.commit")}</span>
      </button>
    </div>
  );
}

/// ---- Tree model ----
///
/// `dir` nodes carry a compressed label like "src/components" when the
/// directory has a single subdirectory child (VS Code-style). `path` is the
/// full repo-relative dir path used as the collapse key.

type TreeNode =
  | { kind: "file"; change: GitFileChange }
  | { kind: "dir"; path: string; label: string; children: TreeNode[] };

function buildTree(changes: GitFileChange[]): TreeNode[] {
  interface MutDir {
    label: string;
    path: string;
    dirs: Map<string, MutDir>;
    files: GitFileChange[];
  }
  const root: MutDir = { label: "", path: "", dirs: new Map(), files: [] };

  for (const c of changes) {
    const parts = c.path.split("/");
    const fileName = parts.pop()!;
    let cursor = root;
    let acc = "";
    for (const seg of parts) {
      acc = acc ? `${acc}/${seg}` : seg;
      let next = cursor.dirs.get(seg);
      if (!next) {
        next = { label: seg, path: acc, dirs: new Map(), files: [] };
        cursor.dirs.set(seg, next);
      }
      cursor = next;
    }
    cursor.files.push({ ...c, path: c.path });
    // Keep file's local name implicit via basename(c.path).
    void fileName;
  }

  // Convert MutDir → TreeNode[], applying path compression: a dir with exactly
  // one subdir and no files collapses into its child's label ("a/b/c").
  const toNodes = (d: MutDir): TreeNode[] => {
    // Sort: dirs first (alpha), then files (alpha by basename).
    const dirEntries = Array.from(d.dirs.values()).sort((a, b) =>
      a.label.localeCompare(b.label),
    );
    const fileEntries = [...d.files].sort((a, b) =>
      basename(a.path).localeCompare(basename(b.path)),
    );
    const out: TreeNode[] = [];
    for (const sub of dirEntries) {
      out.push(compressDir(sub));
    }
    for (const f of fileEntries) {
      out.push({ kind: "file", change: f });
    }
    return out;
  };

  const compressDir = (d: MutDir): TreeNode => {
    let label = d.label;
    let path = d.path;
    let cur = d;
    while (cur.files.length === 0 && cur.dirs.size === 1) {
      const only = cur.dirs.values().next().value!;
      label = `${label}/${only.label}`;
      path = only.path;
      cur = only;
    }
    return { kind: "dir", path, label, children: toNodes(cur) };
  };

  return toNodes(root);
}

function nodeKey(n: TreeNode): string {
  return n.kind === "dir" ? `d:${n.path}` : `f:${n.change.path}`;
}

/// ---- Renderers ----

function TreeRow({
  node,
  depth,
  selected,
  collapsed,
  onToggleDir,
  onSelectFile,
  onToggleStage,
  onDiscard,
}: {
  node: TreeNode;
  depth: number;
  selected: string | null;
  collapsed: Set<string>;
  onToggleDir: (path: string) => void;
  onSelectFile: (path: string) => void;
  onToggleStage: (change: GitFileChange) => void;
  onDiscard: (change: GitFileChange) => void;
}) {
  if (node.kind === "file") {
    return (
      <li>
        <FileRow
          change={node.change}
          active={node.change.path === selected}
          onClick={() => onSelectFile(node.change.path)}
          onToggleStage={() => onToggleStage(node.change)}
          onDiscard={() => onDiscard(node.change)}
          showDir={false}
          indent={depth}
        />
      </li>
    );
  }
  const isCollapsed = collapsed.has(node.path);
  return (
    <li>
      <button
        type="button"
        className="changes-dir-row"
        onClick={() => onToggleDir(node.path)}
        aria-expanded={!isCollapsed}
        style={{ paddingLeft: 10 + depth * 12 }}
        title={node.path}
      >
        <span
          className={"changes-dir-chevron" + (isCollapsed ? "" : " open")}
          aria-hidden
        >
          <ChevronIcon />
        </span>
        <span className="changes-dir-label">{node.label}</span>
      </button>
      {!isCollapsed && (
        <ul role="group">
          {node.children.map((child) => (
            <TreeRow
              key={nodeKey(child)}
              node={child}
              depth={depth + 1}
              selected={selected}
              collapsed={collapsed}
              onToggleDir={onToggleDir}
              onSelectFile={onSelectFile}
              onToggleStage={onToggleStage}
              onDiscard={onDiscard}
            />
          ))}
        </ul>
      )}
    </li>
  );
}

function FileRow({
  change,
  active,
  onClick,
  onToggleStage,
  onDiscard,
  showDir,
  indent,
}: {
  change: GitFileChange;
  active: boolean;
  onClick: () => void;
  onToggleStage: () => void;
  onDiscard: () => void;
  showDir: boolean;
  indent: number;
}) {
  const { t } = useTranslation();
  // The row is a container (not a <button>) so it can hold three independent
  // targets: the main body selects the file for the diff view, the ↩ discards,
  // and the checkbox stages/unstages. Nesting buttons inside a button is
  // invalid HTML, hence the div wrapper.
  return (
    <div
      className={"changes-file-row" + (active ? " active" : "")}
      role="option"
      aria-selected={active}
    >
      <button
        type="button"
        className="changes-file-main"
        onClick={onClick}
        title={change.path}
        style={indent > 0 ? { paddingLeft: 10 + indent * 12 } : undefined}
      >
        <span className={`changes-file-status status-${change.status}`}>
          {statusGlyph(change.status)}
        </span>
        <span className="changes-file-name">{basename(change.path)}</span>
        {showDir && (
          <span className="changes-file-dir">{dirname(change.path)}</span>
        )}
        <span className="changes-file-counts">
          {change.additions > 0 && (
            <span className="diff-add">+{change.additions}</span>
          )}
          {change.deletions > 0 && (
            <span className="diff-del">−{change.deletions}</span>
          )}
        </span>
      </button>
      <button
        type="button"
        className="changes-file-discard"
        onClick={onDiscard}
        aria-label={t("changes.discardFileAria", { name: basename(change.path) })}
        title={t("changes.discardFile")}
      >
        <DiscardIcon />
      </button>
      <input
        type="checkbox"
        className="changes-file-stage"
        checked={change.staged}
        onChange={onToggleStage}
        aria-label={
          change.staged
            ? t("changes.unstageFile", { name: basename(change.path) })
            : t("changes.stageFile", { name: basename(change.path) })
        }
        title={change.staged ? t("changes.unstage") : t("changes.stage")}
      />
    </div>
  );
}

function statusGlyph(s: GitFileStatus): string {
  switch (s) {
    case "modified":
      return "M";
    case "deleted":
      return "D";
    case "untracked":
      return "U";
    case "added":
      return "A";
    default:
      return "?";
  }
}

function basename(path: string): string {
  const i = path.lastIndexOf("/");
  return i >= 0 ? path.slice(i + 1) : path;
}

function dirname(path: string): string {
  const i = path.lastIndexOf("/");
  return i >= 0 ? path.slice(0, i) : "";
}

// Git branch glyph: two commit dots on a line with a fork — mirrors the
// Changes tab icon in the right-pane strip.

// Commit glyph: a commit dot on a line — the classic git-commit mark.
function CommitIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="15"
      height="15"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <circle cx="12" cy="12" r="3.2" />
      <path d="M3 12h5.8" />
      <path d="M15.2 12H21" />
    </svg>
  );
}

// Discard glyph: a curved undo arrow — reverts a file to its committed state.
function DiscardIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="14"
      height="14"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <path d="M9 14L4 9l5-5" />
      <path d="M4 9h11a5 5 0 0 1 0 10h-1" />
    </svg>
  );
}

function RefreshIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="16"
      height="16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <path d="M21 12a9 9 0 1 1-3-6.7" />
      <path d="M21 4v5h-5" />
    </svg>
  );
}

function UnifiedDiffIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="14"
      height="14"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      aria-hidden
    >
      <path d="M5 6h14M5 12h9M5 18h14" />
      <path d="M17 10v4M15 12h4" />
    </svg>
  );
}

function SplitDiffIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="14"
      height="14"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      aria-hidden
    >
      <path d="M4 6h6M4 12h6M4 18h6M14 6h6M14 12h6M14 18h6" />
      <path d="M12 4v16" />
    </svg>
  );
}

// Fetch: two arrows chasing each other (sync), distinct from the plain Refresh
// glyph so "update remote refs" reads differently from "reload the panel".
function FetchIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="15"
      height="15"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <path d="M21 12a9 9 0 0 0-15-6.7L3 8" />
      <path d="M3 4v4h4" />
      <path d="M3 12a9 9 0 0 0 15 6.7l3-2.7" />
      <path d="M21 20v-4h-4" />
    </svg>
  );
}

// Pull: an arrow coming down into a tray (incoming commits).
function PullIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="15"
      height="15"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <path d="M12 3v11" />
      <path d="M7 10l5 5 5-5" />
      <path d="M5 20h14" />
    </svg>
  );
}

// Push: an arrow going up out of a tray (outgoing commits).
function PushIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="15"
      height="15"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <path d="M12 21V10" />
      <path d="M7 14l5-5 5 5" />
      <path d="M5 4h14" />
    </svg>
  );
}

// Directory disclosure caret. Matches the file tree's chevron (an SVG that
// rotates 90° when the folder is expanded) so the Working Tree and the file
// manager read the same.
function ChevronIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="16"
      height="16"
      fill="none"
      stroke="currentColor"
      strokeWidth="2.2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <path d="M9 6l6 6-6 6" />
    </svg>
  );
}

function ListIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="14"
      height="14"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <path d="M8 6h13" />
      <path d="M8 12h13" />
      <path d="M8 18h13" />
      <circle cx="4" cy="6" r="1" />
      <circle cx="4" cy="12" r="1" />
      <circle cx="4" cy="18" r="1" />
    </svg>
  );
}

function TreeIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="14"
      height="14"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <path d="M5 5h6" />
      <path d="M9 11h8" />
      <path d="M9 17h8" />
      <path d="M7 5v12" />
      <path d="M7 11h2" />
      <path d="M7 17h2" />
    </svg>
  );
}
