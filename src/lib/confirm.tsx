// Promise-based confirm dialog. Each call mounts a transient root onto
// document.body, awaits the user's choice, then tears the root down —
// avoids global state / providers.
//
// 自绘而非 HeroUI AlertDialog:后者不消费我们的主题令牌,在浅色主题下
// 仍渲染黑底蓝框,与设置 dialog 的视觉语言脱节。这里复用同一套令牌
// (--panel / --rule-strong / --st-blocked),让确认框和其余浮层是一家人。

import { useEffect, useRef } from "react";
import { useTranslation } from "react-i18next";
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
  const { t } = useTranslation();
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
            className={`${CONFIRM_BTN} ${CONFIRM_BTN_QUIET}`}
            onClick={() => onResult(false)}
          >
            {opts.cancelLabel ?? t("common.cancel")}
          </button>
          <button
            type="button"
            className={`${CONFIRM_BTN} ${
              opts.destructive ? CONFIRM_BTN_DANGER : CONFIRM_BTN_PRIMARY
            }`}
            onClick={() => onResult(true)}
          >
            {opts.confirmLabel ?? t("ui.confirmOk")}
          </button>
        </div>
      </div>
    </div>
  );
}

/// 只放几何与过渡 —— 颜色一律由下面三套完整给出。
///
/// 背景/文字色若在这里写一份、再由三元加一份,两条 utility 特异性相同,
/// 赢的是生成样式表里靠后的那个(跟书写顺序无关),主按钮会被基础串的
/// `bg-transparent` / `text-muted` 压成幽灵按钮。
/// `confirm-btn` 是钩子:焦点用实线 outline 而不是全局那圈光晕(遮罩上
/// 糊成一团),而全局规则 unlayered、utility 压不过,例外写在 styles.css。
const CONFIRM_BTN = `confirm-btn h-control py-0 px-3.5 border rounded-lg text-[12.5px] cursor-pointer
  transition-[background-color,border-color,color] duration-[var(--t-fast)] ease-smooth`
  .replace(/\s+/g, " ");

/// 取消:安静的幽灵按钮。
const CONFIRM_BTN_QUIET =
  "bg-transparent border-rule-strong text-muted hover:bg-panel-raised hover:text-text";

/// 确定:填充强调色。
const CONFIRM_BTN_PRIMARY =
  "bg-accent border-transparent text-bg hover:opacity-90 hover:text-bg";

/// 破坏性确认:红字红边,hover 时补一层淡红底。
const CONFIRM_BTN_DANGER =
  "bg-transparent border-st-blocked-half text-st-blocked hover:bg-st-blocked-wash hover:border-transparent hover:text-st-blocked";
