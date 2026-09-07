// 「3 分钟前」这类相对时间。
//
// 原本这个函数在 AttentionInbox / ProjectsOverview / SidebarProjectGroup
// 里各抄了一份,三份的阈值一样、文案一样。接 i18n 时三份都要改,那正好
// 是它们该合成一份的时候 —— 否则以后英文那边改了措辞,漏掉的两处会
// 安静地留着旧写法。
//
// 不用 `Intl.RelativeTimeFormat`:它给的是「3 minutes ago」这种完整
// 句式,而这里的位置(侧栏副行、卡片角落)只放得下「3m ago」。想要那种
// 紧凑写法就得自己控制,那 Intl 帮不上忙,只剩它的语言判断还有用 ——
// 而语言我们已经知道了。

import type { TFunction } from "i18next";

const MINUTE = 60_000;
const HOUR = 3_600_000;
const DAY = 86_400_000;

/// 把时间戳渲染成相对现在的说法。
///
/// `t` 由调用方传进来而不是在这里 `useTranslation()` —— 这是个纯函数,
/// 不是组件,拿不到 hook;而且传进来之后它在测试里可以被替换掉。
export function relativeTime(ms: number, t: TFunction): string {
  const diff = Date.now() - ms;
  if (diff < MINUTE) return t("time.justNow");
  if (diff < HOUR) return t("time.minutesAgo", { count: Math.floor(diff / MINUTE) });
  if (diff < DAY) return t("time.hoursAgo", { count: Math.floor(diff / HOUR) });
  return t("time.daysAgo", { count: Math.floor(diff / DAY) });
}
