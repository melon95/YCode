// CodeMirror 6 editor. Each open file keeps its in-memory buffer in
// `filesRef` so switching tabs preserves unsaved edits. ⌘S saves the active
// file. An fs.watch on the focused file detects external edits and shows
// either an auto-reload (clean buffer) or a conflict banner (dirty buffer).

import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { watch } from "@tauri-apps/plugin-fs";
import { toast } from "@heroui/react";
import CodeMirror, { type ReactCodeMirrorRef } from "@uiw/react-codemirror";
import {
  EditorView,
  keymap,
  runScopeHandlers,
  type Panel,
  type ViewUpdate,
} from "@codemirror/view";
import { Prec, type Extension } from "@codemirror/state";
import {
  ArrowDown,
  ArrowUp,
  CaseSensitive,
  ChevronRight,
  List,
  Regex,
  Replace,
  ReplaceAll,
  WholeWord,
  X,
  type LucideIcon,
} from "lucide-react";
import { indentWithTab } from "@codemirror/commands";
import { indentUnit, StreamLanguage, foldService } from "@codemirror/language";
import {
  SearchQuery,
  closeSearchPanel,
  findNext,
  findPrevious,
  getSearchQuery,
  highlightSelectionMatches,
  replaceAll,
  replaceNext,
  search,
  searchKeymap,
  selectMatches,
  setSearchQuery,
} from "@codemirror/search";
import { javascript } from "@codemirror/lang-javascript";
import { json } from "@codemirror/lang-json";
import { markdown } from "@codemirror/lang-markdown";
import { rust } from "@codemirror/lang-rust";
import { python } from "@codemirror/lang-python";
import { css } from "@codemirror/lang-css";
import { html } from "@codemirror/lang-html";
import { yaml } from "@codemirror/lang-yaml";
import { xml } from "@codemirror/lang-xml";
import { toml } from "@codemirror/legacy-modes/mode/toml";
import { properties } from "@codemirror/legacy-modes/mode/properties";
import { dockerFile } from "@codemirror/legacy-modes/mode/dockerfile";
import { shell } from "@codemirror/legacy-modes/mode/shell";
import { java } from "@codemirror/lang-java";
import { csharp } from "@replit/codemirror-lang-csharp";
import { sql } from "@codemirror/lang-sql";
import { go } from "@codemirror/lang-go";
import { cpp } from "@codemirror/lang-cpp";
import { php } from "@codemirror/lang-php";
import { kotlin, scala, dart, objectiveC } from "@codemirror/legacy-modes/mode/clike";
import { ruby } from "@codemirror/legacy-modes/mode/ruby";
import { lua } from "@codemirror/legacy-modes/mode/lua";
import { perl } from "@codemirror/legacy-modes/mode/perl";
import { r } from "@codemirror/legacy-modes/mode/r";
import { swift } from "@codemirror/legacy-modes/mode/swift";
import { haskell } from "@codemirror/legacy-modes/mode/haskell";
import { clojure } from "@codemirror/legacy-modes/mode/clojure";
import { powerShell } from "@codemirror/legacy-modes/mode/powershell";
import { groovy } from "@codemirror/legacy-modes/mode/groovy";
import { julia } from "@codemirror/legacy-modes/mode/julia";
import { diff } from "@codemirror/legacy-modes/mode/diff";
import { protobuf } from "@codemirror/legacy-modes/mode/protobuf";
import { elm } from "@codemirror/legacy-modes/mode/elm";
import { erlang } from "@codemirror/legacy-modes/mode/erlang";
import { scheme } from "@codemirror/legacy-modes/mode/scheme";
import {
  lspDefinition,
  lspDidChange,
  lspDidClose,
  lspDidOpen,
  lspSemanticTokensFull,
  readFile,
  readFileDataUrl,
  writeFile,
} from "../lib/ipc";
import { useStore } from "../lib/store";
import { confirmDialog } from "../lib/confirm";
import { renderMarkdown } from "../lib/markdown";
import type { EditorGotoDetail } from "../lib/fileLinkProvider";
import {
  applyLspTokens,
  createLspExtension,
  type SemanticTokensResponse,
} from "../lib/lspExtension";

interface FileState {
  /// Last known disk contents — what a save will be compared against.
  original: string;
  /// In-memory buffer (== editor view's current value).
  value: string;
  isBinary: boolean;
  loaded: boolean;
}

export function EditorPanel({
  projectId,
  sessionId,
  rootPath,
}: {
  projectId: string;
  sessionId?: string;
  rootPath?: string;
}) {
  const openFiles = useStore((s) => s.openFiles);
  const selectedFilePath = useStore((s) => s.selectedFilePath);
  const closeFile = useStore((s) => s.closeFile);
  const setFileDirty = useStore((s) => s.setFileDirty);
  const openFile = useStore((s) => s.openFile);
  const editorFontSize = useStore((s) => s.fontSizes.editor);

  const filesRef = useRef<Map<string, FileState>>(new Map());
  // LSP-tracked files. `version` is the monotonic counter the server expects
  // on every didChange — incrementing per keystroke is cheap and avoids the
  // server discarding stale change notifications.
  const lspOpenRef = useRef<Map<string, { version: number; active: boolean }>>(
    new Map(),
  );
  const lspChangeTimerRef = useRef<Map<string, ReturnType<typeof setTimeout>>>(
    new Map(),
  );
  // We mutate filesRef in place for performance (CM emits onChange every
  // keystroke). Use a tiny render-tick to surface those mutations to React.
  const [, tick] = useReducer((x: number) => x + 1, 0);
  const [externalChange, setExternalChange] = useState(false);
  const skipNextWatchRef = useRef(false);
  const cmRef = useRef<ReactCodeMirrorRef>(null);
  // Preview/Raw toggle for markdown & SVG files, keyed by path so each tab
  // remembers its own choice. Files default to "preview" (absent from the map).
  const [previewModes, setPreviewModes] = useState<
    Record<string, "preview" | "raw">
  >({});
  const setPreviewMode = useCallback(
    (path: string, mode: "preview" | "raw") =>
      setPreviewModes((prev) => ({ ...prev, [path]: mode })),
    [],
  );

  // Drop cache entries for closed tabs so reopens re-read from disk.
  useEffect(() => {
    const open = new Set(openFiles);
    for (const path of Array.from(filesRef.current.keys())) {
      if (!open.has(path)) filesRef.current.delete(path);
    }
    // Mirror the close into the LSP: notify the server, clear the version
    // counter, and cancel any pending didChange debounce so a late timer
    // doesn't re-open a doc the server already forgot about.
    for (const path of Array.from(lspOpenRef.current.keys())) {
      if (!open.has(path)) {
        lspOpenRef.current.delete(path);
        const timer = lspChangeTimerRef.current.get(path);
        if (timer) clearTimeout(timer);
        lspChangeTimerRef.current.delete(path);
        void lspDidClose(projectId, path, sessionId).catch((err) =>
          console.warn("lsp didClose failed", err),
        );
      }
    }
  }, [openFiles, projectId, sessionId]);

  // Lazy-load the focused file (no IPC if already cached). Images/SVGs render
  // through <ImagePreview>, which fetches its own data URL — skip the text
  // read and LSP wiring entirely for them.
  useEffect(() => {
    if (!selectedFilePath) return;
    setExternalChange(false);
    if (isImagePath(selectedFilePath)) return;
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
    readFile(projectId, selectedFilePath, sessionId)
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
        // Hand the freshly loaded buffer to the LSP if we haven't already.
        // Binary files are skipped — no language server cares about them.
        if (!file.is_binary && !lspOpenRef.current.has(selectedFilePath)) {
          lspOpenRef.current.set(selectedFilePath, { version: 1, active: false });
          void lspDidOpen(
            projectId,
            selectedFilePath,
            file.contents,
            1,
            sessionId,
          )
            .then((active) => {
              if (cancelled) return;
              const entry = lspOpenRef.current.get(selectedFilePath);
              if (!entry) return;
              entry.active = active;
              if (active) void requestSemanticTokens(selectedFilePath);
            })
            .catch((err) => console.warn("lsp didOpen failed", err));
        }
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
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [projectId, sessionId, selectedFilePath, setFileDirty]);

  // Watch only the focused file. Inactive tabs catch up on next focus via
  // the load effect above.
  useEffect(() => {
    if (!selectedFilePath || !rootPath) return;
    if (isImagePath(selectedFilePath)) return;
    const abs = `${rootPath}/${selectedFilePath}`;
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
        readFile(projectId, selectedFilePath, sessionId)
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
  }, [projectId, sessionId, rootPath, selectedFilePath, setFileDirty]);

  // ── LSP helpers ────────────────────────────────────────────────────────
  //
  // Token decorations are pushed into the active CM6 view via dispatch; they
  // survive tab switches because `lspTokensField` is per-state and we
  // re-request on every (didOpen / didChange) for the focused tab.
  const requestSemanticTokens = useCallback(
    async (path: string) => {
      try {
        const resp = (await lspSemanticTokensFull(projectId, path, sessionId)) as
          | SemanticTokensResponse
          | null;
        if (useStore.getState().selectedFilePath !== path) return;
        const view = cmRef.current?.view;
        if (view) applyLspTokens(view, resp);
      } catch (err) {
        console.warn("lsp semantic tokens failed", err);
      }
    },
    [projectId, sessionId],
  );

  // Debounced didChange. Keystrokes within 300 ms collapse into one update —
  // both rust-analyzer and tsserver re-analyse on each change, so being too
  // chatty makes the server hog a core.
  const scheduleLspChange = useCallback(
    (path: string, value: string) => {
      const entry = lspOpenRef.current.get(path);
      if (!entry || !entry.active) return;
      const prev = lspChangeTimerRef.current.get(path);
      if (prev) clearTimeout(prev);
      const timer = setTimeout(() => {
        lspChangeTimerRef.current.delete(path);
        const cur = lspOpenRef.current.get(path);
        if (!cur || !cur.active) return;
        cur.version += 1;
        const nextVersion = cur.version;
        void lspDidChange(projectId, path, nextVersion, value, sessionId)
          .then(() => {
            if (useStore.getState().selectedFilePath === path) {
              void requestSemanticTokens(path);
            }
          })
          .catch((err) => console.warn("lsp didChange failed", err));
      }, 300);
      lspChangeTimerRef.current.set(path, timer);
    },
    [projectId, sessionId, requestSemanticTokens],
  );

  const handleGotoDef = useCallback(
    async (line: number, character: number) => {
      const path = useStore.getState().selectedFilePath;
      if (!path || !rootPath) return;
      try {
        const result = await lspDefinition(
          projectId,
          path,
          line,
          character,
          sessionId,
        );
        const loc = pickLspLocation(result);
        if (!loc) return;
        const abs = parseFileUri(loc.uri);
        if (!abs) return;
        // Anchor the prefix match on `/` so a repo at `/foo` doesn't match
        // `/foobar/...`. Same-file jumps are allowed via the equality arm.
        if (abs !== rootPath && !abs.startsWith(rootPath + "/")) return;
        const rel = abs === rootPath ? "" : abs.slice(rootPath.length + 1);
        if (!rel) return;
        openFile(rel);
        window.dispatchEvent(
          new CustomEvent<EditorGotoDetail>("ycode:editor-goto", {
            detail: {
              path: rel,
              line: loc.range.start.line + 1,
              column: loc.range.start.character + 1,
            },
          }),
        );
      } catch (err) {
        console.warn("lsp definition failed", err);
      }
    },
    [projectId, sessionId, rootPath, openFile],
  );

  const save = useCallback(async () => {
    if (!selectedFilePath) return;
    const fs = filesRef.current.get(selectedFilePath);
    if (!fs || !fs.loaded || fs.isBinary) return;
    if (fs.value === fs.original) return;
    skipNextWatchRef.current = true;
    try {
      await writeFile(
        {
          project_id: projectId,
          file_path: selectedFilePath,
          contents: fs.value,
        },
        sessionId,
      );
      fs.original = fs.value;
      setFileDirty(selectedFilePath, false);
      setExternalChange(false);
      tick();
    } catch (err) {
      skipNextWatchRef.current = false;
      toast.danger(`Save ${selectedFilePath}: ${err}`);
    }
  }, [projectId, sessionId, selectedFilePath, setFileDirty]);

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

  // `onGotoDef` reads through a ref so the CM6 mousedown handler doesn't
  // need to rebuild on every render (rebuilding would discard the editor's
  // history stack).
  const handleGotoDefRef = useRef(handleGotoDef);
  handleGotoDefRef.current = handleGotoDef;

  const extensions: Extension[] = useMemo(() => {
    const lang = languageFor(selectedFilePath);
    return [
      keymap.of([
        ...searchKeymap,
        {
          key: "Mod-s",
          preventDefault: true,
          run: () => {
            void saveRef.current();
            return true;
          },
        },
        // CM6 leaves Tab unbound by default (it moves focus, for keyboard
        // accessibility). Bind it to indent/dedent so the editor behaves
        // like VS Code; Esc-then-Tab still escapes for a11y per the command's
        // own design.
        indentWithTab,
      ]),
      // Match VS Code's per-language indent width (Rust/Python use 4 spaces,
      // web languages 2). CM6 otherwise defaults to a flat 2 spaces for
      // everything.
      indentUnit.of(indentUnitFor(selectedFilePath)),
      fontTheme,
      search({ top: true, createPanel: (view) => new YCodeSearchPanel(view) }),
      highlightSelectionMatches(),
      indentFoldService,
      ...(lang ? [lang] : []),
      ...createLspExtension({
        onGotoDef: (line, ch) => handleGotoDefRef.current(line, ch),
      }),
    ];
  }, [selectedFilePath, fontTheme]);

  async function discardAndReload() {
    if (!selectedFilePath) return;
    try {
      const file = await readFile(projectId, selectedFilePath, sessionId);
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
  const isImage = isImagePath(selectedFilePath);
  const previewKind = previewKindFor(selectedFilePath);
  const previewMode: "preview" | "raw" =
    (selectedFilePath ? previewModes[selectedFilePath] : undefined) ?? "preview";
  const showPreviewTabs = !!previewKind && loaded && !isBinary;

  return (
    <div className="editor-panel">
      {externalChange && (
        <div className="editor-warning">
          File changed on disk while you were editing.
          <button onClick={discardAndReload}>Discard &amp; reload</button>
        </div>
      )}
      {showPreviewTabs && selectedFilePath && (
        <div className="preview-tabs" role="tablist" aria-label="Preview mode">
          <button
            type="button"
            className={previewMode === "preview" ? "active" : ""}
            onClick={() => setPreviewMode(selectedFilePath, "preview")}
            role="tab"
            aria-selected={previewMode === "preview"}
            aria-label="Preview"
            title="Preview"
          >
            <PreviewIcon />
          </button>
          <button
            type="button"
            className={previewMode === "raw" ? "active" : ""}
            onClick={() => setPreviewMode(selectedFilePath, "raw")}
            role="tab"
            aria-selected={previewMode === "raw"}
            aria-label="Raw"
            title="Raw"
          >
            <RawIcon />
          </button>
        </div>
      )}
      {!selectedFilePath ? null : isImage ? (
        <ImagePreview
          projectId={projectId}
          path={selectedFilePath}
          sessionId={sessionId}
          rootPath={rootPath}
        />
      ) : isBinary ? (
        <div className="empty">Binary file — editor cannot display.</div>
      ) : !loaded ? (
        <div className="empty">Loading…</div>
      ) : previewKind && previewMode === "preview" ? (
        previewKind === "markdown" ? (
          <MarkdownPreview value={value} />
        ) : (
          <SvgPreview value={value} />
        )
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
            scheduleLspChange(selectedFilePath, v);
          }}
          basicSetup={{
            highlightActiveLine: true,
            highlightActiveLineGutter: true,
            foldGutter: true,
            lineNumbers: true,
            indentOnInput: true,
            searchKeymap: false,
            highlightSelectionMatches: false,
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

class YCodeSearchPanel implements Panel {
  readonly dom: HTMLElement;
  private query: SearchQuery;
  private searchField: HTMLInputElement;
  private replaceField: HTMLInputElement;
  private caseField: HTMLInputElement;
  private reField: HTMLInputElement;
  private wordField: HTMLInputElement;
  private toggle: HTMLButtonElement;
  private status: HTMLSpanElement;
  private iconRoots: Root[] = [];

  constructor(private view: EditorView) {
    this.query = getSearchQuery(view.state);
    this.dom = element("div", {
      className: "ycode-search-panel replace-collapsed",
    });
    this.dom.addEventListener("keydown", (event) => this.keydown(event));

    this.toggle = this.iconButton("toggle-replace", "Toggle replace", ChevronRight, () => {
      const collapsed = this.dom.classList.toggle("replace-collapsed");
      this.toggle.setAttribute("aria-expanded", String(!collapsed));
    });
    this.toggle.classList.add("cm-search-replace-toggle");
    this.toggle.setAttribute("aria-expanded", "false");

    this.searchField = this.textField("search", "Find", this.query.search);
    this.searchField.setAttribute("main-field", "true");
    this.replaceField = this.textField("replace", "Replace", this.query.replace);

    this.caseField = this.optionField("case", this.query.caseSensitive);
    this.reField = this.optionField("re", this.query.regexp);
    this.wordField = this.optionField("word", this.query.wholeWord);

    const searchOptions = element("div", { className: "cm-search-options" }, [
      this.optionButton(this.caseField, "Match case", CaseSensitive),
      this.optionButton(this.wordField, "Match whole word", WholeWord),
      this.optionButton(this.reField, "Use regular expression", Regex),
    ]);

    this.status = element("span", { className: "cm-search-status" });
    this.status.setAttribute("aria-live", "polite");

    const actions = element("div", { className: "cm-search-actions" }, [
      this.iconButton("prev", "Previous match", ArrowUp, () => findPrevious(this.view)),
      this.iconButton("next", "Next match", ArrowDown, () => findNext(this.view)),
      this.iconButton("select", "Select all matches", List, () => selectMatches(this.view)),
      this.iconButton("close", "Close search", X, () => closeSearchPanel(this.view)),
    ]);

    const replaceActions = element("div", { className: "cm-search-replace-actions" }, [
      this.iconButton("replace", "Replace", Replace, () => replaceNext(this.view)),
      this.iconButton("replaceAll", "Replace all", ReplaceAll, () => replaceAll(this.view)),
    ]);

    // Four cells laid out by a 2-column grid in CSS: [find field | find
    // controls] over [replace field | replace actions]. The two fields share
    // the grid's 1fr column so they stay equal width with aligned edges.
    const findField = element("div", { className: "cm-search-field-wrap cm-search-find-field" }, [
      this.searchField,
      searchOptions,
    ]);
    const findControls = element("div", { className: "cm-search-controls" }, [
      this.status,
      actions,
    ]);
    const replaceField = element(
      "div",
      { className: "cm-search-field-wrap cm-search-replace-cell" },
      [this.replaceField],
    );
    replaceActions.classList.add("cm-search-replace-cell");

    this.dom.append(
      this.toggle,
      element("div", { className: "cm-search-body" }, [
        findField,
        findControls,
        replaceField,
        replaceActions,
      ]),
    );

    this.updateStatus();
  }

  mount() {
    this.searchField.select();
  }

  update(update: ViewUpdate) {
    for (const tr of update.transactions) {
      for (const effect of tr.effects) {
        if (effect.is(setSearchQuery) && !effect.value.eq(this.query)) {
          this.setQuery(effect.value);
        }
      }
    }
    if (update.docChanged || update.selectionSet || update.transactions.length) {
      this.updateStatus();
    }
  }

  destroy() {
    for (const root of this.iconRoots) root.unmount();
  }

  get pos() {
    return 80;
  }

  get top() {
    return true;
  }

  private commit() {
    const query = new SearchQuery({
      search: this.searchField.value,
      replace: this.replaceField.value,
      caseSensitive: this.caseField.checked,
      regexp: this.reField.checked,
      wholeWord: this.wordField.checked,
    });
    if (!query.eq(this.query)) {
      this.query = query;
      this.view.dispatch({ effects: setSearchQuery.of(query) });
      this.updateStatus();
    }
  }

  private keydown(event: KeyboardEvent) {
    if (runScopeHandlers(this.view, event, "search-panel")) {
      event.preventDefault();
    } else if (event.key === "Enter" && event.target === this.searchField) {
      event.preventDefault();
      (event.shiftKey ? findPrevious : findNext)(this.view);
    } else if (event.key === "Enter" && event.target === this.replaceField) {
      event.preventDefault();
      replaceNext(this.view);
    }
  }

  private setQuery(query: SearchQuery) {
    this.query = query;
    this.searchField.value = query.search;
    this.replaceField.value = query.replace;
    this.caseField.checked = query.caseSensitive;
    this.reField.checked = query.regexp;
    this.wordField.checked = query.wholeWord;
    this.updateStatus();
  }

  private updateStatus() {
    const query = getSearchQuery(this.view.state);
    if (!query.search || !query.valid) {
      this.status.textContent = "";
      return;
    }

    let total = 0;
    let active = 0;
    const head = this.view.state.selection.main.head;
    const cursor = query.getCursor(this.view.state);
    for (let next = cursor.next(); !next.done; next = cursor.next()) {
      total += 1;
      const match = next.value;
      if (match.from <= head && head <= match.to) active = total;
      if (total > 999) break;
    }

    if (total === 0) {
      this.status.textContent = "No results";
    } else if (total > 999) {
      this.status.textContent = "999+ results";
    } else {
      this.status.textContent = `${active || 1} / ${total}`;
    }
  }

  private textField(name: string, placeholder: string, value: string) {
    const input = element("input", {
      className: "cm-textfield",
      name,
      value,
      placeholder,
    }) as HTMLInputElement;
    input.type = "text";
    input.setAttribute("aria-label", placeholder);
    input.autocomplete = "off";
    input.addEventListener("input", () => this.commit());
    input.addEventListener("change", () => this.commit());
    return input;
  }

  private optionField(name: string, checked: boolean) {
    const input = element("input", { name }) as HTMLInputElement;
    input.type = "checkbox";
    input.checked = checked;
    input.addEventListener("change", () => this.commit());
    return input;
  }

  private optionButton(input: HTMLInputElement, label: string, Icon: LucideIcon) {
    const option = element("label", {
      className: "cm-search-option",
      title: label,
    });
    option.dataset.tooltip = label;
    option.setAttribute("aria-label", label);
    const icon = element("span", { className: "cm-search-option-icon" });
    this.renderIcon(icon, Icon);
    option.append(input, icon);
    return option;
  }

  private iconButton(
    name: string,
    label: string,
    Icon: LucideIcon,
    onClick: () => void,
  ) {
    const button = element("button", { name, title: label }) as HTMLButtonElement;
    button.type = "button";
    button.dataset.ycodeIcon = "true";
    button.dataset.tooltip = label;
    button.setAttribute("aria-label", label);
    button.addEventListener("click", onClick);
    this.renderIcon(button, Icon);
    return button;
  }

  private renderIcon(target: HTMLElement, Icon: LucideIcon) {
    const root = createRoot(target);
    this.iconRoots.push(root);
    root.render(
      <Icon aria-hidden="true" focusable="false" size={16} strokeWidth={2} />,
    );
  }
}

function element<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  props: Record<string, string> = {},
  children: Array<Node | string> = [],
): HTMLElementTagNameMap[K] {
  const dom = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (key === "className") dom.className = value;
    else if (key === "value" && dom instanceof HTMLInputElement) dom.value = value;
    else dom.setAttribute(key, value);
  }
  dom.append(...children);
  return dom;
}

/// Eye icon for the rendered "Preview" mode.
function PreviewIcon() {
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
      <path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7-10-7-10-7z" />
      <circle cx="12" cy="12" r="3" />
    </svg>
  );
}

/// Angle-brackets icon for the editable "Raw" (source) mode.
function RawIcon() {
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
      <path d="M8 8l-4 4 4 4" />
      <path d="M16 8l4 4-4 4" />
    </svg>
  );
}

// Raster images are binary — preview only, no source to edit. SVG and Markdown
// are text, so they get a Preview/Raw toggle instead (see previewKindFor).
const IMAGE_EXTS = new Set([
  "png",
  "jpg",
  "jpeg",
  "gif",
  "webp",
  "bmp",
  "ico",
  "avif",
  "apng",
]);

/// True for raster image files we render as an inline (non-editable) preview.
function isImagePath(path: string | null): boolean {
  if (!path) return false;
  const ext = path.split(".").pop()?.toLowerCase() ?? "";
  return IMAGE_EXTS.has(ext);
}

/// Text files that render a preview by default but can be edited via the Raw
/// tab. Returns the renderer to use, or null for plain editor-only files.
function previewKindFor(path: string | null): "markdown" | "svg" | null {
  if (!path) return null;
  const ext = path.split(".").pop()?.toLowerCase() ?? "";
  if (ext === "svg") return "svg";
  if (ext === "md" || ext === "markdown") return "markdown";
  return null;
}

/// Sanitized markdown preview. Reads the live editor buffer so switching back
/// from Raw shows unsaved edits.
function MarkdownPreview({ value }: { value: string }) {
  const html = useMemo(() => renderMarkdown(value), [value]);
  return (
    <div
      className="markdown-preview"
      // Sanitized in renderMarkdown via DOMPurify.
      dangerouslySetInnerHTML={{ __html: html }}
    />
  );
}

/// SVG preview rendered through an <img> + data URL so any embedded <script>
/// can't execute (image-loaded SVGs run in a restricted mode). Reflects the
/// live buffer including unsaved edits.
function SvgPreview({ value }: { value: string }) {
  const src = useMemo(
    () => `data:image/svg+xml;utf8,${encodeURIComponent(value)}`,
    [value],
  );
  return (
    <div className="image-preview">
      <img src={src} alt="SVG preview" />
    </div>
  );
}

/// Inline image/SVG preview. Fetches the file as a base64 `data:` URL (no raw
/// filesystem path is exposed to the WebView) and re-fetches when the file
/// changes on disk so saving from an external tool updates the preview live.
function ImagePreview({
  projectId,
  path,
  sessionId,
  rootPath,
}: {
  projectId: string;
  path: string;
  sessionId?: string;
  rootPath?: string;
}) {
  const [src, setSrc] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setSrc(null);
    setError(null);
    const load = () => {
      readFileDataUrl(projectId, path, sessionId)
        .then((url) => {
          if (!cancelled) setSrc(url);
        })
        .catch((err) => {
          if (!cancelled) setError(String(err));
        });
    };
    load();

    if (!rootPath) {
      return () => {
        cancelled = true;
      };
    }
    const abs = `${rootPath}/${path}`;
    let unwatch: (() => void) | undefined;
    watch(abs, () => !cancelled && load(), { delayMs: 300 })
      .then((fn) => {
        if (cancelled) fn();
        else unwatch = fn;
      })
      .catch((err) => console.warn("image watch failed", err));
    return () => {
      cancelled = true;
      unwatch?.();
    };
  }, [projectId, path, sessionId, rootPath]);

  if (error) {
    return <div className="empty">Failed to load image: {error}</div>;
  }
  if (!src) {
    return <div className="empty">Loading…</div>;
  }
  return (
    <div className="image-preview">
      <img src={src} alt={basename(path)} />
    </div>
  );
}

interface LspPosition {
  line: number;
  character: number;
}
interface LspRange {
  start: LspPosition;
  end: LspPosition;
}

/// Normalise the three LSP `textDocument/definition` return shapes (single
/// `Location`, `Location[]`, or `LocationLink[]`) to a uniform target.
/// Returns the first hit when the server gives us a list — multi-definition
/// disambiguation belongs in a future menu, not the unconditional jump.
function pickLspLocation(
  result: unknown,
): { uri: string; range: LspRange } | null {
  if (!result) return null;
  if (Array.isArray(result)) {
    if (result.length === 0) return null;
    return pickLspLocation(result[0]);
  }
  if (typeof result !== "object") return null;
  const r = result as Record<string, unknown>;
  if (typeof r.uri === "string" && r.range) {
    return { uri: r.uri, range: r.range as LspRange };
  }
  if (typeof r.targetUri === "string") {
    const range = (r.targetSelectionRange ?? r.targetRange) as
      | LspRange
      | undefined;
    if (range) return { uri: r.targetUri, range };
  }
  return null;
}

/// `file:///abs/path` → `/abs/path`. Returns null for non-file schemes so
/// the goto-def jump silently ignores http:// links a server might surface
/// (some report stdlib stubs that way).
function parseFileUri(uri: string): string | null {
  if (!uri.startsWith("file://")) return null;
  try {
    // `file://localhost/...` and `file:///...` both decode to a leading `/`
    // — slice past the scheme and any optional authority.
    const stripped = uri.replace(/^file:\/\/[^/]*/, "");
    return decodeURI(stripped);
  } catch {
    return null;
  }
}

/// VS Code-style per-language indent width, as the literal whitespace one
/// indent level inserts. Rust and Python convention is 4 spaces; web
/// languages (JS/TS/JSON/CSS/HTML) and everything else default to 2.
function indentUnitFor(path: string | null): string {
  const ext = path?.split(".").pop()?.toLowerCase() ?? "";
  switch (ext) {
    case "rs":
    case "py":
    case "java":
    case "cs":
    case "csx":
      return "    ";
    default:
      return "  ";
  }
}

/// Leading-whitespace width of a line, or -1 for blank/whitespace-only lines.
/// Tabs count as one column each — good enough for deciding nesting depth.
function measureIndent(text: string): number {
  let i = 0;
  while (i < text.length && (text[i] === " " || text[i] === "\t")) i++;
  return i === text.length ? -1 : i;
}

/// Indentation-based folding fallback. CodeMirror's Lezer-backed languages
/// (JS/TS/JSON/Python/Rust/…) ship syntax-tree folding, but the legacy
/// `StreamLanguage` modes (Java, C#, TOML, shell, Dockerfile, …) provide none,
/// so their fold gutter is dead. This folds any line whose following lines are
/// more indented. Registered at lowest precedence so real language folding
/// wins wherever it exists.
const indentFoldService = Prec.lowest(
  foldService.of((state, lineStart, lineEnd) => {
    const first = state.doc.lineAt(lineStart);
    const baseIndent = measureIndent(first.text);
    if (baseIndent < 0) return null;
    let lastLine = -1;
    for (let n = first.number + 1; n <= state.doc.lines; n++) {
      const line = state.doc.line(n);
      const indent = measureIndent(line.text);
      if (indent < 0) continue; // ignore blank lines, don't extend on them
      if (indent > baseIndent) lastLine = n;
      else break;
    }
    if (lastLine < 0) return null;
    return { from: lineEnd, to: state.doc.line(lastLine).to };
  }),
);

function languageFor(path: string | null): Extension | null {
  if (!path) return null;
  const name = (path.split("/").pop() ?? "").toLowerCase();
  // Special-name config files that carry no (useful) extension.
  if (name === "dockerfile" || name.startsWith("dockerfile.")) {
    return StreamLanguage.define(dockerFile);
  }
  // Extensionless Ruby project files (Gemfile, Rakefile, Podfile, …).
  if (
    name === "gemfile" ||
    name === "rakefile" ||
    name === "podfile" ||
    name === "brewfile" ||
    name === "vagrantfile" ||
    name === "guardfile"
  ) {
    return StreamLanguage.define(ruby);
  }
  // Dotfiles like `.env` / `.bashrc` keep their "extension" after the dot;
  // extensionless names (e.g. `Makefile`) fall through as the whole name.
  const ext = name.includes(".") ? (name.split(".").pop() ?? "") : name;
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
    case "jsonc":
    case "json5":
      return json();
    case "md":
    case "markdown":
      return markdown();
    case "rs":
      return rust();
    case "py":
      return python();
    case "java":
      return java();
    case "cs":
    case "csx":
      return csharp();
    case "sql":
    case "ddl":
    case "dml":
      return sql();
    case "go":
      return go();
    case "c":
    case "h":
    case "cc":
    case "cpp":
    case "cxx":
    case "c++":
    case "hpp":
    case "hh":
    case "hxx":
      return cpp();
    case "php":
    case "phtml":
      return php();
    case "rb":
    case "rake":
    case "gemspec":
    case "podspec":
      return StreamLanguage.define(ruby);
    case "kt":
    case "kts":
      return StreamLanguage.define(kotlin);
    case "scala":
    case "sc":
      return StreamLanguage.define(scala);
    case "dart":
      return StreamLanguage.define(dart);
    case "m":
    case "mm":
      return StreamLanguage.define(objectiveC);
    case "swift":
      return StreamLanguage.define(swift);
    case "lua":
      return StreamLanguage.define(lua);
    case "pl":
    case "pm":
      return StreamLanguage.define(perl);
    case "r":
      return StreamLanguage.define(r);
    case "hs":
      return StreamLanguage.define(haskell);
    case "clj":
    case "cljs":
    case "cljc":
    case "edn":
      return StreamLanguage.define(clojure);
    case "ps1":
    case "psm1":
    case "psd1":
      return StreamLanguage.define(powerShell);
    case "groovy":
    case "gradle":
      return StreamLanguage.define(groovy);
    case "jl":
      return StreamLanguage.define(julia);
    case "elm":
      return StreamLanguage.define(elm);
    case "erl":
    case "hrl":
      return StreamLanguage.define(erlang);
    case "scm":
    case "ss":
      return StreamLanguage.define(scheme);
    case "proto":
      return StreamLanguage.define(protobuf);
    case "diff":
    case "patch":
      return StreamLanguage.define(diff);
    case "css":
    case "scss":
    case "less":
      return css();
    case "html":
    case "htm":
      return html();
    // ── Config / data formats ───────────────────────────────────────────
    case "yaml":
    case "yml":
      return yaml();
    case "xml":
    case "svg":
    case "xsd":
    case "xsl":
    case "xslt":
    case "plist":
      return xml();
    case "toml":
      return StreamLanguage.define(toml);
    case "ini":
    case "cfg":
    case "conf":
    case "properties":
    case "env":
    case "editorconfig":
      return StreamLanguage.define(properties);
    case "sh":
    case "bash":
    case "zsh":
    case "ksh":
    case "fish":
    case "bashrc":
    case "zshrc":
    case "profile":
    case "bash_profile":
      return StreamLanguage.define(shell);
    default:
      return null;
  }
}
