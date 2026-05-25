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
  const [error, setError] = useState<string | null>(null);

  // Boot the xterm Terminal exactly once per mount/cwd. The cwd dep makes
  // React tear down + rebuild when the active project changes.
  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    const term = new Terminal(TERMINAL_OPTIONS);
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(container);
    termRef.current = term;
    fitRef.current = fit;

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
    setError(null);

    spawnPtyRaw({ cwd, command: "", args: [] })
      .then((id) => {
        if (cancelled) {
          // Component already torn down — kill the orphan.
          void killPtyRaw(id).catch(() => {});
          return;
        }
        ptyIdRef.current = id;
        localPtyId = id;
        // Sync PTY geometry once the container has layout.
        requestAnimationFrame(() => {
          try {
            fit.fit();
          } catch {
            // ignore — window resize handler will retry
          }
          void resizePty({
            session_id: id,
            cols: term.cols,
            rows: term.rows,
          }).catch(() => {});
        });
      })
      .catch((err) => {
        if (!cancelled) setError(String(err));
      });

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

  // Re-fit on window resize and on visibility flips (hidden → visible).
  useEffect(() => {
    function refit() {
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
        void resizePty({
          session_id: id,
          cols: term.cols,
          rows: term.rows,
        }).catch(() => {});
      }
    }
    window.addEventListener("resize", refit);
    if (visible) requestAnimationFrame(refit);
    return () => window.removeEventListener("resize", refit);
  }, [visible]);

  return (
    <div className="manual-terminal">
      {error && <div className="form-error" style={{ margin: 8 }}>{error}</div>}
      <div className="manual-terminal-body" ref={containerRef} />
    </div>
  );
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
