// CodeMirror 6 editor. Each open file keeps its in-memory buffer in
// `filesRef` so switching tabs preserves unsaved edits. ⌘S saves the active
// file. An fs.watch on the focused file detects external edits and shows
// either an auto-reload (clean buffer) or a conflict banner (dirty buffer).

import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from "react";
import { watch } from "@tauri-apps/plugin-fs";
import { toast } from "@heroui/react";
import CodeMirror, { type ReactCodeMirrorRef } from "@uiw/react-codemirror";
import { EditorView, keymap } from "@codemirror/view";
import type { Extension } from "@codemirror/state";
import { javascript } from "@codemirror/lang-javascript";
import { json } from "@codemirror/lang-json";
import { markdown } from "@codemirror/lang-markdown";
import { rust } from "@codemirror/lang-rust";
import { python } from "@codemirror/lang-python";
import { css } from "@codemirror/lang-css";
import { html } from "@codemirror/lang-html";
import {
  openInExternalEditor,
  readFile,
  revealInFinder,
  writeFile,
} from "../lib/ipc";
import { useStore } from "../lib/store";
import { confirmDialog } from "../lib/confirm";
import type { EditorGotoDetail } from "../lib/fileLinkProvider";

interface FileState {
  /// Last known disk contents — what a save will be compared against.
  original: string;
  /// In-memory buffer (== editor view's current value).
  value: string;
  isBinary: boolean;
  loaded: boolean;
}

export function EditorPanel({ projectId }: { projectId: string }) {
  const openFiles = useStore((s) => s.openFiles);
  const selectedFilePath = useStore((s) => s.selectedFilePath);
  const closeFile = useStore((s) => s.closeFile);
  const setFileDirty = useStore((s) => s.setFileDirty);
  const repoPath = useStore((s) => s.projects[projectId]?.repo_path);
  const editorFontSize = useStore((s) => s.fontSizes.editor);

  const filesRef = useRef<Map<string, FileState>>(new Map());
  // We mutate filesRef in place for performance (CM emits onChange every
  // keystroke). Use a tiny render-tick to surface those mutations to React.
  const [, tick] = useReducer((x: number) => x + 1, 0);
  const [externalChange, setExternalChange] = useState(false);
  const skipNextWatchRef = useRef(false);
  const cmRef = useRef<ReactCodeMirrorRef>(null);

  // Drop cache entries for closed tabs so reopens re-read from disk.
  useEffect(() => {
    const open = new Set(openFiles);
    for (const path of Array.from(filesRef.current.keys())) {
      if (!open.has(path)) filesRef.current.delete(path);
    }
  }, [openFiles]);

  // Lazy-load the focused file (no IPC if already cached).
  useEffect(() => {
    if (!selectedFilePath) return;
    setExternalChange(false);
    const cached = filesRef.current.get(selectedFilePath);
    if (cached?.loaded) return;
    // Placeholder so React knows the tab is in-flight.
    filesRef.current.set(selectedFilePath, {
      original: "",
      value: "",
      isBinary: false,
      loaded: false,
    });
    let cancelled = false;
    readFile(projectId, selectedFilePath)
      .then((file) => {
        if (cancelled) return;
        filesRef.current.set(selectedFilePath, {
          original: file.contents,
          value: file.contents,
          isBinary: file.is_binary,
          loaded: true,
        });
        setFileDirty(selectedFilePath, false);
        tick();
      })
      .catch((err) => {
        if (cancelled) return;
        toast.danger(`Open ${selectedFilePath}: ${err}`);
        filesRef.current.delete(selectedFilePath);
        setFileDirty(selectedFilePath, false);
        tick();
      });
    return () => {
      cancelled = true;
    };
  }, [projectId, selectedFilePath, setFileDirty]);

  // Watch only the focused file. Inactive tabs catch up on next focus via
  // the load effect above.
  useEffect(() => {
    if (!selectedFilePath || !repoPath) return;
    const abs = `${repoPath}/${selectedFilePath}`;
    let cancelled = false;
    let unwatch: (() => void) | undefined;
    watch(
      abs,
      () => {
        if (cancelled) return;
        if (skipNextWatchRef.current) {
          skipNextWatchRef.current = false;
          return;
        }
        readFile(projectId, selectedFilePath)
          .then((file) => {
            if (cancelled) return;
            const cur = filesRef.current.get(selectedFilePath);
            if (!cur) return;
            cur.isBinary = file.is_binary;
            if (cur.value === cur.original) {
              // Clean buffer — adopt disk version silently.
              cur.original = file.contents;
              cur.value = file.contents;
              setFileDirty(selectedFilePath, false);
              setExternalChange(false);
            } else if (cur.value !== file.contents) {
              // Local edits diverge from disk — keep the user's draft, but
              // update `original` so a save merges cleanly, and flag conflict.
              cur.original = file.contents;
              setFileDirty(selectedFilePath, true);
              setExternalChange(true);
            }
            tick();
          })
          .catch((err) => {
            if (!cancelled) console.warn("editor watch reload failed", err);
          });
      },
      { delayMs: 300 },
    )
      .then((fn) => {
        if (cancelled) fn();
        else unwatch = fn;
      })
      .catch((err) => console.warn("editor watch failed", err));
    return () => {
      cancelled = true;
      unwatch?.();
    };
  }, [projectId, repoPath, selectedFilePath, setFileDirty]);

  const save = useCallback(async () => {
    if (!selectedFilePath) return;
    const fs = filesRef.current.get(selectedFilePath);
    if (!fs || !fs.loaded || fs.isBinary) return;
    if (fs.value === fs.original) return;
    skipNextWatchRef.current = true;
    try {
      await writeFile({
        project_id: projectId,
        file_path: selectedFilePath,
        contents: fs.value,
      });
      fs.original = fs.value;
      setFileDirty(selectedFilePath, false);
      setExternalChange(false);
      tick();
    } catch (err) {
      skipNextWatchRef.current = false;
      toast.danger(`Save ${selectedFilePath}: ${err}`);
    }
  }, [projectId, selectedFilePath, setFileDirty]);

  // Stash `save` in a ref so the CM keymap extension doesn't rebuild on every
  // value/dirty change (which would discard editor history).
  const saveRef = useRef(save);
  saveRef.current = save;

  // CodeMirror 6's default theme leaves `.cm-editor` with an inherited font
  // but its `.cm-scroller` carries an explicit `font-family` + `font-size`,
  // so an inline `style={{ fontSize }}` on the wrapper has no effect. A
  // theme extension overrides the scroller rule and is the canonical fix.
  // `useMemo`-cached so identity is stable while editorFontSize is constant,
  // avoiding a reconfigure on every render.
  const fontTheme = useMemo(
    () =>
      EditorView.theme({
        "&": { fontSize: `${editorFontSize}px` },
        ".cm-scroller": { fontSize: `${editorFontSize}px` },
      }),
    [editorFontSize],
  );

  const extensions: Extension[] = useMemo(() => {
    const lang = languageFor(selectedFilePath);
    return [
      keymap.of([
        {
          key: "Mod-s",
          preventDefault: true,
          run: () => {
            void saveRef.current();
            return true;
          },
        },
      ]),
      EditorView.lineWrapping,
      fontTheme,
      ...(lang ? [lang] : []),
    ];
  }, [selectedFilePath, fontTheme]);

  async function discardAndReload() {
    if (!selectedFilePath) return;
    try {
      const file = await readFile(projectId, selectedFilePath);
      filesRef.current.set(selectedFilePath, {
        original: file.contents,
        value: file.contents,
        isBinary: file.is_binary,
        loaded: true,
      });
      setFileDirty(selectedFilePath, false);
      setExternalChange(false);
      tick();
    } catch (err) {
      toast.danger(`Reload failed: ${err}`);
    }
  }

  const handleClose = useCallback(
    async (path: string) => {
      const fs = filesRef.current.get(path);
      if (fs && fs.loaded && fs.value !== fs.original) {
        const ok = await confirmDialog({
          title: `Close ${basename(path)} with unsaved changes?`,
          message: "Your edits since the last save will be discarded.",
          confirmLabel: "Discard changes",
          destructive: true,
        });
        if (!ok) return;
      }
      closeFile(path);
    },
    [closeFile],
  );

  useEffect(() => {
    function onCloseFile(event: Event) {
      const path = (event as CustomEvent<string>).detail;
      if (typeof path === "string") void handleClose(path);
    }
    window.addEventListener("ycode:close-file", onCloseFile);
    return () => window.removeEventListener("ycode:close-file", onCloseFile);
  }, [handleClose]);

  // ── Cmd-click goto from terminal file links ─────────────────────────────
  //
  // `ycode:editor-goto` fires after `openFile` has already switched
  // `selectedFilePath`, but the file's contents and the CodeMirror view both
  // come up asynchronously. Poll with rAF (capped) until both are ready.
  // `useStore.getState()` reads the live selection so we don't rely on a
  // stale closure when the user clicks multiple paths in quick succession.
  const pendingGotoRef = useRef<EditorGotoDetail | null>(null);
  useEffect(() => {
    function tryApply(attemptsLeft: number) {
      const pending = pendingGotoRef.current;
      if (!pending) return;
      if (pending.path !== useStore.getState().selectedFilePath) {
        // Selection moved on (or not yet there). Keep the request pinned —
        // future rAF ticks or another goto will catch up.
        if (attemptsLeft <= 0) {
          pendingGotoRef.current = null;
          return;
        }
        requestAnimationFrame(() => tryApply(attemptsLeft - 1));
        return;
      }
      const fs = filesRef.current.get(pending.path);
      const view = cmRef.current?.view;
      if (!fs?.loaded || fs.isBinary || !view) {
        if (attemptsLeft <= 0) {
          pendingGotoRef.current = null;
          return;
        }
        requestAnimationFrame(() => tryApply(attemptsLeft - 1));
        return;
      }
      pendingGotoRef.current = null;
      const totalLines = view.state.doc.lines;
      const targetLine = Math.max(1, Math.min(totalLines, pending.line));
      const line = view.state.doc.line(targetLine);
      const colOffset = pending.column
        ? Math.max(0, Math.min(line.length, pending.column - 1))
        : 0;
      const pos = line.from + colOffset;
      view.dispatch({
        selection: { anchor: pos },
        effects: EditorView.scrollIntoView(pos, { y: "center" }),
      });
      view.focus();
    }
    function onGoto(event: Event) {
      const detail = (event as CustomEvent<EditorGotoDetail>).detail;
      if (!detail || typeof detail.path !== "string") return;
      pendingGotoRef.current = detail;
      // ~1s of rAF retries covers IPC read + CM mount for typical files;
      // very large files just won't auto-jump, which is preferable to
      // looping forever.
      tryApply(60);
    }
    window.addEventListener("ycode:editor-goto", onGoto);
    return () => window.removeEventListener("ycode:editor-goto", onGoto);
  }, []);

  if (openFiles.length === 0) {
    return (
      <div className="editor-panel">
        <div className="empty">
          Pick a file from the <strong>Files</strong> tab.
        </div>
      </div>
    );
  }

  const fileState = selectedFilePath
    ? filesRef.current.get(selectedFilePath)
    : null;
  const loaded = fileState?.loaded ?? false;
  const value = fileState?.value ?? "";
  const isBinary = fileState?.isBinary ?? false;
  const absPath = selectedFilePath && repoPath ? `${repoPath}/${selectedFilePath}` : null;

  async function onOpenInEditor() {
    if (!absPath) return;
    try {
      await openInExternalEditor({ path: absPath, editor: null });
    } catch (err) {
      toast.danger(`Open in editor failed: ${err}`);
    }
  }

  async function onRevealInFinder() {
    if (!absPath) return;
    try {
      await revealInFinder(absPath);
    } catch (err) {
      toast.danger(`Reveal in Finder failed: ${err}`);
    }
  }

  return (
    <div className="editor-panel">
      {selectedFilePath && (
        <div className="editor-viewer-header">
          <span className="editor-viewer-path">{selectedFilePath}</span>
          <button type="button" onClick={onOpenInEditor} className="editor-viewer-action">
            Open in editor
          </button>
          <button type="button" onClick={onRevealInFinder} className="editor-viewer-action">
            Reveal in Finder
          </button>
        </div>
      )}
      {externalChange && (
        <div className="editor-warning">
          File changed on disk while you were editing.
          <button onClick={discardAndReload}>Discard &amp; reload</button>
        </div>
      )}
      {!selectedFilePath ? null : isBinary ? (
        <div className="empty">Binary file — editor cannot display.</div>
      ) : !loaded ? (
        <div className="empty">Loading…</div>
      ) : (
        <CodeMirror
          ref={cmRef}
          value={value}
          theme="dark"
          extensions={extensions}
          onChange={(v) => {
            if (!selectedFilePath) return;
            const cur = filesRef.current.get(selectedFilePath);
            if (!cur) return;
            cur.value = v;
            setFileDirty(selectedFilePath, v !== cur.original);
            tick();
          }}
          basicSetup={{
            highlightActiveLine: true,
            highlightActiveLineGutter: true,
            foldGutter: true,
            lineNumbers: true,
            indentOnInput: true,
          }}
          height="100%"
          style={{ flex: 1, minHeight: 0 }}
        />
      )}
    </div>
  );
}

function basename(path: string): string {
  const idx = path.lastIndexOf("/");
  return idx >= 0 ? path.slice(idx + 1) : path;
}

function languageFor(path: string | null): Extension | null {
  if (!path) return null;
  const ext = path.split(".").pop()?.toLowerCase() ?? "";
  switch (ext) {
    case "js":
    case "jsx":
    case "mjs":
    case "cjs":
      return javascript({ jsx: true });
    case "ts":
    case "tsx":
      return javascript({ jsx: true, typescript: true });
    case "json":
      return json();
    case "md":
    case "markdown":
      return markdown();
    case "rs":
      return rust();
    case "py":
      return python();
    case "css":
    case "scss":
    case "less":
      return css();
    case "html":
    case "htm":
      return html();
    default:
      return null;
  }
}
