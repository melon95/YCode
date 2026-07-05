// Shared Escape handling for modals/overlays.
//
// Why this exists: in fullscreen, a bare Escape's default webview action is to
// leave fullscreen. Overlay libraries (react-aria/HeroUI) close on Escape but
// don't call preventDefault — so an unguarded modal both closes AND drops out
// of fullscreen. `useEscapeGuard` intercepts Escape in the capture phase and
// swallows the default + propagation, so Escape only dismisses the modal.
//
// Stacking: a single module-level capture listener drives a stack of guards, so
// when modals overlap only the top-most one responds, and each Escape peels off
// exactly one layer. With no guard mounted the listener is inert (it never
// preventDefaults), so Escape keeps its normal behaviour everywhere else.

import { useEffect, useRef } from "react";

const stack: Array<() => void> = [];
let listening = false;

function onKeyDown(e: KeyboardEvent) {
  if (e.key !== "Escape") return;
  const top = stack[stack.length - 1];
  if (!top) return;
  e.preventDefault();
  e.stopPropagation();
  top();
}

/// Intercept Escape to dismiss this modal while it's mounted/open.
/// `onEscape` need not be memoized — the latest value is always used, and the
/// listener is not re-registered on every render. Pass `enabled: false` to
/// opt out (e.g. a modal that's conditionally rendered but momentarily open).
export function useEscapeGuard(onEscape: () => void, enabled = true): void {
  const cb = useRef(onEscape);
  cb.current = onEscape;
  useEffect(() => {
    if (!enabled) return;
    const handler = () => cb.current();
    stack.push(handler);
    if (!listening) {
      window.addEventListener("keydown", onKeyDown, true);
      listening = true;
    }
    return () => {
      const i = stack.indexOf(handler);
      if (i >= 0) stack.splice(i, 1);
    };
  }, [enabled]);
}
