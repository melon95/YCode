// xterm.js multi-pane host. Renders one Terminal instance per session id and
// places visible ones into a CSS-grid layout chosen by the user (stack /
// columns / 2×2 / main+side). Hidden terminals stay alive in an off-screen
// pool so closing a pane keeps the agent running and scrollback intact.
//
// Data flow:
//   • PtyOutput { data: base64 } → decode → terminal.write(bytes)
//   • terminal.onData(string)    → utf-8 encode → base64 → write_pty
//   • cell ResizeObserver        → FitAddon.fit() → resize_pty
//
// Membership-changing UiEventKind variants (SessionAppeared, etc.) are
// handled in App.tsx; here we only listen for the per-session PTY payload.
//
// Output buffering: PtyOutput/PtyExit can arrive between `create_session`
// returning and React mounting the cell for the new id. We buffer those
// bytes in `pendingRef` and drain them when the Terminal is created —
// otherwise the agent's startup banner would be lost.

import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { SearchAddon } from "@xterm/addon-search";
import { Unicode11Addon } from "@xterm/addon-unicode11";
import { WebLinksAddon } from "@xterm/addon-web-links";
import "@xterm/xterm/css/xterm.css";
import { toast } from "@heroui/react";
import {
  listenSessionEvents,
  openUrl,
  readPtyBacklog,
  renameSession,
  resizePty,
  writePty,
} from "../lib/ipc";
import { displaySessionTitle, useStore, type LayoutMode } from "../lib/store";
import { activateFilePath, createFileLinkProvider } from "../lib/fileLinkProvider";
import {
  attachImeInputBridge,
  isPrintableCharEvent,
} from "../lib/terminalInput";
import { getTheme } from "../lib/themes";
import { sessionLight, SESSION_LIGHT_LABEL } from "../lib/types";
import { NewSessionPicker } from "./NewSessionPicker";
import { AgentIcon } from "./AgentIcon";

type TermInstance = {
  term: Terminal;
  fit: FitAddon;
  container: HTMLDivElement;
  cleanup: () => void;
  /// Id of the theme last actually written into `term.options.theme`. We
  /// stamp this every time we (re)skin a Terminal so that hidden pool
  /// members can stay stale during a theme swap without paying their
  /// redraw cost up front — when a stale member is later attached to a
  /// visible slot, the reparent effect compares this against the current
  /// store theme and catches it up exactly once.
  lastThemeId: string;
};

// Non-color options live here; the theme block is grafted on at construction
// time from `lib/themes.ts` so a Settings → Appearance swap can re-skin live
// terminals (see `useEffect` watching `theme` below) instead of being baked
// in at boot.
const TERMINAL_BASE_OPTIONS = {
  fontFamily:
    'ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace',
  fontSize: 13,
  lineHeight: 1.2,
  cursorBlink: true,
  scrollback: 5000,
  // Force a floor on fg/bg contrast. xterm.js renders the SGR "dim" attribute
  // (which CLIs like Claude Code use for diff context lines, line numbers,
  // secondary text) by blending the foreground toward the background. On dark
  // themes that just darkens it; on light themes it washes near-black ink out
  // to near-invisible pale gray. minimumContrastRatio makes xterm re-darken
  // any pair below this ratio until it's legible — 4.5 = WCAG AA for body text.
  minimumContrastRatio: 4.5,
  // Required for the Unicode11Addon below — `term.unicode.activeVersion` is
  // proposed API in xterm.js.
  allowProposedApi: true,
} as const;

// User-draggable split positions, stored per `${mode}-${count}` key so each
// layout remembers its own divider drags. Switching mode reads from a fresh
// entry (or the defaults below); switching back restores prior drags.
//
// Positions are cumulative percentages in (0, 100). For a 3-column grid with
// cols=[33, 66] the cells span [0%, 33%], [33%, 66%], [66%, 100%].
interface LayoutSplits {
  cols: number[]; // length = grid cols - 1
  rows: number[]; // length = grid rows - 1
}
type SplitsMap = Record<string, LayoutSplits>;

const MIN_PANE_PCT = 12; // smallest pane width/height — keeps the TUI legible

function splitsKey(mode: LayoutMode, count: number): string {
  return `${mode}-${count}`;
}

function equalSplits(n: number): number[] {
  if (n <= 1) return [];
  return Array.from({ length: n - 1 }, (_, i) => ((i + 1) * 100) / n);
}

function defaultSplits(mode: LayoutMode, count: number): LayoutSplits {
  switch (mode) {
    case "single":
      return { cols: [], rows: [] };
    case "stack":
      return { cols: [], rows: equalSplits(count) };
    case "columns":
      return { cols: equalSplits(count), rows: [] };
    case "grid2x2":
      return { cols: [50], rows: [50] };
    case "main-side":
      // Side column has count-1 cells stacked vertically. Main is 60% wide
      // by default (matches the prior CSS-only 3fr:2fr ratio).
      return { cols: [60], rows: equalSplits(count - 1) };
  }
}

function splitsToTemplate(splits: number[], cellCount: number): string {
  if (cellCount <= 1) return "1fr";
  if (splits.length === 0) return new Array(cellCount).fill("1fr").join(" ");
  const parts: string[] = [];
  let prev = 0;
  for (const s of splits) {
    parts.push(`${s - prev}%`);
    prev = s;
  }
  parts.push(`${100 - prev}%`);
  return parts.join(" ");
}

interface GridDims {
  cols: number;
  rows: number;
}

function gridDims(mode: LayoutMode, count: number): GridDims {
  switch (mode) {
    case "single":
      return { cols: 1, rows: 1 };
    case "stack":
      return { cols: 1, rows: count };
    case "columns":
      return { cols: count, rows: 1 };
    case "grid2x2":
      return { cols: 2, rows: 2 };
    case "main-side":
      return { cols: 2, rows: count - 1 };
  }
}

interface GutterDef {
  axis: "col" | "row";
  splitIdx: number;
  // For row gutters in main-side: start at the col split so the gutter
  // only spans the side column, not across the main pane. Defaults to 0.
  startPct?: number;
  endPct?: number; // default 100
}

function gutterDefs(mode: LayoutMode, splits: LayoutSplits): GutterDef[] {
  if (mode === "single") return [];
  if (mode === "stack") {
    return splits.rows.map((_, i) => ({ axis: "row", splitIdx: i }));
  }
  if (mode === "columns") {
    return splits.cols.map((_, i) => ({ axis: "col", splitIdx: i }));
  }
  if (mode === "grid2x2") {
    return [
      { axis: "col", splitIdx: 0 },
      { axis: "row", splitIdx: 0 },
    ];
  }
  // main-side
  const colGutter: GutterDef = { axis: "col", splitIdx: 0 };
  const rowGutters: GutterDef[] = splits.rows.map((_, i) => ({
    axis: "row",
    splitIdx: i,
    startPct: splits.cols[0],
    endPct: 100,
  }));
  return [colGutter, ...rowGutters];
}

export function TerminalPane() {
  const sessions = useStore((s) => s.sessions);
  const liveTitles = useStore((s) => s.liveTitles);
  const layout = useStore((s) => s.layout);
  const projects = useStore((s) => s.projects);
  const activeProjectId = useStore((s) => s.activeProjectId);
  const agents = useStore((s) => s.agents);
  const terminalFontSize = useStore((s) => s.fontSizes.terminal);
  const activityBySession = useStore((s) => s.activityBySession);
  // Pane-header icon lookup. Sessions carry `agent_profile` (the launch
  // profile id), so we index by id here.
  const agentByProfileId = useMemo(() => {
    const out: Record<string, (typeof agents)[number]> = {};
    for (const a of agents) out[a.id] = a;
    return out;
  }, [agents]);
  const activeProject = activeProjectId ? projects[activeProjectId] : null;
  const focusLayoutSlot = useStore((s) => s.focusLayoutSlot);
  const closeLayoutSlot = useStore((s) => s.closeLayoutSlot);
  const upsertSession = useStore((s) => s.upsertSession);

  // Inline pane-title rename. `editingId` is the session whose header title is
  // being edited (at most one); `editingText` is the working draft. Double-
  // click a title to start; Enter / blur commits, Escape cancels.
  const [editingId, setEditingId] = useState<string | null>(null);
  const [editingText, setEditingText] = useState("");

  const { visibleIds, focusSlot, mode } = layout;

  // Picker takes over when nothing is visible OR the user is down to a
  // single pane whose process has exited — they probably want to start
  // a fresh one rather than stare at the [process exited] banner.
  const focusedId = visibleIds[focusSlot] ?? null;
  const focusedSession = focusedId ? sessions[focusedId] : null;
  const onlyDeadSlot =
    visibleIds.length === 1 &&
    !!focusedSession &&
    focusedSession.status.type !== "Running";
  const showPicker = visibleIds.length === 0 || onlyDeadSlot;

  // Holds Terminal instances not currently mounted in a slot cell. Hidden
  // (display:none) so cursor blinks etc. don't burn CPU off-screen.
  const poolRef = useRef<HTMLDivElement | null>(null);
  // Grid container — used to translate pointer px into split percentages
  // during a drag.
  const gridRef = useRef<HTMLDivElement | null>(null);
  // session id → cell body element. Keyed by id (not slot) so two cells
  // swapping slots during a layout change don't race each other's ref
  // callbacks into deleting a still-live entry.
  const cellBodyRefs = useRef<Map<string, HTMLDivElement>>(new Map());
  const terminalsRef = useRef<Map<string, TermInstance>>(new Map());

  // User-drag split state. In-memory only — refreshing or restarting the
  // app reverts to equal panes. Keyed by `${mode}-${count}` so each layout
  // remembers its own drags independently.
  const [splitsMap, setSplitsMap] = useState<SplitsMap>({});
  const count = visibleIds.length;
  const dims = useMemo(() => gridDims(mode, count), [mode, count]);
  const splits = useMemo<LayoutSplits>(() => {
    return splitsMap[splitsKey(mode, count)] ?? defaultSplits(mode, count);
  }, [splitsMap, mode, count]);
  const gridTemplateColumns = useMemo(
    () => splitsToTemplate(splits.cols, dims.cols),
    [splits.cols, dims.cols],
  );
  const gridTemplateRows = useMemo(
    () => splitsToTemplate(splits.rows, dims.rows),
    [splits.rows, dims.rows],
  );
  const gutters = useMemo(() => gutterDefs(mode, splits), [mode, splits]);

  // Pointer-drag handler for a gutter. Captures `mode`/`count` at start so
  // a stale move event (after layout swap) writes to the right map entry.
  const startGutterDrag = useCallback(
    (e: React.PointerEvent, axis: "col" | "row", splitIdx: number) => {
      e.preventDefault();
      const grid = gridRef.current;
      if (!grid) return;
      const rect = grid.getBoundingClientRect();
      const key = splitsKey(mode, count);
      const baseline = splitsMap[key] ?? defaultSplits(mode, count);
      const arr = axis === "col" ? baseline.cols : baseline.rows;
      // Clamp between neighbouring splits (or 0/100) minus the min pane size.
      const lower = (arr[splitIdx - 1] ?? 0) + MIN_PANE_PCT;
      const upper = (arr[splitIdx + 1] ?? 100) - MIN_PANE_PCT;

      const onMove = (ev: PointerEvent) => {
        const pos =
          axis === "col"
            ? ((ev.clientX - rect.left) / rect.width) * 100
            : ((ev.clientY - rect.top) / rect.height) * 100;
        const clamped = Math.max(lower, Math.min(upper, pos));
        setSplitsMap((prev) => {
          const cur = prev[key] ?? defaultSplits(mode, count);
          const nextArr = (axis === "col" ? cur.cols : cur.rows).slice();
          nextArr[splitIdx] = clamped;
          return {
            ...prev,
            [key]:
              axis === "col"
                ? { ...cur, cols: nextArr }
                : { ...cur, rows: nextArr },
          };
        });
      };
      const onUp = () => {
        window.removeEventListener("pointermove", onMove);
        window.removeEventListener("pointerup", onUp);
        document.body.style.cursor = "";
        document.body.style.userSelect = "";
      };
      window.addEventListener("pointermove", onMove);
      window.addEventListener("pointerup", onUp);
      // Lock the cursor + suppress text selection across the whole window
      // so the drag survives the pointer briefly leaving the gutter strip.
      document.body.style.cursor = axis === "col" ? "col-resize" : "row-resize";
      document.body.style.userSelect = "none";
    },
    [mode, count, splitsMap],
  );
  // Per-session byte buffer used **only during the lazy-create init window**:
  // the lazy-create flow inserts an empty array when it begins, the
  // PtyOutput listener pushes any live bytes that arrive between
  // `createTerminal` and `readPtyBacklog` resolving, and the resolve
  // handler drains it. Presence of an entry doubles as the "initializing"
  // marker — used by the listener to keep live bytes from getting written
  // ahead of the backlog snapshot.
  //
  // Critically, sessions that don't have a Terminal at all do NOT get a
  // pendingRef entry. Their PtyOutput is dropped — the backend's rolling
  // backlog will replay it when (and only if) the user actually opens them.
  // Without this we'd buffer indefinitely for every accumulated history
  // session, recreating the memory bloat that motivated this refactor.
  const pendingRef = useRef<Map<string, Uint8Array[]>>(new Map());

  // Single global subscriber. Routes per-session PTY events to the matching
  // Terminal, or buffers them if the Terminal hasn't been created yet.
  useEffect(() => {
    let unlisten: (() => void) | undefined;
    let cancelled = false;
    listenSessionEvents((event) => {
      // React 19 StrictMode runs this effect twice in dev; the async
      // `listenSessionEvents` can leave the first mount's listener briefly
      // registered with Tauri after the second mount adds its own. Without
      // this guard, both listeners would write the same PtyOutput into the
      // shared xterm → every keystroke doubles. See ManualTerminal for the
      // same fix.
      if (cancelled) return;
      const k = event.kind;
      let bytes: Uint8Array | null = null;
      if (k.type === "PtyOutput") {
        bytes = base64ToBytes(k.data);
      } else if (k.type === "PtyExit") {
        const tag =
          k.code === null
            ? "[process killed]"
            : `[process exited with code ${k.code}]`;
        const restartHint =
          "Session ended. Use Restart in the session list to launch it again.";
        bytes = new TextEncoder().encode(
          `\r\n\x1b[33m${tag}\x1b[0m\r\n\x1b[90m${restartHint}\x1b[0m\r\n`,
        );
      }
      if (!bytes) return;

      const id = event.session_id;
      const inst = terminalsRef.current.get(id);
      if (!inst) {
        // No Terminal yet — session hasn't been opened in this window.
        // Drop and rely on `readPtyBacklog` to replay when the user
        // eventually attaches. Buffering here would mean unbounded
        // memory for every accumulated history session.
        return;
      }
      const initBuf = pendingRef.current.get(id);
      if (initBuf) {
        // Lazy-create is mid-flight: backlog hasn't returned yet, so
        // queue these live bytes to be drained in-order *after* the
        // backlog writes (see the readPtyBacklog handler below).
        initBuf.push(bytes);
      } else {
        inst.term.write(bytes);
      }
    }).then((u) => {
      if (cancelled) u();
      else unlisten = u;
    });
    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, []);

  // Dispose Terminals whose session was removed from the store. Creation
  // is no longer mirrored from the sessions map — Terminals are now built
  // lazily in the reparent effect, the first time a session actually
  // becomes visible. That cuts the per-window memory floor from
  // O(historical sessions × xterm overhead) down to O(currently or
  // previously opened sessions). Combined with the lastThemeId stamp,
  // global ops like theme switching are O(visible) instead of O(all).
  useEffect(() => {
    const known = terminalsRef.current;
    const pending = pendingRef.current;
    for (const id of Array.from(known.keys())) {
      if (!sessions[id]) {
        known.get(id)!.cleanup();
        known.delete(id);
        pending.delete(id);
      }
    }
  }, [sessions]);

  // Reparent terminal containers: visible ones into their slot cell, hidden
  // ones into the pool. useLayoutEffect to avoid a frame of mis-placed
  // terminals when the user changes layout mode or closes a pane.
  useLayoutEffect(() => {
    const pool = poolRef.current;
    if (!pool) return;
    const known = terminalsRef.current;

    const currentThemeId = useStore.getState().theme;
    visibleIds.forEach((id) => {
      const cell = cellBodyRefs.current.get(id);
      if (!cell) return;

      let inst = known.get(id);
      let justCreated = false;
      if (!inst) {
        // Lazy creation. Mounting straight into the visible cell means
        // we never park a brand-new Terminal in the pool — the most
        // common case (open a session, look at it, close it) only ever
        // touches one xterm instance.
        //
        // pendingRef gets a sentinel array first: the global PtyOutput
        // listener checks for it and queues live bytes here instead of
        // writing them ahead of the backlog snapshot we're about to
        // fetch. The readPtyBacklog handler drains and deletes the
        // entry to flip the listener back into the direct-write path.
        pendingRef.current.set(id, []);
        inst = createTerminal(id, cell);
        inst.term.options.fontSize = useStore.getState().fontSizes.terminal;
        known.set(id, inst);
        justCreated = true;

        const createdInst = inst;
        readPtyBacklog(id)
          .then((b64) => {
            if (terminalsRef.current.get(id) !== createdInst) return;
            if (b64) createdInst.term.write(base64ToBytes(b64));
            const buf = pendingRef.current.get(id);
            if (buf) for (const chunk of buf) createdInst.term.write(chunk);
            pendingRef.current.delete(id);
          })
          .catch(() => {
            if (terminalsRef.current.get(id) !== createdInst) return;
            const buf = pendingRef.current.get(id);
            if (buf) for (const chunk of buf) createdInst.term.write(chunk);
            pendingRef.current.delete(id);
          });
      }

      const moved = inst.container.parentElement !== cell;
      if (moved && !justCreated) cell.appendChild(inst.container);
      inst.container.style.display = "block";
      // Lazy theme catch-up. While this terminal was hidden in the pool
      // the user may have switched themes — we deliberately skipped the
      // pool-wide reskin to keep theme swaps snappy regardless of how
      // many sessions accumulated. The single redraw here is cheap (one
      // term, ~30ms) and happens exactly when the user actually starts
      // looking at it. `justCreated` terms already booted with the
      // current theme via createTerminal.
      if (!justCreated && inst.lastThemeId !== currentThemeId) {
        const xterm = getTheme(currentThemeId).xterm;
        inst.term.options.theme = xterm;
        inst.container.style.backgroundColor = xterm.background ?? "";
        inst.lastThemeId = currentThemeId;
      }
      if (moved || justCreated) {
        // Fit immediately on (re)attach / create so the renderer doesn't
        // paint one frame at stale dimensions. The cell ResizeObserver
        // below covers subsequent size changes.
        try {
          inst.fit.fit();
        } catch {
          return;
        }
        const { cols, rows } = inst.term;
        void resizePty({ session_id: id, cols, rows }).catch(() => {});
      }
    });

    for (const [id, inst] of known) {
      if (!visibleIds.includes(id)) {
        if (inst.container.parentElement !== pool) {
          pool.appendChild(inst.container);
        }
        inst.container.style.display = "none";
      }
    }
  }, [visibleIds, mode]);

  // Per-cell ResizeObserver: fit + push new geometry to the PTY whenever
  // the cell's size changes (window resize, layout switch, column drag).
  useEffect(() => {
    const known = terminalsRef.current;
    const observers: ResizeObserver[] = [];
    visibleIds.forEach((id) => {
      const cell = cellBodyRefs.current.get(id);
      const inst = known.get(id);
      if (!cell || !inst) return;
      const observer = new ResizeObserver(() => {
        try {
          inst.fit.fit();
        } catch {
          // FitAddon throws if the cell has zero size (mid-layout swap).
          // The next observer fire will catch up once layout settles.
          return;
        }
        const { cols, rows } = inst.term;
        void resizePty({ session_id: id, cols, rows }).catch(() => {});
      });
      observer.observe(cell);
      observers.push(observer);
    });
    return () => {
      observers.forEach((o) => o.disconnect());
    };
  }, [visibleIds, mode]);

  // Push keyboard focus into the focused slot's xterm whenever it changes.
  // Suppressed while a title is being edited so the rename input keeps the
  // caret; clearing `editingId` re-runs this and hands focus back to the term.
  useEffect(() => {
    if (editingId) return;
    if (!focusedId) return;
    const inst = terminalsRef.current.get(focusedId);
    if (!inst) return;
    const raf = requestAnimationFrame(() => inst.term.focus());
    return () => cancelAnimationFrame(raf);
  }, [focusedId, editingId]);

  // Persist a renamed pane title. No-op when the trimmed draft matches the
  // current display title (e.g. the user opened the editor but didn't change
  // anything). An empty title is allowed — it clears the manual name so the
  // CLI's live OSC title (or "New session") takes over again.
  const commitRename = () => {
    if (editingId === null) return;
    const id = editingId;
    const next = editingText.trim();
    setEditingId(null);
    const session = sessions[id];
    if (!session) return;
    if (next === displaySessionTitle(session, liveTitles)) return;
    renameSession({ session_id: id, title: next })
      .then((view) => upsertSession(view))
      .catch((err) => toast.danger(`Rename failed: ${err}`));
  };

  // Apply terminal font size to every live xterm whenever the setting
  // changes. Only visible cells re-fit (hidden ones have zero size and
  // would throw); the next re-attach in the pool effect catches them.
  // This effect runs on Settings save, not on every keystroke, so the
  // fit + PTY resize cost is paid once and doesn't degrade typing.
  useEffect(() => {
    const known = terminalsRef.current;
    known.forEach((inst, id) => {
      if (inst.term.options.fontSize === terminalFontSize) return;
      inst.term.options.fontSize = terminalFontSize;
      if (!visibleIds.includes(id)) return;
      try {
        inst.fit.fit();
      } catch {
        return;
      }
      const { cols, rows } = inst.term;
      void resizePty({ session_id: id, cols, rows }).catch(() => {});
    });
  }, [terminalFontSize, visibleIds]);

  // Re-skin every live terminal when the theme changes. The subscription
  // intentionally goes through the store's vanilla `subscribe()` instead
  // of `useStore((s) => s.theme)` — a selector here would force this
  // whole component to re-render on every theme swap (and TerminalPane
  // owns a large JSX tree), and the only thing the React render does
  // with the theme is feed it into this effect. Going around React keeps
  // the swap to a single xterm refresh per pane with zero reconciliation.
  //
  // Strategy when the theme moves:
  //   - `rAF` the visible-pane skin so the chrome can paint first.
  //   - `requestIdleCallback` (fallback `setTimeout`) the hidden-pool
  //     terminals — they're off-screen, no rush.
  const visibleIdsRef = useRef<string[]>(visibleIds);
  useEffect(() => {
    visibleIdsRef.current = visibleIds;
  }, [visibleIds]);
  useEffect(() => {
    // Skin ONLY the visible terms on theme change. Hidden pool members
    // skip the work entirely — the reparent layout effect picks up stale
    // ones on attach via `lastThemeId`. This is the difference between a
    // ~zero-cost swap (the typical case: 0–4 visible terms) and a 4-second
    // freeze (the user had 122 accumulated sessions in the pool — even
    // `setTimeout(0)` ran them all back-to-back on the main thread,
    // because WKWebView doesn't ship `requestIdleCallback` and the fallback
    // path was as blocking as a direct loop).
    let pending: number | null = null;
    return useStore.subscribe((state, prev) => {
      if (state.theme === prev.theme) return;
      const themeId = state.theme;
      const theme = getTheme(themeId).xterm;
      const visible = new Set(visibleIdsRef.current);
      if (pending !== null) cancelAnimationFrame(pending);
      pending = requestAnimationFrame(() => {
        pending = null;
        for (const [id, inst] of terminalsRef.current) {
          if (!visible.has(id)) continue;
          inst.term.options.theme = theme;
          inst.container.style.backgroundColor = theme.background ?? "";
          inst.lastThemeId = themeId;
        }
      });
    });
  }, []);

  // Dispose all terminals on unmount.
  useEffect(() => {
    const terminals = terminalsRef.current;
    const pending = pendingRef.current;
    return () => {
      for (const inst of terminals.values()) inst.cleanup();
      terminals.clear();
      pending.clear();
    };
  }, []);

  return (
    <div className={"terminal-pane" + (showPicker ? " picker-active" : "")}>
      {/* Hidden pool: holds Terminal containers that aren't currently in a
          slot. Always present (even when the picker is up) so re-entering
          from the picker can recover any background sessions' scrollback. */}
      <div className="terminal-pool" ref={poolRef} aria-hidden />

      {!showPicker && (
        <div
          ref={gridRef}
          className={
            `terminal-grid layout-${mode} count-${visibleIds.length}`
          }
          // Inline columns/rows override the CSS defaults so user drags
          // stick; grid-template-areas (from CSS) still owns slot placement.
          style={{ gridTemplateColumns, gridTemplateRows }}
        >
          {visibleIds.map((id, slot) => {
            const session = sessions[id];
            const title = session
              ? displaySessionTitle(session, liveTitles)
              : "(loading…)";
            // 4-state status light: folds the PTY lifecycle (running / done /
            // error) together with the agent's turn signal (waiting). Null
            // only while the session row hasn't loaded yet.
            const light = session
              ? sessionLight(session.status, activityBySession[id])
              : null;
            const focused = slot === focusSlot;
            return (
              <div
                key={id}
                className={
                  "pane-cell" + (focused ? " focused" : "")
                }
                style={{ gridArea: `s${slot}` }}
                onMouseDownCapture={(e) => {
                  // Header buttons handle their own clicks; bare-cell
                  // mousedown promotes this slot to focus before xterm
                  // grabs the keyboard.
                  const target = e.target as HTMLElement;
                  if (target.closest("button")) return;
                  if (!focused) focusLayoutSlot(slot);
                }}
              >
                <header className="pane-header">
                  <span
                    className={`pane-agent agent-${session?.agent_profile ?? ""}`}
                    aria-hidden
                  >
                    <AgentIcon
                      icon={
                        session
                          ? agentByProfileId[session.agent_profile]?.icon
                          : undefined
                      }
                      variant={
                        session
                          ? agentByProfileId[session.agent_profile]?.icon_variant
                          : undefined
                      }
                      fallbackChar={
                        session
                          ? agentByProfileId[session.agent_profile]
                              ?.display_name ?? session.agent_profile
                          : undefined
                      }
                      size={14}
                    />
                  </span>
                  {editingId === id ? (
                    <input
                      className="pane-title-input"
                      value={editingText}
                      autoFocus
                      onChange={(e) => setEditingText(e.target.value)}
                      onBlur={commitRename}
                      onMouseDown={(e) => e.stopPropagation()}
                      onKeyDown={(e) => {
                        // Keep keystrokes out of the global hotkey handler
                        // (and the underlying xterm) while editing.
                        e.stopPropagation();
                        if (e.key === "Enter") commitRename();
                        else if (e.key === "Escape") setEditingId(null);
                      }}
                      aria-label="Rename session"
                    />
                  ) : (
                    <span
                      className="pane-title"
                      title={`${title} — double-click to rename`}
                      onDoubleClick={() => {
                        if (!session) return;
                        setEditingId(id);
                        setEditingText(title);
                      }}
                    >
                      {title}
                    </span>
                  )}
                  {light && (
                    <span
                      className={`pane-status-dot light-${light}`}
                      title={SESSION_LIGHT_LABEL[light]}
                      aria-label={SESSION_LIGHT_LABEL[light]}
                    />
                  )}
                  <button
                    type="button"
                    className="pane-close"
                    onClick={(e) => {
                      e.stopPropagation();
                      closeLayoutSlot(slot);
                    }}
                    aria-label="Close pane"
                    title="Close pane (session keeps running)"
                  >
                    ×
                  </button>
                </header>
                <div
                  className="pane-body"
                  ref={(el) => {
                    if (el) cellBodyRefs.current.set(id, el);
                    else cellBodyRefs.current.delete(id);
                  }}
                />
              </div>
            );
          })}
          {gutters.map((g, i) => {
            const splitPct =
              g.axis === "col"
                ? splits.cols[g.splitIdx]
                : splits.rows[g.splitIdx];
            const startPct = g.startPct ?? 0;
            const endPct = g.endPct ?? 100;
            const style: React.CSSProperties =
              g.axis === "col"
                ? {
                    left: `${splitPct}%`,
                    top: `${startPct}%`,
                    height: `${endPct - startPct}%`,
                  }
                : {
                    top: `${splitPct}%`,
                    left: `${startPct}%`,
                    width: `${endPct - startPct}%`,
                  };
            return (
              <div
                key={`gutter-${g.axis}-${g.splitIdx}-${i}`}
                className={`gutter gutter-${g.axis}`}
                style={style}
                onPointerDown={(e) => startGutterDrag(e, g.axis, g.splitIdx)}
                role="separator"
                aria-orientation={g.axis === "col" ? "vertical" : "horizontal"}
              />
            );
          })}
        </div>
      )}

      {showPicker && (
        <div className="terminal-empty">
          {!activeProject ? (
            <span>Select a project from the top bar.</span>
          ) : (
            <NewSessionPicker project={activeProject} />
          )}
        </div>
      )}
    </div>
  );
}

function createTerminal(sessionId: string, parent: HTMLElement): TermInstance {
  // Snapshot the current theme so first paint is correct; the live re-skin
  // pass below handles subsequent swaps. Reading from the store imperatively
  // here (rather than threading the theme through createTerminal's call sites)
  // keeps the existing TermInstance creation contract small.
  const themeId = useStore.getState().theme;
  const theme = getTheme(themeId).xterm;
  const term = new Terminal({ ...TERMINAL_BASE_OPTIONS, theme });
  const fit = new FitAddon();
  const search = new SearchAddon();
  let lastSearch = "";
  term.loadAddon(fit);
  term.loadAddon(search);
  // WebLinksAddon's default `window.open` is a no-op in Tauri's WKWebView,
  // so route clicks through a backend command that uses the OS opener.
  term.loadAddon(
    new WebLinksAddon((_event, uri) => {
      void openUrl(uri).catch(() => {});
    }),
  );
  // Cmd-click on file-path-shaped substrings → open in right-pane editor.
  // Resolve the project id from the session at click time so reassigning a
  // session to a different project (rare but possible) still routes to the
  // correct repo.
  term.registerLinkProvider(
    createFileLinkProvider(term, (candidate, line, column) => {
      const projectId =
        useStore.getState().sessions[sessionId]?.project_id;
      if (!projectId) return;
      void activateFilePath(projectId, candidate, line, column).catch(
        () => {},
      );
    }),
  );
  // Activate Unicode 11 width tables so emoji / Nerd-Font PUA glyphs match
  // what zsh/starship and modern shells assume — without this, xterm treats
  // them as 1 cell while the shell treats them as 2, and cursor columns drift
  // until the visible prompt and shell's internal cursor disagree.
  term.loadAddon(new Unicode11Addon());
  term.unicode.activeVersion = "11";

  const container = document.createElement("div");
  container.className = "terminal-container";
  // Paint the wrapper with the active terminal background so the sub-row
  // remainder at the bottom of a pane (height isn't an exact multiple of the
  // cell height) matches the terminal instead of leaking xterm's hard-coded
  // `#000` viewport background. Kept in sync on every theme change below.
  container.style.backgroundColor = theme.background ?? "";
  // Hidden until reparented into a slot cell.
  container.style.display = "none";
  parent.appendChild(container);
  term.open(container);
  term.attachCustomKeyEventHandler((event) => {
    if (handleSearchShortcut(event, term, search, lastSearch, (next) => {
      lastSearch = next;
    })) {
      return false;
    }
    const macData = macCommandShortcutData(event);
    if (macData) {
      event.preventDefault();
      void writePty({
        session_id: sessionId,
        data: utf8ToBase64(macData),
      }).catch(() => {});
      return false;
    }
    // IME composition: hand the event back to the browser/IME completely
    // so xterm.js doesn't preventDefault and break the composition chain.
    if (event.isComposing) return false;
    // Printable single-char keystrokes (no Cmd/Ctrl/Alt): route through the
    // textarea's `input` event instead of xterm.js's keydown writer. This is
    // the only way macOS Chinese IME punctuation auto-replace (e.g. `?` →
    // `？`) reaches the PTY — xterm's keydown path would write the raw `?`
    // and preventDefault, killing the IME's replacement before it commits.
    // The attached input bridge below picks up whatever character actually
    // lands in the textarea (raw or IME-replaced) and writes it to the PTY.
    if (isPrintableCharEvent(event)) return false;
    return true;
  });

  // Bridge owns term.onData (with IME-aware dedup) plus textarea composition
  // listeners. We don't register our own term.onData separately — that would
  // race the bridge's dedup wrapper for the same callback queue.
  const imeBridgeDispose = attachImeInputBridge(term, () => sessionId);

  const binaryDisposable = term.onBinary((data) => {
    // `data` is a string where each char code is one raw byte (mouse
    // tracking, etc.). Convert directly without UTF-8 re-encoding.
    void writePty({
      session_id: sessionId,
      data: latin1StringToBase64(data),
    }).catch(() => {});
  });

  return {
    term,
    fit,
    container,
    lastThemeId: themeId,
    cleanup: () => {
      imeBridgeDispose();
      binaryDisposable.dispose();
      term.dispose();
      container.remove();
    },
  };
}

function base64ToBytes(b64: string): Uint8Array {
  const binary = atob(b64);
  const len = binary.length;
  const bytes = new Uint8Array(len);
  for (let i = 0; i < len; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function utf8ToBase64(s: string): string {
  const bytes = new TextEncoder().encode(s);
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}

function latin1StringToBase64(s: string): string {
  let bin = "";
  for (let i = 0; i < s.length; i++) bin += String.fromCharCode(s.charCodeAt(i) & 0xff);
  return btoa(bin);
}

function macCommandShortcutData(event: KeyboardEvent): string | null {
  if (
    event.type !== "keydown" ||
    !event.metaKey ||
    event.ctrlKey ||
    event.altKey ||
    event.shiftKey
  ) {
    return null;
  }
  if (event.key === "ArrowLeft") return "\x01";
  if (event.key === "ArrowRight") return "\x05";
  if (event.key === "Backspace" || event.key === "Delete") {
    return "\x01\x0b";
  }
  return null;
}

function handleSearchShortcut(
  event: KeyboardEvent,
  term: Terminal,
  search: SearchAddon,
  lastSearch: string,
  setLastSearch: (next: string) => void,
): boolean {
  if (
    event.type !== "keydown" ||
    !event.metaKey ||
    event.ctrlKey ||
    event.altKey
  ) {
    return false;
  }
  const key = event.key.toLowerCase();
  if (key === "f" && !event.shiftKey) {
    event.preventDefault();
    const selected = term.getSelection().trim().split(/\r?\n/)[0] ?? "";
    const query = window.prompt("Search terminal", selected || lastSearch);
    if (query == null) return true;
    setLastSearch(query);
    if (query) {
      search.findNext(query, {
        decorations: SEARCH_DECORATIONS,
        incremental: true,
      });
    } else {
      search.clearDecorations();
    }
    return true;
  }
  if (key === "g" && lastSearch) {
    event.preventDefault();
    const options = { decorations: SEARCH_DECORATIONS };
    if (event.shiftKey) search.findPrevious(lastSearch, options);
    else search.findNext(lastSearch, options);
    return true;
  }
  return false;
}

const SEARCH_DECORATIONS = {
  matchBackground: "#4b352a",
  matchBorder: "#d6a95c",
  matchOverviewRuler: "#d6a95c",
  activeMatchBackground: "#d97757",
  activeMatchBorder: "#fff9ef",
  activeMatchColorOverviewRuler: "#d97757",
};
