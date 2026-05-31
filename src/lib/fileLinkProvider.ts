// Custom xterm.js link provider for file-path-shaped substrings in terminal
// output. Pairs with `resolveTerminalPath` on the backend: this side matches
// optimistically per visible line, and the backend filters out anything that
// isn't a real file inside the active project on activation.
//
// Limitations (acceptable for v1):
//   • Wrapped lines aren't joined — a path that wraps mid-string won't match.
//   • Column math assumes 1 string char == 1 cell. CJK / wide glyphs before a
//     path on the same line will shift the underline range. The activation
//     still passes the matched substring, so clicks work; only the hover
//     highlight is off.

import type { ILink, ILinkProvider, Terminal } from "@xterm/xterm";
import { resolveTerminalPath } from "./ipc";
import { useStore } from "./store";

export interface EditorGotoDetail {
  path: string;
  line: number;
  column?: number;
}

/**
 * Resolve a terminal-scraped candidate against the project, then open it in
 * the right-pane editor as a preview tab. No-op when the candidate doesn't
 * resolve to a real project file. Optional `line` / `column` jump the editor
 * via a `ycode:editor-goto` window event the EditorPanel listens for.
 */
export async function activateFilePath(
  projectId: string,
  candidate: string,
  line: number | undefined,
  column: number | undefined,
): Promise<void> {
  let rel: string | null;
  try {
    rel = await resolveTerminalPath(projectId, candidate);
  } catch {
    return;
  }
  if (!rel) return;
  const store = useStore.getState();
  store.openFile(rel, { preview: true });
  store.setRightTab("editor");
  if (line !== undefined) {
    window.dispatchEvent(
      new CustomEvent<EditorGotoDetail>("ycode:editor-goto", {
        detail: { path: rel, line, column },
      }),
    );
  }
}

// Three top-level alternatives so we cover the common shapes terminal output
// throws around without over-matching plain prose:
//
//   (?<![\w/])      — boundary so we don't latch onto the tail of a URL/word
//   prefixed:       `./foo`, `../foo`, `/abs/foo` — has explicit prefix
//   multi-segment:  `src/foo.ts`, `crates/.../lib.rs` — needs ≥1 `/`
//   bare-ext:       `Cargo.lock`, `EditorPanel.tsx` — needs ≥1 `.ext` part
//   trailing :line  optional `:row(:col)?` source-location suffix
//
// Each segment is `[\w@.\-+]+` / `[\w@\-+]+` (≥1 char). Trailing punctuation
// (`,`, `;`, `.`) is left in the match — the backend resolver filters when
// the file doesn't exist, and we'd rather under-trim than chop `.bashrc`.
//
// The bare-ext branch is permissive (e.g. `i.e.foo`, `version.0.1` would
// match too) but the backend's resolver returns `None` for non-files, so
// stray underlines hover-only and do nothing on click.
const PATH_REGEX =
  /(?<![\w/])((?:\.{1,2}\/|\/)[\w@.\-+]+(?:\/[\w@.\-+]+)*|[\w@.\-+]+(?:\/[\w@.\-+]+)+|[\w@\-+]+(?:\.[\w@\-+]+)+)(?::(\d+)(?::(\d+))?)?/g;

export interface FileLinkActivate {
  (
    candidate: string,
    line: number | undefined,
    column: number | undefined,
  ): void;
}

/**
 * Build an `ILinkProvider` that surfaces clickable file-path-like substrings.
 *
 * `onActivate` is invoked only on Cmd-click (no plain click) so the link
 * provider doesn't fight text selection or accidentally launch the editor.
 */
export function createFileLinkProvider(
  term: Terminal,
  onActivate: FileLinkActivate,
): ILinkProvider {
  return {
    provideLinks(bufferLineNumber, callback) {
      // bufferLineNumber is 1-based per the xterm.js link-provider contract;
      // getLine() is 0-based.
      const bufLine = term.buffer.active.getLine(bufferLineNumber - 1);
      if (!bufLine) {
        callback(undefined);
        return;
      }
      const text = bufLine.translateToString(true);
      if (!text) {
        callback(undefined);
        return;
      }

      const links: ILink[] = [];
      for (const m of text.matchAll(PATH_REGEX)) {
        if (m.index === undefined) continue;
        const matched = m[0];
        const candidate = m[1];
        const lineNum = m[2] ? Number(m[2]) : undefined;
        const colNum = m[3] ? Number(m[3]) : undefined;
        const startCol = m.index;
        const endCol = startCol + matched.length;
        links.push({
          // Range uses 1-based columns and 1-based row (same convention as
          // bufferLineNumber). end.x is inclusive in xterm's range API.
          range: {
            start: { x: startCol + 1, y: bufferLineNumber },
            end: { x: endCol, y: bufferLineNumber },
          },
          text: matched,
          activate(event) {
            if (!event.metaKey) return;
            onActivate(candidate, lineNum, colNum);
          },
        });
      }
      callback(links.length > 0 ? links : undefined);
    },
  };
}
