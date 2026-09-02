// Toast façade over Base UI's global toast manager.
//
// Call sites only ever needed three severities with a single message string,
// so that's the whole surface. Keeping the `toast.danger(...)` shape means the
// severity stays readable at the call site and the manager stays swappable —
// this file is the only place that knows which toast library is underneath.
import { Toast } from "@base-ui/react/toast";

export const toastManager = Toast.createToastManager();

/// `type` rides through to `data-type` on every toast part, which is what the
/// stylesheet colours against.
function emit(type: "danger" | "success" | "warning", message: string) {
  return toastManager.add({ description: message, type });
}

export const toast = {
  danger: (message: string) => emit("danger", message),
  success: (message: string) => emit("success", message),
  warning: (message: string) => emit("warning", message),
};
