// Unstaged working-tree changes for the active project. Two-column layout:
// left lists files (flat list OR collapsible tree, user-toggled), right
// renders the selected file's unified diff via react-diff-view. Refreshes on
// tab open + manual refresh button. We deliberately don't auto-refresh on fs
// change yet — git index churn during a `npm install` could re-render dozens
// of times a second.

import { useEffect, useMemo, useState } from "react";
import { Diff, Hunk, parseDiff, type FileData } from "react-diff-view";
import "react-diff-view/style/index.css";
import { gitDiffFile, gitStatus } from "../lib/ipc";
import type { GitFileChange, GitFileStatus } from "../lib/types";

type ViewMode = "list" | "tree";

export function ChangesPanel({ projectId }: { projectId: string }) {
  const [changes, setChanges] = useState<GitFileChange[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [diffText, setDiffText] = useState<string>("");
  const [loadingList, setLoadingList] = useState(false);
  const [loadingDiff, setLoadingDiff] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [viewMode, setViewMode] = useState<ViewMode>("tree");
  // Set of directory paths that are *collapsed*. Default empty = all expanded.
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());

  const refresh = useMemo(() => {
    return () => {
      setLoadingList(true);
      setError(null);
      gitStatus(projectId)
        .then((rows) => {
          setChanges(rows);
          setSelected((cur) => {
            if (cur && rows.some((r) => r.path === cur)) return cur;
            return rows[0]?.path ?? null;
          });
        })
        .catch((e) => setError(String(e)))
        .finally(() => setLoadingList(false));
    };
  }, [projectId]);

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
    gitDiffFile(projectId, selected)
      .then((text) => {
        if (!cancelled) setDiffText(text);
      })
      .catch((e) => {
        if (!cancelled) {
          setDiffText("");
          setError(String(e));
        }
      })
      .finally(() => {
        if (!cancelled) setLoadingDiff(false);
      });
    return () => {
      cancelled = true;
    };
  }, [projectId, selected]);

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

  return (
    <div className="changes-panel">
      <div className="changes-panel-header">
        <span className="changes-panel-count">
          {changes.length === 0
            ? "No changes"
            : `${changes.length} file${changes.length === 1 ? "" : "s"}`}
        </span>
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
      <div className="changes-panel-body">
        <div className="changes-file-pane">
          {loadingList && changes.length === 0 && (
            <div className="changes-empty">Loading…</div>
          )}
          {!loadingList && changes.length === 0 && !error && (
            <div className="changes-empty">Working tree clean.</div>
          )}
          {error && <div className="changes-empty error">{error}</div>}
          {!loadingList && changes.length > 0 && viewMode === "list" && (
            <ul className="changes-file-list" role="listbox" aria-label="Changed files">
              {changes.map((c) => (
                <li key={c.path}>
                  <FileRow
                    change={c}
                    active={c.path === selected}
                    onClick={() => setSelected(c.path)}
                    showDir
                    indent={0}
                  />
                </li>
              ))}
            </ul>
          )}
          {!loadingList && changes.length > 0 && viewMode === "tree" && (
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
}: {
  node: TreeNode;
  depth: number;
  selected: string | null;
  collapsed: Set<string>;
  onToggleDir: (path: string) => void;
  onSelectFile: (path: string) => void;
}) {
  if (node.kind === "file") {
    return (
      <li>
        <FileRow
          change={node.change}
          active={node.change.path === selected}
          onClick={() => onSelectFile(node.change.path)}
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
  showDir,
  indent,
}: {
  change: GitFileChange;
  active: boolean;
  onClick: () => void;
  showDir: boolean;
  indent: number;
}) {
  return (
    <button
      type="button"
      className={"changes-file-row" + (active ? " active" : "")}
      onClick={onClick}
      role="option"
      aria-selected={active}
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
