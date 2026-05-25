import { useCallback, useEffect, useState } from "react";
import {
  Group,
  Panel,
  Separator,
  useDefaultLayout,
  usePanelRef,
} from "react-resizable-panels";
import {
  listAgents,
  listProjects,
  listSessions,
  listenSessionEvents,
  startWorkspaceWatch,
  stopWorkspaceWatch,
} from "./lib/ipc";
import { useStore } from "./lib/store";
import { useHotkeys } from "./lib/hotkeys";
import { TopBar } from "./components/TopBar";
import { Sidebar } from "./components/Sidebar";
import { TerminalPane } from "./components/TerminalPane";
import { RightPane } from "./components/RightPane";
import { CommandPalette } from "./components/CommandPalette";
import { HistoryTab } from "./components/HistoryTab";
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
  const activeProjectId = useStore((s) => s.activeProjectId);

  const [paletteOpen, setPaletteOpen] = useState(false);
  const [history, setHistory] = useState<HistoryView | null>(null);

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
      Promise.all([listProjects(), listSessions(), listAgents()])
        .then(([projects, sessions, agents]) => {
          if (cancelled) return;
          setProjects(projects);
          setSessions(sessions);
          setAgents(agents);
        })
        .catch((err) => console.error("initial load failed", err));
    };
    refresh();

    listenSessionEvents((event) => {
      const kind = event.kind;
      if (kind.type === "PtyOutput" || kind.type === "PtyExit") {
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
      refresh();
    }).then((u) => {
      if (cancelled) u();
      else unlisten = u;
    });

    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, [setSessions, setProjects, setAgents, setLiveTitle]);

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
