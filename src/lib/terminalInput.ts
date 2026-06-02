// Bridge xterm.js keyboard input to a PTY in a way that doesn't break
// macOS Chinese IME punctuation auto-replace (e.g. `.` → `。`, `?` → `？`)
// AND doesn't double-write characters on certain key presses (a known
// macOS Chinese IME + WebKit interaction with xterm.js, observed both
// synchronously and across tasks).
//
// Background — xterm.js can emit data through two paths for one IME commit:
//
//   1. `_inputEvent` calls `triggerDataEvent(data)` when
//      `(!ev.composed || !this._keyDownSeen)` is true. The `_keyDownSeen`
//      half is the Sogou-IME fix from xterm.js PR #3680: if no key is
//      currently held (`keyup` already fired) when a composed `insertText`
//      arrives, xterm.js processes it as direct input. On macOS Chinese
//      IME the second press of upper-row symbols defers `input` to AFTER
//      `keyup`, so this path fires.
//   2. `_finalizeComposition`'s `setTimeout(0)` reads
//      `textarea.value.substring(...)` and writes whatever the IME
//      committed. This path always fires on `compositionend`.
//
// When BOTH fire for the same commit, the character is written twice. The
// two fires can also be > 50 ms apart (delayed `input` event after
// `setTimeout(0)` already ran), so a tight onData-only dedup window can
// miss them. References:
//   • xterm.js #3679 / PR #3680    (`_keyDownSeen` condition)
//   • WebKit Bug 164324            (input → compositionend ordering)
//   • xterm.js #5374               (macOS Safari shifted-character quirks)
//
// Strategy:
//
//   • The custom key event handler (in TerminalPane / ManualTerminal) tells
//     xterm.js to skip its keydown/keypress writer for printable
//     single-character keystrokes with no Cmd/Ctrl/Alt. That prevents the
//     raw-char-then-preventDefault path that broke IME replacement
//     originally (the `?` → `？` bug). It also routes printable input
//     entirely through the bubble-phase `input` listener and `term.onData`.
//   • All writes funnel through one `safeWrite(data, source)` with two
//     dedup layers:
//       (a) **Tight unconditional window** (60 ms) for printable single
//           codepoint chars only — collapses adjacent identical writes
//           regardless of source. Control bytes (Enter, Tab, Backspace,
//           CSI escapes from arrow keys) are exempt because they're the
//           keys users legitimately hold for OS-level auto-repeat.
//       (b) **Post-compositionend allowance** (only for `term.onData`):
//           each `compositionend` resets a counter to 1 valid onData
//           write within a 150 ms window. The first onData call for that
//           commit goes through; subsequent ones in the window are
//           dropped. This catches the `_inputEvent` + `setTimeout` pair
//           even when they fire > 60 ms apart. The allowance only gates
//           `term.onData` — `input` events from non-IME keys typed within
//           the window still go through `bridge.onInput`.

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

/** Is this string a single printable Unicode codepoint? Used by the dedup
 *  layer to exempt control bytes (Enter, Tab, Backspace, CSI escapes etc.)
 *  from de-duplication so OS-level key auto-repeat isn't broken. */
function isDedupCandidate(data: string): boolean {
  if (data.length !== 1) return false;
  const code = data.charCodeAt(0);
  // Control range (includes \r, \n, \t, \x1b for escape sequences).
  if (code < 0x20) return false;
  if (code === 0x7f) return false; // DEL
  return true;
}

/** Take ownership of the IME-relevant input paths on `term`:
 *   - composition tracking on `term.textarea`
 *   - a bubble-phase `input` listener for non-composition forwards
 *   - a dedup-wrapped `term.onData` handler for composition forwards
 *
 *  Caller should NOT additionally register their own `term.onData` for
 *  data → PTY: this function does it. Other listeners (e.g. `onBinary`
 *  for mouse tracking) are unaffected.
 *
 *  Returns a disposer that removes every listener registered here. */
export function attachImeInputBridge(
  term: Terminal,
  getSessionId: () => string | null,
): () => void {
  const textarea = term.textarea;

  let composing = false;
  let lastCompositionEndAt = 0;
  // Each compositionend permits exactly one `term.onData` write through the
  // post-composition window. Subsequent onData calls in the window are the
  // IME-double-fire that we're filtering.
  let allowedOnDataAfterComposition = 0;
  const POST_COMPOSITION_WINDOW_MS = 150;

  // Shared dedup state between bridge.onInput and term.onData paths.
  let lastWriteContent = "";
  let lastWriteAt = 0;
  const TIGHT_DEDUP_MS = 60;

  const inPostCompositionWindow = () =>
    Date.now() - lastCompositionEndAt < POST_COMPOSITION_WINDOW_MS;

  function safeWrite(data: string, source: "input" | "ondata"): void {
    if (!data) return;
    const now = Date.now();

    // Layer (a): tight unconditional dedup, single printable codepoint only.
    if (
      isDedupCandidate(data) &&
      data === lastWriteContent &&
      now - lastWriteAt < TIGHT_DEDUP_MS
    ) {
      return;
    }

    // Layer (b): post-compositionend allowance for term.onData only.
    if (source === "ondata" && inPostCompositionWindow()) {
      if (allowedOnDataAfterComposition <= 0) return;
      allowedOnDataAfterComposition--;
    }

    lastWriteContent = data;
    lastWriteAt = now;
    const id = getSessionId();
    if (!id) return;
    void writePty({ session_id: id, data: utf8ToBase64(data) }).catch(() => {
      // PTY is gone (process exited). Drop keystroke silently.
    });
  }

  const onCompositionStart = () => {
    composing = true;
  };
  const onCompositionEnd = () => {
    composing = false;
    lastCompositionEndAt = Date.now();
    allowedOnDataAfterComposition = 1;
  };
  const onInput = (e: Event) => {
    const ie = e as InputEvent;
    if (composing) return;
    if (ie.inputType !== "insertText") return;
    if (!ie.data) return;
    safeWrite(ie.data, "input");
  };

  if (textarea) {
    textarea.addEventListener("compositionstart", onCompositionStart);
    textarea.addEventListener("compositionend", onCompositionEnd);
    textarea.addEventListener("input", onInput);
  }

  const dataDisposable = term.onData((data) => {
    safeWrite(data, "ondata");
  });

  return () => {
    dataDisposable.dispose();
    if (textarea) {
      textarea.removeEventListener("compositionstart", onCompositionStart);
      textarea.removeEventListener("compositionend", onCompositionEnd);
      textarea.removeEventListener("input", onInput);
    }
  };
}
