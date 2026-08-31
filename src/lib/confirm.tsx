// Promise-based confirm dialog. Each call mounts a transient root onto
// document.body, awaits the user's choice, then tears the root down —
// avoids global state / providers.
//
// 自绘而非 HeroUI AlertDialog:后者不消费我们的主题令牌,在浅色主题下
// 仍渲染黑底蓝框,与设置 dialog 的视觉语言脱节。这里复用同一套令牌
// (--panel / --rule-strong / --st-blocked),让确认框和其余浮层是一家人。

import { useEffect, useRef } from "react";
import { createRoot } from "react-dom/client";
import { useEscapeGuard } from "./useEscapeGuard";

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

  // 焦点落在取消上:确认框多为破坏性操作,回车的默认答案应该是「不做」。
  const cancelRef = useRef<HTMLButtonElement | null>(null);
  useEffect(() => {
    cancelRef.current?.focus();
  }, []);

  return (
    <div
      className="confirm-mask"
      role="presentation"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) onResult(false);
      }}
    >
      <div
        className="confirm-dialog"
        role="alertdialog"
        aria-modal="true"
        aria-label={opts.title}
      >
        <div className="confirm-title">{opts.title}</div>
        {opts.message && <div className="confirm-message">{opts.message}</div>}
        <div className="confirm-actions">
          <button
            ref={cancelRef}
            type="button"
            className="confirm-btn"
            onClick={() => onResult(false)}
          >
            {opts.cancelLabel ?? "取消"}
          </button>
          <button
            type="button"
            className={
              "confirm-btn" +
              (opts.destructive ? " is-danger" : " is-primary")
            }
            onClick={() => onResult(true)}
          >
            {opts.confirmLabel ?? "确定"}
          </button>
        </div>
      </div>
    </div>
  );
}
