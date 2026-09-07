// 界面语言。i18next + react-i18next,词条按语言分文件放在 `locales/`。
//
// 语言 id 的取值和主题一模一样,是三选一的字符串:"zh" / "en" /
// "system"。"system" 不是一门语言,是「跟着操作系统走」的意思 —— 存
// 的是这个意图而不是当时解析出的结果,否则用户把系统语言一改,ycode
// 还停在旧语言上。解析发生在每次读取时(`resolveLocale`)。
//
// 为什么不用 i18next 的 LanguageDetector:那个插件会往 localStorage
// 和 cookie 里写自己的一套状态,和 ycode 已有的「配置存 SQLite、UI
// 偏好走 store」两条线都不搭。系统语言从 `navigator.language` 读一次
// 就够,detector 那套额外状态只会多一个真相来源。

import i18next from "i18next";
import { initReactI18next } from "react-i18next";
import en from "../locales/en";
import zh from "../locales/zh";

/// 真正有词条的语言。`system` 不在此列 —— 它要先解析成这两个之一。
export const SUPPORTED_LOCALES = ["zh", "en"] as const;
export type Locale = (typeof SUPPORTED_LOCALES)[number];

/// 用户能选的值,比 `Locale` 多一个「跟随系统」。
export const LOCALE_CHOICES = ["system", ...SUPPORTED_LOCALES] as const;
export type LocaleChoice = (typeof LOCALE_CHOICES)[number];

export const SYSTEM_LOCALE_ID = "system";

/// 没有任何配置时的落点。中文用户装了就是中文,其余一律英文 —— 与
/// `resolveLocale` 对系统语言的判断保持同一条规则。
export const FALLBACK_LOCALE: Locale = "en";

/// 操作系统当前想要的语言。
///
/// 只认前缀:`zh-CN` / `zh-TW` / `zh-Hans-CN` 全部归到 `zh`。ycode 目前
/// 只有一套中文词条(简体),繁体用户看到简体也好过掉回英文;真要分简繁
/// 是另一件事,那需要第三份词条,不是在这里多切一刀。
export function systemLocale(): Locale {
  if (typeof navigator === "undefined") return FALLBACK_LOCALE;
  const tags = navigator.languages?.length
    ? navigator.languages
    : [navigator.language];
  for (const tag of tags) {
    if (!tag) continue;
    const base = tag.toLowerCase().split("-")[0];
    const hit = SUPPORTED_LOCALES.find((l) => l === base);
    if (hit) return hit;
  }
  return FALLBACK_LOCALE;
}

/// 把用户的选择解析成实际要用的语言。
///
/// 认不出的 id 一律当 `system`,而不是硬退回英文:配置文件是可以手改
/// 的,也可能来自装了更多语言的新版 ycode。让未知值落回「跟随系统」,
/// 老版本读到新配置时至少还能给出一个讲得通的语言。
export function resolveLocale(choice: string | undefined): Locale {
  const hit = SUPPORTED_LOCALES.find((l) => l === choice);
  return hit ?? systemLocale();
}

/// 语言选择器上的名字。一律用该语言自己的写法(endonym),且**不随界面
/// 语言变化** —— 在英文界面里把「简体中文」写成 "Chinese Simplified",
/// 恰好挡住了唯一看得懂它的那批人。这也是为什么它是常量而不是词条。
///
/// `system` 不在这里:它不是一门语言而是一句说明,得跟着界面语言翻译,
/// 走 `settings.general.matchSystem`。
export const LOCALE_LABEL: Record<Locale, string> = {
  zh: "简体中文",
  en: "English",
};

export const resources = {
  zh: { translation: zh },
  en: { translation: en },
} as const;

void i18next.use(initReactI18next).init({
  resources,
  lng: FALLBACK_LOCALE,
  fallbackLng: FALLBACK_LOCALE,
  // 词条里出现的 `<b>…</b>` 之类由 `<Trans>` 处理,普通 `t()` 拿到的
  // 都是纯文本,再走一遍 HTML 转义只会把 `&` `<` 变成实体码。React
  // 本身就不会把字符串当 HTML 渲染,这里的转义是多余的一层。
  interpolation: { escapeValue: false },
  // 词条缺失时返回 key 本身而不是空串 —— 空白界面看不出哪里漏了,
  // 露出 key 至少能一眼定位。
  parseMissingKeyHandler: (key) => key,
});

/// 切换当前语言。传入的是用户的选择(可能是 `system`),内部解析。
export function applyLocale(choice: string | undefined): Locale {
  const locale = resolveLocale(choice);
  if (i18next.language !== locale) void i18next.changeLanguage(locale);
  // 让 `<html lang>` 跟上:字体回退、拼写检查、屏幕阅读器的读音都看它。
  if (typeof document !== "undefined") {
    document.documentElement.lang = locale;
  }
  return locale;
}

export { i18next };
