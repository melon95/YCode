// Repo file tree for the active project. Honours .gitignore on the backend
// (see ycode-ipc::Service::list_files); the frontend just builds the nested
// view from the flat sorted entries and tracks per-dir expand state.

import { useEffect, useMemo, useRef, useState } from "react";
import { watch } from "@tauri-apps/plugin-fs";
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
  const openFile = useStore((s) => s.openFile);
  const setRightTab = useStore((s) => s.setRightTab);
  const repoPath = useStore((s) => s.projects[projectId]?.repo_path);
  const reloadKeyRef = useRef(reloadKey);
  reloadKeyRef.current = reloadKey;

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

  // Watch the repo directory; any fs event triggers a debounced re-list.
  // The plugin already debounces (delayMs default ~2s); we just bump the
  // reloadKey to reuse the effect above.
  useEffect(() => {
    if (!repoPath) return;
    let cancelled = false;
    let unwatch: (() => void) | undefined;
    watch(
      repoPath,
      () => {
        if (cancelled) return;
        setReloadKey(reloadKeyRef.current + 1);
      },
      { recursive: true, delayMs: 400 },
    )
      .then((fn) => {
        if (cancelled) fn();
        else unwatch = fn;
      })
      .catch((err) => {
        console.warn("watch failed", err);
      });
    return () => {
      cancelled = true;
      unwatch?.();
    };
  }, [repoPath]);

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
    openFile(path);
    setRightTab("editor");
  }

  return (
    <div className="file-tree">
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
          <FolderIcon open={open} />
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
      <FileIcon name={node.name} />
      <span className="file-row-name">{node.name}</span>
    </div>
  );
}

function FolderIcon({ open }: { open: boolean }) {
  return (
    <svg
      viewBox="0 0 16 16"
      width="15"
      height="15"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.4"
      strokeLinecap="round"
      strokeLinejoin="round"
      className="file-row-icon folder"
      aria-hidden
    >
      {open ? (
        <>
          <path d="M1.5 5.5h13l-1.2 7H2.7z" />
          <path d="M2.2 3.5h4l1.1 1.4h6.5v2" />
        </>
      ) : (
        <path d="M1.8 4h4.2l1.1 1.4h7.1v7.1H1.8z" />
      )}
    </svg>
  );
}

function FileIcon({ name }: { name: string }) {
  const meta = fileIconFor(name);
  return (
    <span className={"file-row-icon file " + meta.kind} aria-hidden>
      {meta.label}
    </span>
  );
}

type FileIconMeta = {
  kind: string;
  label: string;
};

function fileIconFor(name: string): FileIconMeta {
  const lower = name.toLowerCase();
  const exact: Record<string, FileIconMeta> = {
    "package.json": { kind: "npm", label: "N" },
    "package-lock.json": { kind: "npm", label: "N" },
    "pnpm-lock.yaml": { kind: "npm", label: "N" },
    "yarn.lock": { kind: "npm", label: "N" },
    "bun.lock": { kind: "npm", label: "B" },
    "cargo.toml": { kind: "rust", label: "R" },
    "cargo.lock": { kind: "rust", label: "R" },
    "readme.md": { kind: "markdown", label: "M" },
    "license": { kind: "plain", label: "L" },
    ".gitignore": { kind: "git", label: "G" },
    ".gitattributes": { kind: "git", label: "G" },
    ".env": { kind: "env", label: "E" },
    ".env.local": { kind: "env", label: "E" },
    "dockerfile": { kind: "docker", label: "D" },
    "tsconfig.json": { kind: "typescript", label: "TS" },
    "vite.config.ts": { kind: "vite", label: "V" },
    "vite.config.js": { kind: "vite", label: "V" },
  };
  const byName = exact[lower];
  if (byName) return byName;

  const ext = lower.includes(".") ? lower.split(".").pop() ?? "" : "";
  switch (ext) {
    case "ts":
    case "tsx":
      return { kind: "typescript", label: "TS" };
    case "js":
    case "jsx":
    case "mjs":
    case "cjs":
      return { kind: "javascript", label: "JS" };
    case "json":
      return { kind: "json", label: "{}" };
    case "md":
    case "mdx":
    case "markdown":
      return { kind: "markdown", label: "M" };
    case "rs":
      return { kind: "rust", label: "R" };
    case "py":
      return { kind: "python", label: "PY" };
    case "css":
    case "scss":
    case "sass":
    case "less":
      return { kind: "css", label: "#" };
    case "html":
    case "htm":
      return { kind: "html", label: "<>" };
    case "svg":
      return { kind: "image", label: "S" };
    case "png":
    case "jpg":
    case "jpeg":
    case "gif":
    case "webp":
    case "ico":
      return { kind: "image", label: "I" };
    case "toml":
    case "yaml":
    case "yml":
      return { kind: "config", label: "Y" };
    case "sh":
    case "bash":
    case "zsh":
      return { kind: "shell", label: "$" };
    case "swift":
      return { kind: "swift", label: "S" };
    case "sql":
      return { kind: "sql", label: "Q" };
    case "lock":
      return { kind: "lock", label: "L" };
    default:
      return { kind: "plain", label: "·" };
  }
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
