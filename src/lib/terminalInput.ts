// Bridge xterm.js keyboard input to a PTY in a way that doesn't break
// macOS Chinese IME punctuation auto-replace (e.g. `.` → `。`, `?` → `？`).
//
// Why we don't just use xterm.js's built-in path:
//   xterm.js's `_keyDown` synchronously writes the raw keystroke (`?`) and
//   then `preventDefault`s the event, which short-circuits the IME before it
//   can replace the codepoint. The follow-up `input` event (with the
//   replaced `？`) is then dropped by xterm.js's `_inputEvent` guard
//   `(!ev.composed || !this._keyDownSeen)`. End result: `？` never makes it
//   to the PTY in Chinese IME mode.
//
// What we do instead:
//   • For printable single-character keystrokes with no Cmd/Ctrl/Alt, we
//     tell xterm.js to skip its keydown/keypress processing (returning
//     false from the custom key event handler). xterm's listener is registered
//     with capture=true, so this short-circuits the event before
//     preventDefault — the IME's natural input flow can run to completion.
//   • A bubble-phase `input` listener on `term.textarea` forwards the
//     actually-inserted character (raw or IME-replaced) directly to the PTY.
//     Bubble phase means xterm's own capture-phase `_inputEvent` runs first;
//     if it ever does process the event (it calls `cancel()` which stops
//     propagation), we won't double-write.
//   • A `composing` flag (set by compositionstart/end) suppresses our
//     forwarding during multi-key IME composition like pinyin — the final
//     committed text comes through as a post-compositionend `input` event,
//     which is what we forward.

import { writePty } from "./ipc";
import type { Terminal } from "@xterm/xterm";

export function utf8ToBase64(s: string): string {
  const bytes = new TextEncoder().encode(s);
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}

/** True for plain printable character keystrokes that should be left to the
 *  browser/IME instead of xterm.js's keydown writer. Shift is allowed (it's
 *  needed for `?`, `:`, `~`, capital letters, etc.). Cmd/Ctrl/Alt are not —
 *  those are shortcut combos that xterm handles. */
export function isPrintableCharEvent(event: KeyboardEvent): boolean {
  if (event.type !== "keydown" && event.type !== "keypress") return false;
  if (event.metaKey || event.ctrlKey || event.altKey) return false;
  return typeof event.key === "string" && event.key.length === 1;
}

/** Attach a bubble-phase `input` listener that forwards inserted text to
 *  the PTY. Returns a disposer that removes the listener. */
export function attachImeInputBridge(
  term: Terminal,
  getSessionId: () => string | null,
): () => void {
  const textarea = term.textarea;
  if (!textarea) return () => {};

  let composing = false;
  const onCompositionStart = () => {
    composing = true;
  };
  const onCompositionEnd = () => {
    composing = false;
  };
  const onInput = (e: Event) => {
    const ie = e as InputEvent;
    if (composing) return;
    if (ie.inputType !== "insertText") return;
    if (!ie.data) return;
    const id = getSessionId();
    if (!id) return;
    void writePty({ session_id: id, data: utf8ToBase64(ie.data) }).catch(() => {});
    // Clear textarea so subsequent reads (e.g. xterm.js's _finalizeComposition
    // setTimeout, which reads textarea.value.substring(...)) don't double-write
    // the same character.
    textarea.value = "";
  };

  textarea.addEventListener("compositionstart", onCompositionStart);
  textarea.addEventListener("compositionend", onCompositionEnd);
  textarea.addEventListener("input", onInput);

  return () => {
    textarea.removeEventListener("compositionstart", onCompositionStart);
    textarea.removeEventListener("compositionend", onCompositionEnd);
    textarea.removeEventListener("input", onInput);
  };
}
