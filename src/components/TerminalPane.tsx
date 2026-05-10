// xterm.js terminal pane. One persistent Terminal instance per session id,
// kept alive across active-session switches so scrollback survives navigation.
//
// Data flow:
//   • PtyOutput { data: base64 } → decode → terminal.write(bytes)
//   • terminal.onData(string)    → utf-8 encode → base64 → write_pty
//   • container resize           → FitAddon.fit() → resize_pty
//
// Membership-changing UiEventKind variants (SessionAppeared, etc.) are
// handled in App.tsx; here we only listen for the per-session payload.

import { useEffect, useRef } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import "@xterm/xterm/css/xterm.css";
import { listenSessionEvents, resizePty, writePty } from "../lib/ipc";
import { useStore } from "../lib/store";

type TermInstance = {
  term: Terminal;
  fit: FitAddon;
  container: HTMLDivElement;
  cleanup: () => void;
};

const TERMINAL_OPTIONS = {
  fontFamily:
    'ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace',
  fontSize: 13,
  lineHeight: 1.2,
  cursorBlink: true,
  scrollback: 5000,
  theme: {
    background: "#14161c",
    foreground: "#d8dae5",
    cursor: "#6aa9ff",
    cursorAccent: "#14161c",
    selectionBackground: "rgba(106, 169, 255, 0.3)",
    black: "#14161c",
    red: "#d8554b",
    green: "#4caf81",
    yellow: "#d8a14a",
    blue: "#6aa9ff",
    magenta: "#b48be8",
    cyan: "#4ec9b0",
    white: "#d8dae5",
    brightBlack: "#5d6478",
    brightRed: "#f47670",
    brightGreen: "#6ed09f",
    brightYellow: "#f0c067",
    brightBlue: "#92c0ff",
    brightMagenta: "#d0a8ff",
    brightCyan: "#6cd9c4",
    brightWhite: "#ffffff",
  },
} as const;

export function TerminalPane() {
  const activeId = useStore((s) => s.activeId);
  const rootRef = useRef<HTMLDivElement | null>(null);
  const terminalsRef = useRef<Map<string, TermInstance>>(new Map());

  // Single global subscriber; routes per-session PTY events to the matching
  // Terminal instance by id. Mounted once for the pane's lifetime.
  useEffect(() => {
    let unlisten: (() => void) | undefined;
    let cancelled = false;
    listenSessionEvents((event) => {
      const inst = terminalsRef.current.get(event.session_id);
      if (!inst) return;
      const k = event.kind;
      if (k.type === "PtyOutput") {
        inst.term.write(base64ToBytes(k.data));
      } else if (k.type === "PtyExit") {
        const tag =
          k.code === null
            ? "[process killed]"
            : `[process exited with code ${k.code}]`;
        inst.term.write(`\r\n\x1b[33m${tag}\x1b[0m\r\n`);
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

  // Lazy-create the terminal for `activeId`, then show only that container
  // inside the pane root. All others are detached/hidden but kept alive.
  useEffect(() => {
    const root = rootRef.current;
    if (!root || !activeId) return;

    let inst = terminalsRef.current.get(activeId);
    if (!inst) {
      inst = createTerminal(activeId);
      terminalsRef.current.set(activeId, inst);
    }

    for (const [id, entry] of terminalsRef.current) {
      if (id === activeId) {
        if (entry.container.parentElement !== root) {
          root.appendChild(entry.container);
        }
        entry.container.style.display = "block";
      } else {
        entry.container.style.display = "none";
      }
    }

    // Defer fit until the container has dimensions. rAF is enough on first
    // mount; subsequent activations are no-ops if size hasn't changed.
    const raf = requestAnimationFrame(() => {
      try {
        inst!.fit.fit();
      } catch {
        // FitAddon throws if the container is hidden / has zero size.
        // Resize will be retried on the next window/layout change.
      }
      const { cols, rows } = inst!.term;
      void resizePty({ session_id: activeId, cols, rows }).catch(() => {});
      inst!.term.focus();
    });
    return () => cancelAnimationFrame(raf);
  }, [activeId]);

  // Window resize → refit + push new geometry to the PTY of the active session.
  useEffect(() => {
    const onResize = () => {
      if (!activeId) return;
      const inst = terminalsRef.current.get(activeId);
      if (!inst) return;
      try {
        inst.fit.fit();
      } catch {
        return;
      }
      const { cols, rows } = inst.term;
      void resizePty({ session_id: activeId, cols, rows }).catch(() => {});
    };
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, [activeId]);

  // Dispose all terminals on unmount.
  useEffect(() => {
    const terminals = terminalsRef.current;
    return () => {
      for (const inst of terminals.values()) inst.cleanup();
      terminals.clear();
    };
  }, []);

  return (
    <div className="terminal-pane" ref={rootRef}>
      {!activeId && (
        <div className="terminal-empty">
          Select a session from the sidebar, or create a new one.
        </div>
      )}
    </div>
  );
}

function createTerminal(sessionId: string): TermInstance {
  const term = new Terminal(TERMINAL_OPTIONS);
  const fit = new FitAddon();
  term.loadAddon(fit);

  const container = document.createElement("div");
  container.className = "terminal-container";
  term.open(container);

  const dataDisposable = term.onData((data) => {
    void writePty({
      session_id: sessionId,
      data: utf8ToBase64(data),
    }).catch(() => {
      // PTY is gone (process exited). Drop the keystroke silently — the
      // exit marker already tells the user.
    });
  });

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
    cleanup: () => {
      dataDisposable.dispose();
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
