// Promise-based confirm dialog backed by HeroUI AlertDialog. Each call mounts
// a transient root onto document.body, awaits the user's choice, then tears
// the root down — avoids global state / providers.

import { useEffect } from "react";
import { createRoot } from "react-dom/client";
import {
  AlertDialog,
  AlertDialogBackdrop,
  AlertDialogBody,
  AlertDialogContainer,
  AlertDialogDialog,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogHeading,
  Button,
} from "@heroui/react";

interface ConfirmOptions {
  title: string;
  message?: string;
  confirmLabel?: string;
  cancelLabel?: string;
  destructive?: boolean;
}

export function confirmDialog(opts: ConfirmOptions): Promise<boolean> {
  return new Promise((resolve) => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    const root = createRoot(container);
    let settled = false;
    const finish = (ok: boolean) => {
      if (settled) return;
      settled = true;
      // Defer unmount past React's current commit; calling .unmount() inside
      // a render-triggered handler logs a warning.
      queueMicrotask(() => {
        root.unmount();
        container.remove();
      });
      resolve(ok);
    };
    root.render(<ConfirmInner opts={opts} onResult={finish} />);
  });
}

function ConfirmInner({
  opts,
  onResult,
}: {
  opts: ConfirmOptions;
  onResult: (ok: boolean) => void;
}) {
  // While the dialog is up, Escape must dismiss *it* — not exit fullscreen.
  // The webview's default action for a bare Escape in fullscreen is to leave
  // fullscreen; react-aria closes the overlay on Escape but doesn't call
  // preventDefault, so both happen. Intercept in the capture phase: swallow the
  // default (and further propagation) and cancel the dialog ourselves.
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      e.preventDefault();
      e.stopPropagation();
      onResult(false);
    };
    window.addEventListener("keydown", onKeyDown, true);
    return () => window.removeEventListener("keydown", onKeyDown, true);
  }, [onResult]);

  return (
    <AlertDialog isOpen onOpenChange={(open) => !open && onResult(false)}>
      <AlertDialogBackdrop>
        <AlertDialogContainer placement="center" size="sm">
          <AlertDialogDialog>
            <AlertDialogHeader>
              <AlertDialogHeading>{opts.title}</AlertDialogHeading>
            </AlertDialogHeader>
            {opts.message && <AlertDialogBody>{opts.message}</AlertDialogBody>}
            <AlertDialogFooter className="flex justify-end gap-2">
              <Button variant="ghost" onPress={() => onResult(false)}>
                {opts.cancelLabel ?? "Cancel"}
              </Button>
              <Button
                variant={opts.destructive ? "danger" : "primary"}
                onPress={() => onResult(true)}
              >
                {opts.confirmLabel ?? "Confirm"}
              </Button>
            </AlertDialogFooter>
          </AlertDialogDialog>
        </AlertDialogContainer>
      </AlertDialogBackdrop>
    </AlertDialog>
  );
}
