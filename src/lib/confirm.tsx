// Promise-based confirm dialog backed by HeroUI AlertDialog. Each call mounts
// a transient root onto document.body, awaits the user's choice, then tears
// the root down — avoids global state / providers.

import { createRoot } from "react-dom/client";
import { useEscapeGuard } from "./useEscapeGuard";
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
  // Escape dismisses the dialog without also exiting fullscreen. See the hook.
  useEscapeGuard(() => onResult(false));

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
