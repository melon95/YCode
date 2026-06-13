// Repo file tree for the active project. Honours .gitignore on the backend
// (see ycode-ipc::Service::list_files); the frontend builds the nested view
// from the flat sorted entries, then hands it to react-arborist for
// virtualized rendering + keyboard navigation. File-type / folder-type icons
// come from `material-icon-theme` via `iconForFile` / `iconForFolder`.

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { watchImmediate } from "@tauri-apps/plugin-fs";
import { toast } from "@heroui/react";
import { Tree, type NodeRendererProps } from "react-arborist";
import {
  createPath,
  deletePath,
  listFiles,
  renamePath,
  revealInFinder,
} from "../lib/ipc";
import { useStore } from "../lib/store";
import type { FileEntry } from "../lib/types";
import { iconForFile, iconForFolder } from "../lib/fileIcons";
import { ContextMenu, type ContextMenuItem } from "./ContextMenu";
import { confirmDialog } from "../lib/confirm";

interface TreeNode {
  id: string;
  name: string;
  is_dir: boolean;
  /** Present iff `is_dir`. `react-arborist` treats undefined as "leaf". */
  children?: TreeNode[];
}

interface CreatingState {
  /** Repo-relative parent dir. Empty string = repo root. */
  parentDir: string;
  isDir: boolean;
}

interface MenuState {
  x: number;
  y: number;
  items: ContextMenuItem[];
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
  const closeFile = useStore((s) => s.closeFile);
  const openFiles = useStore((s) => s.openFiles);
  const setRightTab = useStore((s) => s.setRightTab);
  const repoPath = useStore((s) => s.projects[projectId]?.repo_path);
  const reloadKeyRef = useRef(reloadKey);
  reloadKeyRef.current = reloadKey;

  // Editing state for inline rename / create. `editingPath` swaps the row's
  // label for an input; `creating` shows a one-shot input at the top of the
  // panel scoped to a parent directory.
  const [editingPath, setEditingPath] = useState<string | null>(null);
  const [creating, setCreating] = useState<CreatingState | null>(null);
  const [menu, setMenu] = useState<MenuState | null>(null);

  // `openFiles` is read inside event handlers fired well after the closure
  // was captured; mirror through a ref so we always see the current set.
  const openFilesRef = useRef(openFiles);
  openFilesRef.current = openFiles;

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

  // Close any tabs whose path was just deleted/renamed. Directory ops cascade
  // to descendants via the `path/` prefix check.
  const closeAffectedTabs = useCallback(
    (gonePath: string) => {
      const prefix = gonePath + "/";
      for (const p of openFilesRef.current) {
        if (p === gonePath || p.startsWith(prefix)) closeFile(p);
      }
    },
    [closeFile],
  );

  const doDelete = useCallback(
    async (node: TreeNode) => {
      const ok = await confirmDialog({
        title: `Delete ${node.name}?`,
        message: node.is_dir
          ? "This will permanently remove the directory and all of its contents."
          : "This will permanently remove the file from disk.",
        confirmLabel: "Delete",
        destructive: true,
      });
      if (!ok) return;
      try {
        await deletePath(projectId, node.id);
        closeAffectedTabs(node.id);
      } catch (err) {
        toast.danger(`Delete ${node.name}: ${err}`);
      }
    },
    [projectId, closeAffectedTabs],
  );

  const doRevealInFinder = useCallback(
    async (relPath: string) => {
      if (!repoPath) return;
      try {
        await revealInFinder(`${repoPath}/${relPath}`);
      } catch (err) {
        toast.danger(`Reveal in Finder failed: ${err}`);
      }
    },
    [repoPath],
  );

  function startCreate(parentDir: string, isDir: boolean) {
    setEditingPath(null);
    setCreating({ parentDir, isDir });
  }

  function startRename(path: string) {
    setCreating(null);
    setEditingPath(path);
  }

  async function commitCreate(rawName: string) {
    if (!creating) return;
    const name = rawName.trim();
    if (!name) {
      setCreating(null);
      return;
    }
    if (name.includes("/")) {
      toast.danger("Name cannot contain '/'");
      return;
    }
    const targetPath = creating.parentDir ? `${creating.parentDir}/${name}` : name;
    const isDir = creating.isDir;
    setCreating(null);
    try {
      await createPath(projectId, targetPath, isDir);
      if (!isDir) {
        // Auto-open new files so the user can start typing immediately. Skip
        // for directories — there's nothing to display.
        openFile(targetPath, { preview: false });
        setRightTab("editor");
      }
    } catch (err) {
      toast.danger(`Create ${targetPath}: ${err}`);
    }
  }

  async function commitRename(oldPath: string, rawName: string) {
    const name = rawName.trim();
    const oldName = basename(oldPath);
    if (!name || name === oldName) {
      setEditingPath(null);
      return;
    }
    if (name.includes("/")) {
      toast.danger("Name cannot contain '/'");
      return;
    }
    const dir = dirname(oldPath);
    const newPath = dir ? `${dir}/${name}` : name;
    setEditingPath(null);
    try {
      await renamePath(projectId, oldPath, newPath);
      // Reopen affected tabs at their new paths so the user keeps the file
      // they were just looking at. Done before closing the old paths to
      // preserve tab focus order.
      const oldPrefix = oldPath + "/";
      const reopens: string[] = [];
      for (const p of openFilesRef.current) {
        if (p === oldPath) reopens.push(newPath);
        else if (p.startsWith(oldPrefix)) {
          reopens.push(newPath + p.slice(oldPath.length));
        }
      }
      closeAffectedTabs(oldPath);
      for (const p of reopens) openFile(p, { preview: false });
    } catch (err) {
      toast.danger(`Rename ${oldPath}: ${err}`);
    }
  }

  function openNodeContextMenu(e: React.MouseEvent, node: TreeNode) {
    e.preventDefault();
    e.stopPropagation();
    // VS Code convention: right-click a file → new sibling; right-click a
    // folder → new child.
    const parentDir = node.is_dir ? node.id : dirname(node.id);
    const items: ContextMenuItem[] = [
      { label: "New File", onSelect: () => startCreate(parentDir, false) },
      { label: "New Folder", onSelect: () => startCreate(parentDir, true) },
      { label: "Rename", onSelect: () => startRename(node.id) },
      { label: "Delete", onSelect: () => void doDelete(node) },
      { label: "Reveal in Finder", onSelect: () => void doRevealInFinder(node.id) },
    ];
    setMenu({ x: e.clientX, y: e.clientY, items });
  }

  function openBackgroundContextMenu(e: React.MouseEvent) {
    // Don't fight a node-targeted menu — its handler stops propagation.
    e.preventDefault();
    const items: ContextMenuItem[] = [
      { label: "New File", onSelect: () => startCreate("", false) },
      { label: "New Folder", onSelect: () => startCreate("", true) },
    ];
    setMenu({ x: e.clientX, y: e.clientY, items });
  }

  // Row is defined inside the component so it captures the open handlers via
  // closure. react-arborist v3 doesn't pass arbitrary props to the renderer,
  // so this is the cleanest way to thread project-scoped callbacks down.
  const Row = useCallback(
    ({ node, style, dragHandle }: NodeRendererProps<TreeNode>) => {
      const isDir = node.data.is_dir;
      const iconUrl = isDir
        ? iconForFolder(node.data.name, node.isOpen)
        : iconForFile(node.data.name);
      const isEditing = editingPath === node.data.id;
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
            if (isEditing) return;
            e.stopPropagation();
            if (isDir) {
              node.toggle();
              return;
            }
            node.select();
            openPreview(node.data.id);
          }}
          onDoubleClick={(e) => {
            if (isEditing) return;
            e.stopPropagation();
            if (isDir) return;
            openPinned(node.data.id);
          }}
          onContextMenu={(e) => openNodeContextMenu(e, node.data)}
          title={node.data.id}
        >
          {/* VS Code / Cursor convention: only directories show a chevron;
              files render `[icon][name]` flush-left so a depth's icons /
              names line up at the leftmost visible glyph. The chevron is an
              SVG that rotates 90° when the folder is open. */}
          {isDir && (
            <span
              className={"file-row-chevron" + (node.isOpen ? " open" : "")}
              aria-hidden
            >
              <ChevronIcon />
            </span>
          )}
          {iconUrl ? (
            <img src={iconUrl} alt="" className="file-row-icon" />
          ) : (
            <span className="file-row-icon placeholder" aria-hidden />
          )}
          {isEditing ? (
            <InlineNameInput
              initial={node.data.name}
              onCommit={(name) => void commitRename(node.data.id, name)}
              onCancel={() => setEditingPath(null)}
            />
          ) : (
            <span className="file-row-name">{node.data.name}</span>
          )}
        </div>
      );
    },
    // commitRename is recreated each render but the closures it captures
    // (projectId, openFile) are stable; rebuilding Row on every keystroke
    // would discard react-arborist's internal selection. We intentionally
    // exclude it.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [openPreview, openPinned, editingPath],
  );

  return (
    <div
      className="file-tree"
      ref={containerRef}
      onContextMenu={openBackgroundContextMenu}
    >
      {creating && (
        <CreateRow
          state={creating}
          onCommit={commitCreate}
          onCancel={() => setCreating(null)}
        />
      )}
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
      {menu && (
        <ContextMenu
          x={menu.x}
          y={menu.y}
          items={menu.items}
          onClose={() => setMenu(null)}
        />
      )}
    </div>
  );
}

function CreateRow({
  state,
  onCommit,
  onCancel,
}: {
  state: CreatingState;
  onCommit: (name: string) => void;
  onCancel: () => void;
}) {
  const inputRef = useRef<HTMLInputElement>(null);
  // Unmount-on-success would otherwise refire onBlur and try to create twice.
  const settledRef = useRef(false);
  useEffect(() => {
    inputRef.current?.focus();
  }, []);
  const commit = (value: string) => {
    if (settledRef.current) return;
    settledRef.current = true;
    onCommit(value);
  };
  const cancel = () => {
    if (settledRef.current) return;
    settledRef.current = true;
    onCancel();
  };
  const where = state.parentDir ? `/${state.parentDir}/` : "/";
  return (
    <div className="file-tree-create-row">
      <span className="file-tree-create-icon">{state.isDir ? "▸" : "·"}</span>
      <input
        ref={inputRef}
        className="file-tree-create-input"
        placeholder={state.isDir ? "folder name" : "file name"}
        onKeyDown={(e) => {
          e.stopPropagation();
          if (e.key === "Enter") {
            e.preventDefault();
            commit(e.currentTarget.value);
          } else if (e.key === "Escape") {
            e.preventDefault();
            cancel();
          }
        }}
        onKeyUp={(e) => e.stopPropagation()}
        onBlur={(e) => {
          const v = e.target.value.trim();
          if (v) commit(v);
          else cancel();
        }}
      />
      <span className="file-tree-create-where" title={where}>{where}</span>
    </div>
  );
}

function InlineNameInput({
  initial,
  onCommit,
  onCancel,
}: {
  initial: string;
  onCommit: (name: string) => void;
  onCancel: () => void;
}) {
  const ref = useRef<HTMLInputElement>(null);
  // The input unmounts both on Enter (commit succeeded; the watcher refresh
  // remounts a fresh row) and on blur. Without this guard, the unmount-driven
  // blur would fire a second commit against the now-stale path.
  const settledRef = useRef(false);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    el.focus();
    // Select the basename without its extension so the typical rename
    // (changing the stem) doesn't require an extra ⌘-A. Falls back to a
    // whole-string selection for dotfiles / extension-less names.
    const dot = initial.lastIndexOf(".");
    if (dot > 0) el.setSelectionRange(0, dot);
    else el.select();
  }, [initial]);
  const commit = (value: string) => {
    if (settledRef.current) return;
    settledRef.current = true;
    onCommit(value);
  };
  const cancel = () => {
    if (settledRef.current) return;
    settledRef.current = true;
    onCancel();
  };
  return (
    <input
      ref={ref}
      className="file-row-input"
      defaultValue={initial}
      onClick={(e) => e.stopPropagation()}
      onDoubleClick={(e) => e.stopPropagation()}
      onKeyDown={(e) => {
        // react-arborist binds its own type-to-jump / shortcut handlers
        // (notably ".", arrows, backspace) on the tree container. Stop the
        // bubble so typing inside the rename input doesn't trigger them.
        e.stopPropagation();
        if (e.key === "Enter") {
          e.preventDefault();
          commit(e.currentTarget.value);
        } else if (e.key === "Escape") {
          e.preventDefault();
          cancel();
        }
      }}
      onKeyUp={(e) => e.stopPropagation()}
      onBlur={(e) => commit(e.target.value)}
    />
  );
}

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

function basename(path: string): string {
  const idx = path.lastIndexOf("/");
  return idx >= 0 ? path.slice(idx + 1) : path;
}

function dirname(path: string): string {
  const idx = path.lastIndexOf("/");
  return idx >= 0 ? path.slice(0, idx) : "";
}
