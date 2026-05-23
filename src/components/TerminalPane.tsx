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
//
// Output buffering: PtyOutput/PtyExit can arrive between `create_session`
// returning and React mounting the Terminal for the new id. We buffer
// those bytes in `pendingRef` and drain them when the Terminal is created
// — otherwise the agent's startup banner would be lost.

import { useEffect, useRef } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import "@xterm/xterm/css/xterm.css";
import { listenSessionEvents, resizePty, writePty } from "../lib/ipc";
import { useStore } from "../lib/store";
import { NewSessionPicker } from "./NewSessionPicker";

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
    background: "#13120f",
    foreground: "#f0eee6",
    cursor: "#d97757",
    cursorAccent: "#13120f",
    selectionBackground: "rgba(217, 119, 87, 0.28)",
    black: "#13120f",
    red: "#d46a5f",
    green: "#4caf81",
    yellow: "#d6a95c",
    blue: "#8aa4c8",
    magenta: "#c58fbd",
    cyan: "#7bb8a6",
    white: "#f0eee6",
    brightBlack: "#736b5f",
    brightRed: "#f47670",
    brightGreen: "#6ed09f",
    brightYellow: "#efc06f",
    brightBlue: "#a8bddb",
    brightMagenta: "#d8a8cf",
    brightCyan: "#98d0bf",
    brightWhite: "#fff9ef",
  },
} as const;

export function TerminalPane() {
  const sessions = useStore((s) => s.sessions);
  const activeId = useStore((s) => s.activeId);
  const projects = useStore((s) => s.projects);
  const activeProjectId = useStore((s) => s.activeProjectId);
  const activeProject = activeProjectId ? projects[activeProjectId] : null;
  const rootRef = useRef<HTMLDivElement | null>(null);
  const terminalsRef = useRef<Map<string, TermInstance>>(new Map());
  // Per-session byte buffer for output that arrives before its Terminal
  // exists. Drained by `ensureTerminal`.
  const pendingRef = useRef<Map<string, Uint8Array[]>>(new Map());

  // Single global subscriber. Routes per-session PTY events to the matching
  // Terminal, or buffers them if the Terminal hasn't been created yet.
  useEffect(() => {
    let unlisten: (() => void) | undefined;
    let cancelled = false;
    listenSessionEvents((event) => {
      const k = event.kind;
      let bytes: Uint8Array | null = null;
      if (k.type === "PtyOutput") {
        bytes = base64ToBytes(k.data);
      } else if (k.type === "PtyExit") {
        const tag =
          k.code === null
            ? "[process killed]"
            : `[process exited with code ${k.code}]`;
        bytes = new TextEncoder().encode(`\r\n\x1b[33m${tag}\x1b[0m\r\n`);
      }
      if (!bytes) return;

      const inst = terminalsRef.current.get(event.session_id);
      if (inst) {
        inst.term.write(bytes);
      } else {
        const buf = pendingRef.current.get(event.session_id) ?? [];
        buf.push(bytes);
        pendingRef.current.set(event.session_id, buf);
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

  // Mirror the store's sessions map into Terminal instances. Eager creation
  // closes the race window where output arrives before activation.
  useEffect(() => {
    const root = rootRef.current;
    if (!root) return;
    const known = terminalsRef.current;

    for (const id of Object.keys(sessions)) {
      if (!known.has(id)) {
        const inst = createTerminal(id, root);
        known.set(id, inst);
        // Drain any output that arrived before this Terminal existed.
        const buf = pendingRef.current.get(id);
        if (buf) {
          for (const chunk of buf) inst.term.write(chunk);
          pendingRef.current.delete(id);
        }
      }
    }
    for (const id of Array.from(known.keys())) {
      if (!sessions[id]) {
        known.get(id)!.cleanup();
        known.delete(id);
        pendingRef.current.delete(id);
      }
    }
  }, [sessions]);

  // Show only the active Terminal; fit + focus it.
  useEffect(() => {
    const known = terminalsRef.current;
    for (const [id, entry] of known) {
      entry.container.style.display = id === activeId ? "block" : "none";
    }
    if (!activeId) return;
    const inst = known.get(activeId);
    if (!inst) return;
    // Defer fit until the container has layout dimensions. rAF is enough on
    // first activation; later activations of an already-laid-out container
    // are effectively no-ops.
    const raf = requestAnimationFrame(() => {
      try {
        inst.fit.fit();
      } catch {
        // FitAddon throws if the container has zero size. Window resize will
        // retry once the layout settles.
      }
      const { cols, rows } = inst.term;
      void resizePty({ session_id: activeId, cols, rows }).catch(() => {});
      inst.term.focus();
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
    const pending = pendingRef.current;
    return () => {
      for (const inst of terminals.values()) inst.cleanup();
      terminals.clear();
      pending.clear();
    };
  }, []);

  return (
    <div className="terminal-pane">
      {/* Pool: holds all Terminal containers, managed imperatively. React
          must not render children into this div — they'd fight the
          appendChild/removeChild we do in effects. */}
      <div className="terminal-pool" ref={rootRef} />
      {!activeId && (
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
  const term = new Terminal(TERMINAL_OPTIONS);
  const fit = new FitAddon();
  term.loadAddon(fit);

  const container = document.createElement("div");
  container.className = "terminal-container";
  // Hidden by default; the activeId effect flips display on activation.
  container.style.display = "none";
  parent.appendChild(container);
  term.open(container);

  const dataDisposable = term.onData((data) => {
    void writePty({
      session_id: sessionId,
      data: utf8ToBase64(data),
    }).catch(() => {
      // PTY is gone (process exited). Drop keystroke silently.
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
