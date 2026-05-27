// Second terminal pane — runs the user's $SHELL in the active project's cwd,
// independent of the main terminal's session switching.
//
// Lifecycle:
//   • Mount → spawn_pty_raw(cwd=project.repo_path, command=""[default SHELL])
//   • Receive PtyOutput / PtyExit for own pty_id, route into xterm
//   • Window/container resize → resizePty
//   • Unmount or cwd change → kill_pty_raw + dispose xterm
//
// The component is meant to stay mounted across right-tab switches; only an
// `activeProject` change (or an actual unmount) tears the PTY down.

import { useEffect, useRef, useState } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { SearchAddon } from "@xterm/addon-search";
import { Unicode11Addon } from "@xterm/addon-unicode11";
import { WebLinksAddon } from "@xterm/addon-web-links";
import "@xterm/xterm/css/xterm.css";
import {
  killPtyRaw,
  listenSessionEvents,
  resizePty,
  spawnPtyRaw,
  writePty,
} from "../lib/ipc";

const TERMINAL_OPTIONS = {
  fontFamily:
    'ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace',
  fontSize: 13,
  lineHeight: 1.2,
  cursorBlink: true,
  scrollback: 5000,
  // Required for the Unicode11Addon below — `term.unicode.activeVersion` is
  // marked proposed API in xterm.js.
  allowProposedApi: true,
  theme: {
    background: "#13120f",
    foreground: "#f0eee6",
    cursor: "#d97757",
    cursorAccent: "#13120f",
    selectionBackground: "rgba(217, 119, 87, 0.28)",
  },
} as const;

export function ManualTerminal({
  cwd,
  visible,
}: {
  cwd: string;
  visible: boolean;
}) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const termRef = useRef<Terminal | null>(null);
  const fitRef = useRef<FitAddon | null>(null);
  const ptyIdRef = useRef<string | null>(null);
  const visibleRef = useRef(visible);
  // Tracks whether we've already pushed a "shell is live" resize_pty after
  // observing the first byte of PTY output. See the listen effect for why
  // that's necessary even when spawn already had the right geometry.
  const firstOutputSeenRef = useRef(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    visibleRef.current = visible;
  }, [visible]);

  // Boot the xterm Terminal exactly once per mount/cwd. The cwd dep makes
  // React tear down + rebuild when the active project changes.
  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    const term = new Terminal(TERMINAL_OPTIONS);
    const fit = new FitAddon();
    const search = new SearchAddon();
    let lastSearch = "";
    term.loadAddon(fit);
    term.loadAddon(search);
    term.loadAddon(new WebLinksAddon());
    // Default Unicode tables in xterm.js treat many emoji and Nerd-Font PUA
    // glyphs as 1 cell, while modern shells (zsh/starship + wcwidth) treat
    // them as 2. The mismatch slowly desynchronises cursor columns between
    // shell and xterm, surfacing as prompts that "disappear", misaligned
    // wraps, and overwritten lines. Activating the Unicode 11 addon aligns
    // xterm with what zsh/starship assume on macOS-style terminals.
    term.loadAddon(new Unicode11Addon());
    term.unicode.activeVersion = "11";
    term.open(container);
    termRef.current = term;
    fitRef.current = fit;

    term.attachCustomKeyEventHandler((event) => {
      if (handleSearchShortcut(event, term, search, lastSearch, (next) => {
        lastSearch = next;
      })) {
        return false;
      }
      const data = macCommandShortcutData(event);
      if (!data) return true;
      const id = ptyIdRef.current;
      if (!id) return false;
      event.preventDefault();
      void writePty({ session_id: id, data: utf8ToBase64(data) }).catch(() => {});
      return false;
    });

    const dataDisposable = term.onData((data) => {
      const id = ptyIdRef.current;
      if (!id) return;
      void writePty({ session_id: id, data: utf8ToBase64(data) }).catch(() => {});
    });
    const binaryDisposable = term.onBinary((data) => {
      const id = ptyIdRef.current;
      if (!id) return;
      void writePty({
        session_id: id,
        data: latin1StringToBase64(data),
      }).catch(() => {});
    });

    let cancelled = false;
    let localPtyId: string | null = null;
    firstOutputSeenRef.current = false;
    setError(null);

    // Fit BEFORE spawning so the backend opens the PTY at the real terminal
    // size. If we spawned first and then resize_pty'd, SIGWINCH would race
    // shell startup: the signal can land before the shell installs its
    // handler (default action: ignore), leaving the shell stuck at the
    // backend's hardcoded INITIAL_COLS/ROWS while xterm displays a different
    // width — visible as misaligned wraps and missing prompts.
    // Reference: hermes-hq/hermes-ide#113.
    //
    // We need cell metrics populated before fitting (FitAddon.fit() bails
    // silently when cell.width/height === 0). The renderer measures cells
    // on its first render, scheduled by term.open(). One rAF is usually
    // enough, but we poll for up to ~10 frames to be safe — and fall back
    // to xterm's defaults afterwards so we never block spawn indefinitely.
    const MAX_FIT_ATTEMPTS = 10;
    let attempts = 0;
    function fitThenSpawn() {
      if (cancelled) return;
      const cell = readCellDims(term);
      if ((!cell || cell.width === 0 || cell.height === 0) && attempts < MAX_FIT_ATTEMPTS) {
        attempts++;
        requestAnimationFrame(fitThenSpawn);
        return;
      }
      try {
        fit.fit();
      } catch {
        // Cell dims unmeasurable — proceed with xterm defaults; the
        // ResizeObserver below will catch up on the next layout tick.
      }
      // FitAddon can return NaN cols/rows (xterm.js#4338). Guard before
      // handing to the backend — otherwise the PTY opens with junk geometry.
      const cols = sanitizeDim(term.cols, 2);
      const rows = sanitizeDim(term.rows, 1);
      spawnPtyRaw({ cwd, command: "", args: [], cols, rows })
        .then((id) => {
          if (cancelled) {
            // Component already torn down — kill the orphan.
            void killPtyRaw(id).catch(() => {});
            return;
          }
          ptyIdRef.current = id;
          localPtyId = id;
        })
        .catch((err) => {
          if (!cancelled) setError(String(err));
        });
    }
    requestAnimationFrame(fitThenSpawn);

    return () => {
      cancelled = true;
      const id = localPtyId ?? ptyIdRef.current;
      ptyIdRef.current = null;
      dataDisposable.dispose();
      binaryDisposable.dispose();
      term.dispose();
      termRef.current = null;
      fitRef.current = null;
      if (id) void killPtyRaw(id).catch(() => {});
    };
  }, [cwd]);

  // Route PTY events strictly by exact id match. Anything arriving before our
  // spawn returns is dropped — we don't try to buffer because a previous mount
  // (rapid project switch) may still have its listener attached and would
  // otherwise siphon our events into its own buffer. Losing a few startup
  // bytes from a shell is harmless; the prompt repaints on first keystroke.
  //
  // The `cancelled` check inside the handler is load-bearing: React 19 +
  // StrictMode runs this effect twice in dev (mount → unmount → mount).
  // `listenSessionEvents` is async, so the first listener can still be
  // registered with Tauri when the second effect kicks in — both listeners
  // would then write the same PtyOutput into the live xterm, doubling every
  // keystroke. Gating the handler on the captured `cancelled` makes the
  // stale listener a no-op until its unsubscribe promise resolves.
  useEffect(() => {
    let unlisten: (() => void) | undefined;
    let cancelled = false;
    listenSessionEvents((event) => {
      if (cancelled) return;
      const id = ptyIdRef.current;
      if (id == null || event.session_id !== id) return;
      const k = event.kind;
      let bytes: Uint8Array | null = null;
      if (k.type === "PtyOutput") {
        bytes = base64ToBytes(k.data);
        // Safety-net resize on the first byte we hear from the shell. By
        // the time the shell produces output, its SIGWINCH handler is up,
        // so any resize_pty we issued earlier (during spawn race) that the
        // shell might have missed is re-applied here. Idempotent if geometry
        // already matches.
        if (!firstOutputSeenRef.current) {
          firstOutputSeenRef.current = true;
          const term = termRef.current;
          if (term) {
            const cols = sanitizeDim(term.cols, 2);
            const rows = sanitizeDim(term.rows, 1);
            if (cols !== undefined && rows !== undefined) {
              void resizePty({ session_id: id, cols, rows }).catch(() => {});
            }
          }
        }
      } else if (k.type === "PtyExit") {
        const tag =
          k.code === null
            ? "[shell killed]"
            : `[shell exited with code ${k.code}]`;
        bytes = new TextEncoder().encode(`\r\n\x1b[33m${tag}\x1b[0m\r\n`);
      }
      if (!bytes) return;
      const term = termRef.current;
      if (term) term.write(bytes);
    }).then((u) => {
      if (cancelled) u();
      else unlisten = u;
    });
    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, []);

  // Re-fit on container resize (covers window resize AND column drags from
  // react-resizable-panels, which mutate the Panel's DOM width without
  // firing window.resize) and on visibility flips (hidden → visible).
  useEffect(() => {
    function refit(focus = false) {
      const fit = fitRef.current;
      const term = termRef.current;
      const id = ptyIdRef.current;
      if (!fit || !term) return;
      try {
        fit.fit();
      } catch {
        return;
      }
      if (id) {
        const cols = sanitizeDim(term.cols, 2);
        const rows = sanitizeDim(term.rows, 1);
        if (cols !== undefined && rows !== undefined) {
          void resizePty({ session_id: id, cols, rows }).catch(() => {});
        }
      }
      if (focus) term.focus();
    }
    const container = containerRef.current;
    if (!container) return;
    const observer = new ResizeObserver(() => refit());
    observer.observe(container);
    if (visible) requestAnimationFrame(() => refit(true));
    return () => observer.disconnect();
  }, [visible]);

  useEffect(() => {
    function focusTerminal() {
      if (!visibleRef.current) return;
      requestAnimationFrame(() => {
        requestAnimationFrame(() => {
          termRef.current?.focus();
        });
      });
    }
    window.addEventListener("ycode:focus-manual-terminal", focusTerminal);
    return () => {
      window.removeEventListener("ycode:focus-manual-terminal", focusTerminal);
    };
  }, []);

  return (
    <div className="manual-terminal">
      {error && <div className="form-error" style={{ margin: 8 }}>{error}</div>}
      <div className="manual-terminal-body" ref={containerRef} />
    </div>
  );
}

// FitAddon can return NaN cols/rows (xterm.js#4338). `term.cols` would then
// be NaN too; a `< 10` comparison silently passes it through. Return undefined
// in that case so callers can fall back to backend defaults rather than
// shipping junk geometry over IPC.
function sanitizeDim(value: number, min: number): number | undefined {
  if (!Number.isFinite(value)) return undefined;
  const floored = Math.floor(value);
  if (floored < min) return undefined;
  return floored;
}

// Peek at xterm's internal render service to detect whether the renderer has
// measured cell metrics yet. FitAddon.proposeDimensions() bails out silently
// when these are 0, so we poll on this before fitting.
function readCellDims(
  term: Terminal,
): { width: number; height: number } | undefined {
  return (
    term as unknown as {
      _core?: {
        _renderService?: {
          dimensions?: { css?: { cell?: { width: number; height: number } } };
        };
      };
    }
  )._core?._renderService?.dimensions?.css?.cell;
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
