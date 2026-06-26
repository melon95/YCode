import { useCallback, useEffect, useState } from "react";
import {
  Group,
  Panel,
  Separator,
  useDefaultLayout,
  usePanelRef,
} from "react-resizable-panels";
import {
  getConfig,
  listAgents,
  listProjects,
  listSessions,
  listTodos,
  listenSessionEvents,
  setActiveTerminal,
  startWorkspaceWatch,
  stopWorkspaceWatch,
} from "./lib/ipc";
import { useStore } from "./lib/store";
import { applyTheme, getTheme } from "./lib/themes";
import { useHotkeys } from "./lib/hotkeys";
import { TopBar } from "./components/TopBar";
import { Sidebar } from "./components/Sidebar";
import { TerminalPane } from "./components/TerminalPane";
import { RightPane } from "./components/RightPane";
import { CommandPalette } from "./components/CommandPalette";
import { HistoryTab } from "./components/HistoryTab";
import { AppLoading } from "./components/AppLoading";
import { UpdateNotice } from "./components/UpdateNotice";
import {
  bindUnlockOnClose,
  listenPeerLockEvents,
  readLockedProjectIdFromUrl,
  snapshotPeerLockedProjects,
} from "./lib/multiWindow";
import type { SearchHit } from "./lib/types";

const COLUMN_PANEL_IDS = ["sidebar", "middle", "right"];

export interface HistoryView {
  agent: string;
  sessionId: string;
  jsonlPath: string;
  focusSeq?: number;
  title?: string;
}

export function App() {
  const setSessions = useStore((s) => s.setSessions);
  const setProjects = useStore((s) => s.setProjects);
  const setAgents = useStore((s) => s.setAgents);
  const setLiveTitle = useStore((s) => s.setLiveTitle);
  const activeId = useStore((s) => s.activeId);
  const clearAttention = useStore((s) => s.clearAttention);
  const activeProjectId = useStore((s) => s.activeProjectId);
  const fontSizes = useStore((s) => s.fontSizes);
  const setFontSizes = useStore((s) => s.setFontSizes);
  const setTheme = useStore((s) => s.setTheme);
  const setLockedProjectId = useStore((s) => s.setLockedProjectId);
  const setLockedByOtherWindows = useStore((s) => s.setLockedByOtherWindows);
  const addLockedByOther = useStore((s) => s.addLockedByOther);
  const removeLockedByOther = useStore((s) => s.removeLockedByOther);

  // Lock-from-URL must run before the projects fetch returns so `setProjects`
  // can honour the lock when picking the active project. Reading the URL is
  // synchronous; the peer snapshot is async but the lock alone is enough to
  // skip the localStorage fallback.
  useEffect(() => {
    const id = readLockedProjectIdFromUrl();
    if (id) setLockedProjectId(id);
    let unlistenPeers: (() => void) | undefined;
    let unlistenClose: (() => void) | undefined;
    let cancelled = false;
    snapshotPeerLockedProjects().then((set) => {
      if (cancelled) return;
      setLockedByOtherWindows([...set]);
    });
    unlistenPeers = listenPeerLockEvents({
      onLocked: addLockedByOther,
      onUnlocked: removeLockedByOther,
    });
    if (id) {
      bindUnlockOnClose(id).then((u) => {
        if (cancelled) u();
        else unlistenClose = u;
      });
    }
    return () => {
      cancelled = true;
      unlistenPeers?.();
      unlistenClose?.();
    };
  }, [setLockedProjectId, setLockedByOtherWindows, addLockedByOther, removeLockedByOther]);

  const [paletteOpen, setPaletteOpen] = useState(false);
  const [history, setHistory] = useState<HistoryView | null>(null);
  /// Loading-curtain gate. We hide it only when *all three* of:
  ///   - the projects/sessions/agents initial fetch has returned (or errored)
  ///   - the display fonts (Fraunces et al.) have finished loading, so the
  ///     wordmark isn't shown with a system fallback that swaps mid-fade
  ///   - the curtain has been **fully visible** (post-fade-in) for at least
  ///     800ms, so the loading state reads as an intentional moment rather
  ///     than a sub-second flash. Pegging this to fonts-loaded (not mount)
  ///     means the full-visibility timer starts only after Fraunces has
  ///     swapped in, so the user actually sees the wordmark for the full
  ///     window.
  /// ...are satisfied. A 1.6s safety timer on the font gate prevents a
  /// missing-CDN scenario from keeping the user staring at the curtain.
  const FADE_IN_MS = 380;
  const HOLD_MS = 800;
  const [ready, setReady] = useState(false);
  const [fetched, setFetched] = useState(false);
  const [holdElapsed, setHoldElapsed] = useState(false);
  const [fontsReady, setFontsReady] = useState(false);
  useEffect(() => {
    let cancelled = false;
    const fallback = setTimeout(() => {
      if (!cancelled) setFontsReady(true);
    }, 1600);
    const fonts = (document as Document & { fonts?: { ready?: Promise<unknown> } }).fonts;
    if (fonts?.ready) {
      fonts.ready.then(() => {
        if (cancelled) return;
        clearTimeout(fallback);
        setFontsReady(true);
      });
    } else {
      clearTimeout(fallback);
      setFontsReady(true);
    }
    return () => {
      cancelled = true;
      clearTimeout(fallback);
    };
  }, []);
  // Start the "fully visible" hold timer only after fonts are in — that's
  // the moment the curtain stops mutating and the user can actually take
  // in what they're looking at.
  useEffect(() => {
    if (!fontsReady) return;
    const t = setTimeout(() => setHoldElapsed(true), FADE_IN_MS + HOLD_MS);
    return () => clearTimeout(t);
  }, [fontsReady]);
  useEffect(() => {
    if (fetched && holdElapsed && fontsReady) setReady(true);
  }, [fetched, holdElapsed, fontsReady]);

  // Persist column widths across reloads. Panel ids must match the literal
  // ids passed to <Panel> below or the restored layout won't apply.
  const { defaultLayout, onLayoutChanged } = useDefaultLayout({
    id: "ycode-columns",
    panelIds: COLUMN_PANEL_IDS,
    storage: typeof window !== "undefined" ? window.localStorage : undefined,
  });
  // Imperative handles for collapse/expand hotkeys.
  const sidebarRef = usePanelRef();
  const rightPaneRef = usePanelRef();
  const openCommandPalette = useCallback(() => setPaletteOpen(true), []);
  useHotkeys({ sidebarRef, rightPaneRef, openCommandPalette });

  // Suppress the WebView's native right-click menu (its lone "Reload" entry
  // would let users blow away app state). Editable surfaces keep their menu so
  // native cut/copy/paste/spellcheck still works in text fields and the editor.
  useEffect(() => {
    const onContextMenu = (e: MouseEvent) => {
      const target = e.target instanceof HTMLElement ? e.target : null;
      if (
        target?.closest(
          "input, textarea, [contenteditable=''], [contenteditable='true']",
        )
      ) {
        return;
      }
      e.preventDefault();
    };
    window.addEventListener("contextmenu", onContextMenu);
    return () => window.removeEventListener("contextmenu", onContextMenu);
  }, []);

  // Lets non-hook callers (TopBar button, future Dock-menu deep links) open
  // the palette without prop-drilling. Mirrors `ycode:close-file` pattern.
  useEffect(() => {
    const onOpen = () => setPaletteOpen(true);
    const onOpenHistory = (event: Event) => {
      const detail = (event as CustomEvent<HistoryView>).detail;
      if (detail) setHistory(detail);
    };
    window.addEventListener("ycode:open-palette", onOpen);
    window.addEventListener("ycode:open-history", onOpenHistory);
    return () => {
      window.removeEventListener("ycode:open-palette", onOpen);
      window.removeEventListener("ycode:open-history", onOpenHistory);
    };
  }, []);

  // Start a jsonl watcher for the active project. Switching projects swaps
  // watchers; unmounting cancels.
  useEffect(() => {
    if (!activeProjectId) return;
    let cancelled = false;
    const pid = activeProjectId;
    void startWorkspaceWatch(pid).catch(() => {
      /* best-effort: backend may not yet be ready */
    });
    return () => {
      if (cancelled) return;
      cancelled = true;
      void stopWorkspaceWatch(pid).catch(() => {});
    };
  }, [activeProjectId]);

  useEffect(() => {
    let unlisten: (() => void) | undefined;
    let cancelled = false;

    const refresh = () => {
      Promise.all([listProjects(), listSessions(), listAgents(), getConfig()])
        .then(([projects, sessions, agents, config]) => {
          if (cancelled) return;
          setProjects(projects);
          setSessions(sessions);
          setAgents(agents);
          setFontSizes(config.font_sizes);
          setTheme(config.theme);
          setFetched(true);
        })
        .catch((err) => {
          console.error("initial load failed", err);
          // Lift the curtain even on failure — otherwise the user is stuck
          // staring at "preparing workbench" forever and can't reach any UI.
          if (!cancelled) setFetched(true);
        });
    };
    refresh();

    listenSessionEvents((event) => {
      const kind = event.kind;
      if (kind.type === "PtyOutput" || kind.type === "PtyExit") {
        // Output never moves the status light (the waiting→running flip is
        // driven by user input in terminalInput.ts — see the note there).
        if (kind.type === "PtyExit") refresh();
        return;
      }
      if (kind.type === "TitleChanged") {
        setLiveTitle(event.session_id, kind.title);
        return;
      }
      if (kind.type === "JsonlChanged") {
        // HistoryTab subscribes directly; nothing to do here.
        return;
      }
      if (kind.type === "TodosChanged") {
        // `session_id` carries the affected project id. Refresh that
        // project's list so both UI edits and MCP-driven changes (an AI
        // agent adding/updating todos) show up live.
        const projectId = event.session_id;
        listTodos(projectId)
          .then((todos) => useStore.getState().setTodos(projectId, todos))
          .catch((err) => console.error("listTodos failed", err));
        return;
      }
      if (kind.type === "AgentTurnComplete") {
        // Skip the badge when the user is in the window AND looking at this
        // exact pane — they don't need a visual cue for the very pane on
        // screen. Backend applies the same gate to the OS notification.
        // Read from the store imperatively to dodge the stale closure that
        // a captured `activeId` dep would produce.
        const { activeId: focusedId, markAttention, setActivity } =
          useStore.getState();
        // The status light is focus-independent: the agent is waiting for the
        // user regardless of which pane they're looking at, so always set it.
        setActivity(event.session_id, "waiting");
        const windowFocused =
          typeof document !== "undefined" && document.hasFocus();
        if (!(windowFocused && focusedId === event.session_id)) {
          markAttention(event.session_id);
        }
        return;
      }
      refresh();
    }).then((u) => {
      if (cancelled) u();
      else unlisten = u;
    });

    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, [setSessions, setProjects, setAgents, setFontSizes, setTheme, setLiveTitle]);

  // UI font size → CSS variable. Chrome (sidebar / tab strip / file tree /
  // top bar) reads `--ui-font-size`. Editor and terminal layers don't go
  // through CSS — they live in CodeMirror / xterm inline props instead, see
  // EditorPanel and TerminalPane / ManualTerminal.
  useEffect(() => {
    document.documentElement.style.setProperty(
      "--ui-font-size",
      `${fontSizes.ui}px`,
    );
  }, [fontSizes.ui]);

  // Active theme → CSS variable map on `:root`. Critically NOT routed
  // through `useStore((s) => s.theme)` — that selector would make App.tsx
  // (the root of the React tree) re-render on every theme switch, which
  // cascades into re-renders of TopBar, Sidebar, TerminalPane, RightPane
  // and every editor / file tree inside. The CSS variable write itself is
  // sub-millisecond; the bulk of the lag users see is the React work
  // triggered by that subscription. So we wire the apply path through the
  // store's vanilla `subscribe()` API — fires synchronously on state
  // change, sidesteps React entirely.
  //
  // `getTheme` falls back to Foundry when the persisted id is unknown
  // (forward-compatible config files). xterm panes still subscribe to
  // `theme` themselves because they need to reach into live `term.options`
  // when the theme moves — a CSS swap alone can't repaint xterm.
  useEffect(() => {
    applyTheme(getTheme(useStore.getState().theme));
    return useStore.subscribe((state, prev) => {
      if (state.theme !== prev.theme) {
        applyTheme(getTheme(state.theme));
      }
    });
  }, []);

  // Mirror the focused pane to the backend so the agent-event pump can skip
  // OS notifications when the user is already looking at the firing pane.
  // Also drop any attention badge on the now-active session — the user is
  // visibly acknowledging it.
  useEffect(() => {
    if (activeId) clearAttention(activeId);
    void setActiveTerminal(activeId).catch(() => {
      // Best-effort: a missed update just means an extra notification, not
      // a correctness issue. Don't surface noise here.
    });
  }, [activeId, clearAttention]);

  // Coming back to the window while looking at a flagged pane shouldn't keep
  // the dot lit — the user has now seen it. Without this, an event that
  // landed while the window was unfocused would leave an attention badge on
  // the very pane the user just refocused on.
  useEffect(() => {
    const onFocus = () => {
      const { activeId: focusedId, clearAttention } = useStore.getState();
      if (focusedId) clearAttention(focusedId);
    };
    window.addEventListener("focus", onFocus);
    return () => window.removeEventListener("focus", onFocus);
  }, []);

  function onPickHit(hit: SearchHit) {
    setHistory({
      agent: hit.agent,
      sessionId: hit.session_id,
      jsonlPath: hit.jsonl_path,
      focusSeq: hit.seq,
    });
  }

  return (
    <>
      <AppLoading ready={ready} />
      <TopBar />
      <Group
        orientation="horizontal"
        className="columns"
        defaultLayout={defaultLayout}
        onLayoutChanged={onLayoutChanged}
      >
        <Panel
          id="sidebar"
          defaultSize="20%"
          minSize="12%"
          collapsible
          collapsedSize="0"
          panelRef={sidebarRef}
        >
          <Sidebar />
        </Panel>
        <Separator className="col-handle" />
        <Panel id="middle" defaultSize="40%" minSize="20%">
          <TerminalPane />
        </Panel>
        <Separator className="col-handle" />
        <Panel
          id="right"
          defaultSize="40%"
          minSize="20%"
          collapsible
          collapsedSize="0"
          panelRef={rightPaneRef}
        >
          <RightPane />
        </Panel>
      </Group>
      <CommandPalette
        open={paletteOpen}
        onClose={() => setPaletteOpen(false)}
        onPick={onPickHit}
      />
      <UpdateNotice />
      {history && (
        <div className="history-backdrop" onClick={() => setHistory(null)}>
          <div className="history-modal" onClick={(e) => e.stopPropagation()}>
            <HistoryTab
              agent={history.agent}
              sessionId={history.sessionId}
              jsonlPath={history.jsonlPath}
              focusSeq={history.focusSeq}
              title={history.title}
              onClose={() => setHistory(null)}
            />
          </div>
        </div>
      )}
    </>
  );
}
