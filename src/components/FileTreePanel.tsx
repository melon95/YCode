// Repo file tree for the active project. Honours .gitignore on the backend
// (see ycode-ipc::Service::list_files); the frontend builds the nested view
// from the flat sorted entries, then hands it to react-arborist for
// virtualized rendering + keyboard navigation. File-type / folder-type icons
// come from `material-icon-theme` via `iconForFile` / `iconForFolder`.

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { watchImmediate } from "@tauri-apps/plugin-fs";
import { Tree, type NodeRendererProps } from "react-arborist";
import { listFiles } from "../lib/ipc";
import { useStore } from "../lib/store";
import type { FileEntry } from "../lib/types";
import { iconForFile, iconForFolder } from "../lib/fileIcons";

interface TreeNode {
  id: string;
  name: string;
  is_dir: boolean;
  /** Present iff `is_dir`. `react-arborist` treats undefined as "leaf". */
  children?: TreeNode[];
}

const ROW_HEIGHT = 24;

export function FileTreePanel({ projectId }: { projectId: string }) {
  const [entries, setEntries] = useState<FileEntry[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Re-mount key forces a fresh load when the watcher fires.
  const [reloadKey, setReloadKey] = useState(0);
  const selectedFilePath = useStore((s) => s.selectedFilePath);
  const openFile = useStore((s) => s.openFile);
  const setRightTab = useStore((s) => s.setRightTab);
  const repoPath = useStore((s) => s.projects[projectId]?.repo_path);
  const reloadKeyRef = useRef(reloadKey);
  reloadKeyRef.current = reloadKey;

  // Measure container so react-arborist knows its viewport size.
  const containerRef = useRef<HTMLDivElement | null>(null);
  const [size, setSize] = useState<{ w: number; h: number }>({ w: 240, h: 400 });
  useEffect(() => {
    if (!containerRef.current) return;
    const el = containerRef.current;
    const update = () => {
      setSize({ w: el.clientWidth, h: el.clientHeight });
    };
    update();
    const ro = new ResizeObserver(update);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

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

  // Watch the repo directory for changes. We use `watchImmediate` instead of
  // `watch` because the latter wraps notify in `notify-debouncer-full`, which
  // synchronously walkdir's the entire tree on setup (ignoring .gitignore!) to
  // populate a FileIdMap for rename-event stitching. That walk is the source
  // of the 1-8s project-switch lag we saw in the perf logs — and we don't use
  // the rename-stitching feature anyway (any event just refetches the list).
  //
  // `watchImmediate` skips the debouncer entirely, so plugin-fs constructs a
  // plain `RecommendedWatcher` and FSEvents registration is the kernel's O(1)
  // call. We replace the 400ms debounce on our side with a trailing-edge
  // setTimeout so a burst of events still only re-lists once.
  useEffect(() => {
    if (!repoPath) return;
    let cancelled = false;
    let unwatch: (() => void) | undefined;
    let timer: ReturnType<typeof setTimeout> | null = null;
    const DEBOUNCE_MS = 400;

    watchImmediate(
      repoPath,
      () => {
        if (cancelled) return;
        if (timer) clearTimeout(timer);
        timer = setTimeout(() => {
          timer = null;
          if (!cancelled) setReloadKey(reloadKeyRef.current + 1);
        }, DEBOUNCE_MS);
      },
      { recursive: true },
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
      if (timer) clearTimeout(timer);
      unwatch?.();
    };
  }, [repoPath]);

  const tree = useMemo(() => buildTree(entries), [entries]);

  // Single-click → open as a preview tab (reuses the existing preview slot
  // so casually browsing the tree doesn't pile up tabs). Double-click → pin
  // the tab so it survives the next single-click on another file.
  const openPreview = useCallback(
    (path: string) => {
      openFile(path, { preview: true });
      setRightTab("editor");
    },
    [openFile, setRightTab],
  );
  const openPinned = useCallback(
    (path: string) => {
      openFile(path, { preview: false });
      setRightTab("editor");
    },
    [openFile, setRightTab],
  );

  // Row is defined inside the component so it captures the open handlers via
  // closure. react-arborist v3 doesn't pass arbitrary props to the renderer,
  // so this is the cleanest way to thread project-scoped callbacks down.
  const Row = useCallback(
    ({ node, style, dragHandle }: NodeRendererProps<TreeNode>) => {
      const isDir = node.data.is_dir;
      const iconUrl = isDir
        ? iconForFolder(node.data.name, node.isOpen)
        : iconForFile(node.data.name);
      return (
        <div
          ref={dragHandle}
          style={style}
          className={
            "file-row" +
            (isDir ? " dir" : " file") +
            (node.isSelected ? " selected" : "")
          }
          onClick={(e) => {
            e.stopPropagation();
            if (isDir) {
              node.toggle();
              return;
            }
            node.select();
            openPreview(node.data.id);
          }}
          onDoubleClick={(e) => {
            e.stopPropagation();
            if (isDir) return;
            openPinned(node.data.id);
          }}
          title={node.data.id}
        >
          {/* VS Code / Cursor convention: only directories show a chevron,
              files render `[icon][name]` flush-left so a depth's icons /
              names line up at the leftmost visible glyph. */}
          {isDir && (
            <span className="file-row-chevron">{node.isOpen ? "▾" : "▸"}</span>
          )}
          {iconUrl ? (
            <img src={iconUrl} alt="" className="file-row-icon" />
          ) : (
            <span className="file-row-icon placeholder" aria-hidden />
          )}
          <span className="file-row-name">{node.data.name}</span>
        </div>
      );
    },
    [openPreview, openPinned],
  );

  return (
    <div className="file-tree" ref={containerRef}>
      {error ? (
        <div className="form-error">{error}</div>
      ) : entries.length === 0 && !loading ? (
        <div className="project-empty">No files.</div>
      ) : (
        <Tree<TreeNode>
          data={tree}
          openByDefault={false}
          width={size.w}
          height={size.h}
          rowHeight={ROW_HEIGHT}
          indent={14}
          padding={4}
          selection={selectedFilePath ?? undefined}
        >
          {Row}
        </Tree>
      )}
    </div>
  );
}

function buildTree(entries: FileEntry[]): TreeNode[] {
  // Map path → node so children find their parents. Top-level array is the
  // value `react-arborist` actually wants.
  const byPath = new Map<string, TreeNode>();
  const roots: TreeNode[] = [];

  for (const e of entries) {
    const parts = e.path.split("/");
    const name = parts[parts.length - 1];
    const parentPath = parts.slice(0, -1).join("/");
    const node: TreeNode = {
      id: e.path,
      name,
      is_dir: e.is_dir,
      children: e.is_dir ? [] : undefined,
    };
    byPath.set(e.path, node);

    if (parentPath === "") {
      roots.push(node);
    } else {
      const parent = byPath.get(parentPath);
      if (parent && parent.children) parent.children.push(node);
      else roots.push(node); // orphan — backend shouldn't emit these, but be defensive
    }
  }

  // Per-directory: dirs first, then files; alphabetical within each group.
  const sortNode = (children: TreeNode[]) => {
    children.sort((a, b) => {
      if (a.is_dir !== b.is_dir) return a.is_dir ? -1 : 1;
      return a.name.localeCompare(b.name);
    });
    for (const c of children) if (c.children) sortNode(c.children);
  };
  sortNode(roots);
  return roots;
}
