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
/// `maxDays` 给定时,超过该天数改用绝对日期(「Jun 2」)。待办面板要这个:
/// 一条三个月前完成的任务显示「92 天前」等于没说,日期至少能让人对上
/// 自己那周在干什么。侧栏不传 —— 那里「N 天前」正是想要的粒度。
export function relativeTime(
  ms: number,
  t: TFunction,
  maxDays?: number,
): string {
  // 负数(时钟回拨、未来的时间戳)夹到 0,否则会渲染出「-3 分钟前」。
  const diff = Math.max(0, Date.now() - ms);
  if (diff < MINUTE) return t("time.justNow");
  if (diff < HOUR) return t("time.minutesAgo", { count: Math.floor(diff / MINUTE) });
  if (diff < DAY) return t("time.hoursAgo", { count: Math.floor(diff / HOUR) });
  if (maxDays != null && diff >= maxDays * DAY) {
    // 月/日跟随浏览器 locale,不写死格式:英文出「Jun 2」,中文出「6月2日」。
    return new Intl.DateTimeFormat(undefined, {
      month: "short",
      day: "numeric",
    }).format(new Date(ms));
  }
  return t("time.daysAgo", { count: Math.floor(diff / DAY) });
}
