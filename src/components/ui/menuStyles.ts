// 浮层菜单的共享外壳。
//
// OverflowMenu(行尾 ⋮)、ProjectPickerMenu 和 AgentFilterMenu 三处本来就
// 长一样 —— 在 CSS 里它们是共用选择器(`.overflow-menu` 被项目选择器直接
// 复用)。迁到 utility 后如果各写各的,这层"看起来是同一个菜单"的一致性
// 就只剩巧合了,所以把外壳和条目提成常量。

/// 钉在 Positioner(真正 fixed 定位的那层)上,不是 Popup —— Popup 是它的
/// 静态子元素,给子元素设 z-index 不会把整个浮层抬起来。z-index 统一钉在
/// 240:高过画布的一切,低于设置弹窗(300)和命令面板。
export const POPOVER_LAYER = "z-240";

export const MENU_POPUP =
  "p-[5px] bg-panel border border-rule-strong rounded-xl shadow-menu animate-pop-in";

export const MENU_ITEM = `flex items-center w-full py-[7px] px-[9px] border-none rounded-lg
  bg-none text-text-soft text-[12.5px] text-left cursor-pointer outline-none
  data-highlighted:bg-panel-raised data-disabled:opacity-40 data-disabled:cursor-default`
  .replace(/\s+/g, " ");

/// 选中态靠底色 + 字重,不加对勾 —— 菜单里每行左边已经有图标了,再塞一
/// 列勾会把名字挤出去。
export const MENU_ITEM_ON = "bg-st-working-wash text-text font-semibold";
