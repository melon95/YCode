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
    // z-index 高于设置(180):确认可能从设置页里弹出。
    <div
      className="fixed inset-0 z-240 flex items-center justify-center bg-black/22 backdrop-blur-[10px] animate-fade-in"
      role="presentation"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) onResult(false);
      }}
    >
      <div
        className="w-[420px] max-w-[90vw] pt-5 px-[22px] pb-4 bg-panel border border-rule-strong rounded-[14px] shadow-menu animate-dialog-in"
        role="alertdialog"
        aria-modal="true"
        aria-label={opts.title}
      >
        <div className="text-sm font-semibold text-text">{opts.title}</div>
        {opts.message && (
          <div className="mt-2 text-[12.5px]/[1.6] text-muted">
            {opts.message}
          </div>
        )}
        <div className="flex justify-end gap-2 mt-[18px]">
          <button
            ref={cancelRef}
            type="button"
            className={CONFIRM_BTN}
            onClick={() => onResult(false)}
          >
            {opts.cancelLabel ?? "取消"}
          </button>
          <button
            type="button"
            className={`${CONFIRM_BTN} ${
              opts.destructive
                ? "border-st-blocked-half text-st-blocked hover:bg-st-blocked-wash hover:border-transparent hover:text-st-blocked"
                : "bg-accent border-transparent text-bg hover:opacity-90 hover:text-bg"
            }`}
            onClick={() => onResult(true)}
          >
            {opts.confirmLabel ?? "确定"}
          </button>
        </div>
      </div>
    </div>
  );
}

const CONFIRM_BTN = `h-control py-0 px-3.5 border border-rule-strong rounded-lg
  bg-transparent text-muted text-[12.5px] cursor-pointer
  transition-[background-color,border-color,color] duration-[var(--t-fast)] ease-smooth
  hover:bg-panel-raised hover:text-text
  focus-visible:outline-2 focus-visible:outline-accent focus-visible:outline-offset-1`
  .replace(/\s+/g, " ");
