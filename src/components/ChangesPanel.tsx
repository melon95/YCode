// Unstaged working-tree changes for the active project. Two-column layout:
// left lists files (flat list OR collapsible tree, user-toggled), right
// renders the selected file's unified diff via react-diff-view. Refreshes on
// tab open + manual refresh button. We deliberately don't auto-refresh on fs
// change yet — git index churn during a `npm install` could re-render dozens
// of times a second.

import { useEffect, useMemo, useRef, useState } from "react";
import { Diff, Hunk, parseDiff, type FileData } from "react-diff-view";
import "react-diff-view/style/index.css";
import {
  gitBranch,
  gitCheckoutBranch,
  gitCommit,
  gitDiffFile,
  gitDiscardFile,
  gitFetch,
  gitListBranches,
  gitPull,
  gitPush,
  gitStageFile,
  gitStatus,
  gitUnstageFile,
} from "../lib/ipc";
import { confirmDialog } from "../lib/confirm";
import { useStore } from "../lib/store";
import { useEscapeGuard } from "../lib/useEscapeGuard";
import type {
  GitBranchInfo,
  GitBranchListView,
  GitFileChange,
  GitFileStatus,
  SessionView,
} from "../lib/types";

type ViewMode = "list" | "tree";

// Strip the internal "bad input:" prefix that IpcError::BadInput serializes
// with, so the panel surfaces only the actionable git message.
function cleanError(e: unknown): string {
  return String(e).replace(/^bad input:\s*/i, "");
}

// Label for a worktree in the tree picker: its branch name (`ycode/<short-id>`).
// We deliberately do NOT use the session's display title here — that comes from
// the CLI's terminal title, which varies per agent (Claude Code sets a friendly
// name, Codex sets its working dir = the session id), so it's neither stable nor
// reliably unique. The branch is always unique per worktree and stable. Falls
// back to reconstructing it from the id for rows created before `branch` was
// persisted on the view.
function treeBranch(s: SessionView): string {
  return s.branch ?? `ycode/${s.id.slice(0, 8)}`;
}

export function ChangesPanel({ projectId }: { projectId: string }) {
  const [changes, setChanges] = useState<GitFileChange[]>([]);
  const [branch, setBranch] = useState<GitBranchInfo | null>(null);
  const [selected, setSelected] = useState<string | null>(null);
  const [diffText, setDiffText] = useState<string>("");
  const [loadingList, setLoadingList] = useState(false);
  const [loadingDiff, setLoadingDiff] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [viewMode, setViewMode] = useState<ViewMode>("tree");
  // Set of directory paths that are *collapsed*. Default empty = all expanded.
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());
  const [commitMsg, setCommitMsg] = useState("");
  const [committing, setCommitting] = useState(false);
  // Remote/branch state. `remoteOp` gates the Fetch/Pull/Push cluster so only
  // one network op runs at a time; the branch menu lazy-loads its list on open.
  const [remoteOp, setRemoteOp] = useState<null | "fetch" | "pull" | "push">(
    null,
  );
  const [branchList, setBranchList] = useState<GitBranchListView | null>(null);
  const [branchMenuOpen, setBranchMenuOpen] = useState(false);
  const [checkingOut, setCheckingOut] = useState<string | null>(null);
  // Which tree the panel targets: null = the project's main working tree, or a
  // session id to target that agent's isolated worktree.
  const [selectedSessionId, setSelectedSessionId] = useState<string | null>(
    null,
  );
  const sessions = useStore((s) => s.sessions);
  // Sessions in THIS project running in their own worktree — the extra trees
  // the user can point the panel at besides the main one.
  const isolatedSessions = useMemo(
    () =>
      Object.values(sessions).filter(
        (s): s is SessionView =>
          s.project_id === projectId && !!s.worktree_path,
      ),
    [sessions, projectId],
  );
  // Resolved target passed to every git call: the selected session id, or
  // `undefined` (main tree) — including when the selected session has gone away.
  const treeSid =
    selectedSessionId &&
    isolatedSessions.some((s) => s.id === selectedSessionId)
      ? selectedSessionId
      : undefined;
  // True when the panel targets an agent's isolated worktree (not the main
  // tree). Such a worktree is pinned to its own `ycode/*` branch, so the branch
  // switcher is meaningless — worse, since worktrees share one ref DB it would
  // list the *main tree's* branches. We render the branch read-only instead.
  const onWorktree = treeSid !== undefined;
  // Escape closes the branch switcher (only while it's open).
  useEscapeGuard(() => setBranchMenuOpen(false), branchMenuOpen);

  // Monotonic id for the in-flight refresh. Switching trees fires a new refresh
  // before the previous one's async git calls resolve; without this guard a
  // slower earlier response (e.g. a worktree under Application Support, which is
  // slower than the main repo) can land *after* the newer one and clobber it —
  // showing the old tree's branch/files. Each result checks it's still current.
  const reqSeq = useRef(0);

  const refresh = useMemo(() => {
    return () => {
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
    };
  }, [projectId, treeSid]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  useEffect(() => {
    if (!selected) {
      setDiffText("");
      return;
    }
    let cancelled = false;
    setLoadingDiff(true);
    gitDiffFile(projectId, selected, treeSid)
      .then((text) => {
        if (!cancelled) setDiffText(text);
      })
      .catch((e) => {
        if (!cancelled) {
          setDiffText("");
          setError(cleanError(e));
        }
      })
      .finally(() => {
        if (!cancelled) setLoadingDiff(false);
      });
    return () => {
      cancelled = true;
    };
  }, [projectId, selected, treeSid]);

  const files: FileData[] = useMemo(() => {
    if (!diffText) return [];
    try {
      return parseDiff(diffText);
    } catch {
      return [];
    }
  }, [diffText]);

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

  const trimmedMsg = commitMsg.trim();
  // Disabled unless there's something staged-able AND a non-empty message,
  // and we're not mid-commit.
  const canCommit = changes.length > 0 && trimmedMsg.length > 0 && !committing;

  const doCommit = () => {
    if (!canCommit) return;
    setCommitting(true);
    setError(null);
    gitCommit(projectId, trimmedMsg, treeSid)
      .then(() => {
        setCommitMsg("");
        refresh();
      })
      .catch((e) => setError(cleanError(e)))
      .finally(() => setCommitting(false));
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

  const openBranchMenu = () => {
    // Lazy-load the branch list each time the menu opens so it stays fresh
    // after a fetch/checkout, without polling on every refresh.
    setBranchList(null);
    gitListBranches(projectId, treeSid)
      .then(setBranchList)
      .catch(() => setBranchList({ current: null, branches: [] }));
    setBranchMenuOpen(true);
  };

  const doCheckout = (name: string) => {
    if (branchList?.current === name) {
      setBranchMenuOpen(false);
      return;
    }
    setCheckingOut(name);
    setError(null);
    gitCheckoutBranch(projectId, name, treeSid)
      .then(() => {
        setBranchMenuOpen(false);
        refresh();
      })
      .catch((e) => {
        const msg = cleanError(e);
        // git refuses to switch when uncommitted changes would be clobbered.
        // Swap its multi-line stderr for a one-line, actionable hint; keep the
        // raw message for other failures (unknown branch, etc.).
        const dirtyTree =
          /would be overwritten|commit your changes or stash/i.test(msg);
        setError(
          dirtyTree
            ? `Commit or stash your changes before switching to “${name}”.`
            : msg,
        );
      })
      .finally(() => setCheckingOut(null));
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
      title: `Discard changes to ${basename(change.path)}?`,
      message:
        change.status === "untracked" || change.status === "added"
          ? "This deletes the file. This cannot be undone."
          : "This reverts the file to its last committed state. This cannot be undone.",
      confirmLabel: "Discard",
      destructive: true,
    });
    if (!ok) return;
    gitDiscardFile(projectId, change.path, treeSid)
      .then(refresh)
      .catch((e) => setError(cleanError(e)));
  };

  return (
    <div className="changes-panel">
      <div className="changes-panel-header">
        {isolatedSessions.length > 0 && (
          <select
            className="changes-panel-tree"
            value={selectedSessionId ?? ""}
            onChange={(e) => {
              setBranchMenuOpen(false);
              setSelectedSessionId(e.target.value || null);
            }}
            title="Which working tree to show — the project's main tree or an agent's isolated worktree"
          >
            <option value="">Main tree</option>
            {isolatedSessions.map((s) => (
              <option key={s.id} value={s.id}>
                {treeBranch(s)}
              </option>
            ))}
          </select>
        )}
        {/* The branch switcher belongs to the main tree only. An isolated
            worktree is pinned to its own `ycode/*` branch (already shown as the
            tree-picker label), so we hide this entirely when one is selected —
            no redundant branch, no meaningless switch to the main tree's
            branches. */}
        {!onWorktree && (
          <div className="changes-panel-branch-wrap">
            <button
              type="button"
              className="changes-panel-branch"
              disabled={!branch}
              onClick={() =>
                branchMenuOpen ? setBranchMenuOpen(false) : openBranchMenu()
              }
              aria-haspopup="menu"
              aria-expanded={branchMenuOpen}
              title={
                branch
                  ? branch.detached
                    ? `Detached HEAD at ${branch.head}`
                    : branch.upstream
                      ? `${branch.head} → ${branch.upstream}`
                      : `${branch.head} (no upstream)`
                  : undefined
              }
            >
              <BranchIcon />
              <span className="changes-panel-branch-name">
                {branch ? branch.head : "—"}
              </span>
              {branch && (branch.ahead > 0 || branch.behind > 0) && (
                <span className="changes-panel-branch-track">
                  {branch.ahead > 0 && <span title="commits ahead of upstream">↑{branch.ahead}</span>}
                  {branch.behind > 0 && <span title="commits behind upstream">↓{branch.behind}</span>}
                </span>
              )}
              <span className="changes-panel-branch-caret">
                <ChevronIcon />
              </span>
            </button>
            {branchMenuOpen && (
              <>
                <div
                  className="changes-panel-branch-backdrop"
                  onClick={() => setBranchMenuOpen(false)}
                />
                <div className="changes-panel-branch-menu" role="menu">
                  {branchList === null ? (
                    <div className="changes-panel-branch-empty">Loading…</div>
                  ) : branchList.branches.length === 0 ? (
                    <div className="changes-panel-branch-empty">No local branches</div>
                  ) : (
                    branchList.branches.map((name) => (
                      <button
                        key={name}
                        type="button"
                        role="menuitem"
                        className={
                          "changes-panel-branch-item" +
                          (name === branchList.current ? " current" : "")
                        }
                        disabled={checkingOut !== null}
                        onClick={() => doCheckout(name)}
                      >
                        <span className="changes-panel-branch-check">
                          {name === branchList.current ? "✓" : ""}
                        </span>
                        <span className="changes-panel-branch-item-name">{name}</span>
                        {checkingOut === name && (
                          <span className="changes-panel-branch-item-spin">…</span>
                        )}
                      </button>
                    ))
                  )}
                </div>
              </>
            )}
          </div>
        )}
        <span className="changes-panel-count">
          {changes.length === 0
            ? "No changes"
            : `${changes.length} file${changes.length === 1 ? "" : "s"}`}
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
        <div className="changes-panel-remote" role="group" aria-label="Remote">
          <button
            type="button"
            className="changes-panel-remote-btn"
            onClick={() => runRemote("fetch", () => gitFetch(projectId, treeSid))}
            disabled={!branch || remoteOp !== null}
            aria-label="Fetch"
            title="Fetch from remote"
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
            aria-label="Pull"
            title={
              branch && !branch.detached && !branch.upstream
                ? "No upstream to pull from"
                : "Pull (fast-forward only)"
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
            aria-label="Push"
            title={
              branch && !branch.detached && !branch.upstream
                ? "Publish branch to origin"
                : "Push to remote"
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
        <div className="changes-panel-mode" role="tablist" aria-label="View mode">
          <button
            type="button"
            className={
              "changes-panel-mode-btn" + (viewMode === "list" ? " active" : "")
            }
            onClick={() => setViewMode("list")}
            aria-label="List view"
            aria-selected={viewMode === "list"}
            role="tab"
            title="List view"
          >
            <ListIcon />
          </button>
          <button
            type="button"
            className={
              "changes-panel-mode-btn" + (viewMode === "tree" ? " active" : "")
            }
            onClick={() => setViewMode("tree")}
            aria-label="Tree view"
            aria-selected={viewMode === "tree"}
            role="tab"
            title="Tree view"
          >
            <TreeIcon />
          </button>
        </div>
        <button
          type="button"
          className="changes-panel-refresh"
          onClick={refresh}
          aria-label="Refresh"
          title="Refresh"
        >
          <RefreshIcon />
        </button>
      </div>
      <div className="changes-commit-box">
        <textarea
          className="changes-commit-input"
          value={commitMsg}
          onChange={(e) => setCommitMsg(e.target.value)}
          onKeyDown={(e) => {
            // ⌘/Ctrl+Enter commits, matching the VS Code affordance.
            if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
              e.preventDefault();
              doCommit();
            }
          }}
          placeholder={
            branch && !branch.detached
              ? `Message (⌘⏎ to commit on "${branch.head}")`
              : "Message (⌘⏎ to commit)"
          }
          rows={1}
          aria-label="Commit message"
        />
        <button
          type="button"
          className="changes-commit-btn"
          onClick={doCommit}
          disabled={!canCommit}
          title={
            changes.length === 0
              ? "Nothing to commit"
              : trimmedMsg.length === 0
                ? "Enter a commit message"
                : "Commit all changes"
          }
        >
          <CommitIcon />
          <span>{committing ? "Committing…" : "Commit"}</span>
        </button>
      </div>
      <div className="changes-panel-body">
        <div className="changes-file-pane">
          {loadingList && changes.length === 0 && (
            <div className="changes-empty">Loading…</div>
          )}
          {!loadingList && changes.length === 0 && !error && (
            <div className="changes-empty">Working tree clean.</div>
          )}
          {error && <div className="changes-empty error">{error}</div>}
          {changes.length > 0 && viewMode === "list" && (
            <ul className="changes-file-list" role="listbox" aria-label="Changed files">
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
            <ul className="changes-file-tree" role="tree" aria-label="Changed files">
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
        <div className="changes-diff-view">
          {loadingDiff && <div className="changes-empty">Loading diff…</div>}
          {!loadingDiff && !selected && (
            <div className="changes-empty">Select a file to view its diff.</div>
          )}
          {!loadingDiff && selected && !hasRenderableDiff && (
            <div className="changes-empty">
              {diffText
                ? "Preview not supported for this file type."
                : "No diff to display."}
            </div>
          )}
          {!loadingDiff &&
            hasRenderableDiff &&
            files.map((file, i) => (
              <Diff
                key={i}
                viewType="unified"
                diffType={file.type}
                hunks={file.hunks}
              >
                {(hunks) =>
                  hunks.map((h) => <Hunk key={h.content} hunk={h} />)
                }
              </Diff>
            ))}
        </div>
      </div>
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
        aria-label={`Discard changes to ${basename(change.path)}`}
        title="Discard changes"
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
            ? `Unstage ${basename(change.path)}`
            : `Stage ${basename(change.path)}`
        }
        title={change.staged ? "Unstage" : "Stage"}
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
function BranchIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="13"
      height="13"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <circle cx="6" cy="6" r="2.4" />
      <circle cx="6" cy="18" r="2.4" />
      <circle cx="18" cy="7" r="2.4" />
      <path d="M6 8.4v7.2" />
      <path d="M18 9.4a6 6 0 0 1-6 6h-1.6" />
    </svg>
  );
}

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
