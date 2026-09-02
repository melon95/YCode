import { Toast } from "@base-ui/react/toast";
import { toastManager } from "../../lib/toast";

/// Renders the toast stack for the whole app. Mounted once, next to `<App />`.
///
/// The provider is wired to the global manager from `lib/toast` so that
/// non-React code (IPC error paths, hotkey handlers) can raise a toast without
/// needing a hook — those call sites are the majority here.
export function Toaster() {
  return (
    <Toast.Provider toastManager={toastManager}>
      <Toast.Portal>
        <Toast.Viewport className="toast-viewport">
          <ToastList />
        </Toast.Viewport>
      </Toast.Portal>
    </Toast.Provider>
  );
}

function ToastList() {
  const { toasts } = Toast.useToastManager();
  return toasts.map((toast) => (
    <Toast.Root key={toast.id} toast={toast} className="toast">
      <Toast.Content className="toast-content">
        <Toast.Description className="toast-description" />
        <Toast.Close className="toast-close" aria-label="关闭">
          ✕
        </Toast.Close>
      </Toast.Content>
    </Toast.Root>
  ));
}
