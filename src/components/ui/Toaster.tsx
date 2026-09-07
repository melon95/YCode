import { Toast } from "@base-ui/react/toast";
import { useTranslation } from "react-i18next";
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
        <Toast.Viewport className="fixed right-4 bottom-4 z-1000 w-[340px] flex flex-col">
          <ToastList />
        </Toast.Viewport>
      </Toast.Portal>
    </Toast.Provider>
  );
}

/// 停靠右下,和 `.update-notice` 共用一套卡片语言(同底、同描边、同投影),
/// 差别只在左侧那道按严重度着色的竖条 —— 一眼分清是报错还是完成,不用读完整句。
///
/// 折叠态下每张都贴合最前一张的高度,堆叠边缘才是齐的;悬停展开后堆叠散成
/// 一列,由 Base UI 量出的偏移驱动。
///
/// 每个改变位置的状态都要显式写回 `scale-100`。迁移前用的是 `transform`
/// 简写,一条声明整个替换掉前一条,缩放顺带就复位了;Tailwind v4 生成的是
/// 独立的 `translate:` 与 `scale:`,互不影响 —— 漏写的话展开后第二张会
/// 一直停在 0.95、第三张 0.90。
const ROOT = `absolute right-0 bottom-0 left-0
  h-[var(--toast-frontmost-height,var(--toast-height))]
  z-[calc(1000-var(--toast-index))]
  transition-[transform,opacity] duration-[280ms] ease-[cubic-bezier(0.22,1,0.36,1)]
  translate-y-[calc(var(--toast-index)*-14%)]
  scale-[calc(max(0,1-(var(--toast-index)*0.05)))]
  data-expanded:h-[var(--toast-height)]
  data-expanded:translate-y-[var(--toast-offset-y)]
  data-expanded:scale-100
  data-swiping:transition-none
  data-swiping:translate-x-[var(--toast-swipe-movement-x)]
  data-swiping:translate-y-[calc(var(--toast-swipe-movement-y)+var(--toast-offset-y,0px))]
  data-swiping:scale-100
  data-starting-style:opacity-0 data-starting-style:translate-y-5 data-starting-style:scale-97
  data-ending-style:opacity-0 data-ending-style:translate-y-5 data-ending-style:scale-97
  data-ending-style:data-[swipe-direction=right]:translate-x-[calc(var(--toast-swipe-movement-x)+130%)]
  data-ending-style:data-[swipe-direction=right]:translate-y-0
  data-ending-style:data-[swipe-direction=right]:scale-100
  data-ending-style:data-[swipe-direction=down]:translate-y-[calc(var(--toast-swipe-movement-y)+130%)]
  data-ending-style:data-[swipe-direction=down]:scale-100
  motion-reduce:transition-[opacity] motion-reduce:duration-200`;

/// `data-type` 落在 Root 上,不在 Content 上 —— Content 只带 data-behind
/// 和 data-expanded,所以严重度必须从 Root 往下选。被压在下面的那几张只留
/// 一个轮廓,文字叠字会糊成一团。
const CONTENT = `flex items-start gap-2.5 pt-[11px] pr-3 pb-[11px] pl-3.5
  bg-panel border border-rule-strong border-l-[3px] border-l-subtle rounded-md
  shadow-[0_12px_32px_rgba(var(--shadow-rgb),0.35)]
  transition-opacity duration-250 ease-[ease]
  data-behind:opacity-0 data-expanded:opacity-100
  in-data-[type=danger]:border-l-st-blocked
  in-data-[type=warning]:border-l-st-working
  in-data-[type=success]:border-l-st-done`;

/// 报错信息常常很长(带路径、带 Rust error chain),给个上限免得一条 toast
/// 铺满半屏;完整内容仍在 title 属性里。
const DESCRIPTION = `flex-1 m-0 text-[12.5px]/[1.45] text-text-soft
  line-clamp-4 [overflow-wrap:anywhere]`;

const CLOSE = `flex-none p-0 size-[18px] grid place-items-center border-none
  rounded-xs bg-transparent text-subtle text-[10px]/none cursor-pointer
  transition-[color,background-color] duration-[120ms] ease-[ease]
  hover:text-text hover:bg-control-hover`;

function ToastList() {
  const { t } = useTranslation();
  const { toasts } = Toast.useToastManager();
  return toasts.map((toast) => (
    <Toast.Root key={toast.id} toast={toast} className={ROOT}>
      <Toast.Content className={CONTENT}>
        <Toast.Description className={DESCRIPTION} />
        <Toast.Close className={CLOSE} aria-label={t("common.close")}>
          ✕
        </Toast.Close>
      </Toast.Content>
    </Toast.Root>
  ));
}
