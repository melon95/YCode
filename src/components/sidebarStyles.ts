// 侧栏内共享的几处外观。
//
// Sidebar 和 SidebarProjectGroup 是一棵树的两半:空态提示、分组小标题、
// 会话行都跨着这两个文件出现。在 CSS 里它们本来就是同一批选择器,分开
// 各写各的之后,「侧栏各处长一样」就只剩巧合了。

/// 侧栏头部的全局按钮(打开项目 / 总览)—— 与工具条 30px 网格一致。
export const TOP_BTN = `flex-none inline-flex items-center justify-center size-control
  border-none rounded-lg bg-none text-muted cursor-pointer
  transition-[background-color,color] duration-[var(--t-fast)] ease-smooth
  not-disabled:hover:bg-panel-raised not-disabled:hover:text-text
  disabled:opacity-40 disabled:cursor-default`.replace(/\s+/g, " ");

export const NEW_SESSION_BTN = `w-full flex items-center gap-2 py-[9px] px-3
  border border-rule-strong rounded-[10px] bg-panel-raised text-text text-[12.5px] font-semibold cursor-pointer
  transition-[background-color,border-color,transform] duration-[var(--t-fast)] ease-smooth
  not-disabled:hover:bg-panel-sunken not-disabled:hover:border-muted
  not-disabled:active:scale-98 disabled:opacity-45 disabled:cursor-not-allowed`
  .replace(/\s+/g, " ");

/// 一段会话行。`[&[hidden]]:hidden` 是必需的:`display:flex` 会盖掉浏览器
/// 默认样式表给 `[hidden]` 的 `display:none`,「更早」收起时列表不会消失。
export const SESSION_LIST =
  "flex-none flex flex-col gap-px px-1.5 pb-1.5 [&[hidden]]:hidden";

/// 列表无内容时的两种说明(空 / 扫描失败)。扫描失败额外走琥珀色。
export const LIST_NOTE = "pt-3.5 px-3.5 pb-2.5 text-[11.5px]/[1.6] text-subtle";

/// 分组小标题。去掉计数后改左对齐 —— space-between 会把仅剩的那个词推到
/// 右端,「更早」跑到和项目名对不齐的位置。需要靠右的元素(「等你处理」
/// 的计数)自己用 `ml-auto`。
export const SECTION_HEADING = `min-h-[42px] pt-[18px] px-3.5 pb-[9px] flex items-center justify-start gap-2
  text-[9.5px] font-[680] tracking-[0.07em] uppercase text-subtle`.replace(
  /\s+/g,
  " ",
);

/// 小标题右侧的计数。字重和字距都比标题本身弱一档。
export const SECTION_CONTEXT =
  "overflow-hidden text-[9px] font-[520] tracking-normal normal-case text-ellipsis whitespace-nowrap";
