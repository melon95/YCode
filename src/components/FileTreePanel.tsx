// Repo file tree for the active project. Honours .gitignore on the backend
// (see ycode-ipc::Service::list_files); the frontend just builds the nested
// view from the flat sorted entries and tracks per-dir expand state.

import { useEffect, useMemo, useState } from "react";
import { listFiles } from "../lib/ipc";
import { useStore } from "../lib/store";
import type { FileEntry } from "../lib/types";

type TreeNode = {
  name: string;
  path: string;
  is_dir: boolean;
  children: TreeNode[];
};

const ROOT_NODE: TreeNode = {
  name: "",
  path: "",
  is_dir: true,
  children: [],
};

export function FileTreePanel({ projectId }: { projectId: string }) {
  const [entries, setEntries] = useState<FileEntry[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Re-mount key forces a fresh load when the user clicks Refresh.
  const [reloadKey, setReloadKey] = useState(0);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const selectedFilePath = useStore((s) => s.selectedFilePath);
  const setSelectedFilePath = useStore((s) => s.setSelectedFilePath);
  const setSidebarTab = useStore((s) => s.setSidebarTab);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    listFiles(projectId)
      .then((es) => {
        if (cancelled) return;
        setEntries(es);
        setLoading(false);
      })
      .catch((err) => {
        if (cancelled) return;
        setError(String(err));
        setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [projectId, reloadKey]);

  // Reset expand state when switching projects so we don't show stale dirs.
  useEffect(() => {
    setExpanded(new Set());
  }, [projectId]);

  const tree = useMemo(() => buildTree(entries), [entries]);

  function toggle(path: string) {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(path)) next.delete(path);
      else next.add(path);
      return next;
    });
  }

  function selectFile(path: string) {
    setSelectedFilePath(path);
    setSidebarTab("diff");
  }

  return (
    <div className="file-tree">
      <div className="file-tree-toolbar">
        <button
          className="file-tree-refresh"
          onClick={() => setReloadKey((k) => k + 1)}
          disabled={loading}
          title="Re-scan the project directory"
        >
          {loading ? "Refreshing…" : "Refresh"}
        </button>
      </div>
      {error ? (
        <div className="form-error">{error}</div>
      ) : entries.length === 0 && !loading ? (
        <div className="project-empty">No files.</div>
      ) : (
        <div className="file-tree-rows">
          {tree.children.map((node) => (
            <TreeRow
              key={node.path}
              node={node}
              depth={0}
              expanded={expanded}
              selectedPath={selectedFilePath}
              onToggle={toggle}
              onSelect={selectFile}
            />
          ))}
        </div>
      )}
    </div>
  );
}

function TreeRow({
  node,
  depth,
  expanded,
  selectedPath,
  onToggle,
  onSelect,
}: {
  node: TreeNode;
  depth: number;
  expanded: Set<string>;
  selectedPath: string | null;
  onToggle: (path: string) => void;
  onSelect: (path: string) => void;
}) {
  const indent = depth * 12;

  if (node.is_dir) {
    const open = expanded.has(node.path);
    return (
      <>
        <div
          className="file-row dir"
          style={{ paddingLeft: indent + 6 }}
          onClick={() => onToggle(node.path)}
        >
          <span className="file-row-chevron">{open ? "▾" : "▸"}</span>
          <span className="file-row-name">{node.name}</span>
        </div>
        {open &&
          node.children.map((c) => (
            <TreeRow
              key={c.path}
              node={c}
              depth={depth + 1}
              expanded={expanded}
              selectedPath={selectedPath}
              onToggle={onToggle}
              onSelect={onSelect}
            />
          ))}
      </>
    );
  }

  const selected = node.path === selectedPath;
  return (
    <div
      className={"file-row file" + (selected ? " selected" : "")}
      style={{ paddingLeft: indent + 22 }}
      onClick={() => onSelect(node.path)}
      title={node.path}
    >
      <span className="file-row-name">{node.name}</span>
    </div>
  );
}

function buildTree(entries: FileEntry[]): TreeNode {
  const root: TreeNode = { ...ROOT_NODE, children: [] };
  const byPath = new Map<string, TreeNode>();
  byPath.set("", root);

  for (const e of entries) {
    const parts = e.path.split("/");
    const name = parts[parts.length - 1];
    const parentPath = parts.slice(0, -1).join("/");
    const parent = byPath.get(parentPath) ?? root;
    const node: TreeNode = {
      name,
      path: e.path,
      is_dir: e.is_dir,
      children: [],
    };
    parent.children.push(node);
    if (e.is_dir) byPath.set(e.path, node);
  }

  // Per-directory: dirs first, then files; alphabetical within each group.
  // The backend sort gave us global path order; this re-sort restores the
  // conventional file-tree presentation.
  const sortNode = (n: TreeNode) => {
    n.children.sort((a, b) => {
      if (a.is_dir !== b.is_dir) return a.is_dir ? -1 : 1;
      return a.name.localeCompare(b.name);
    });
    for (const c of n.children) if (c.is_dir) sortNode(c);
  };
  sortNode(root);

  return root;
}
