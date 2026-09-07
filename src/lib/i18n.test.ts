import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import en from "../locales/en";
import zh from "../locales/zh";
import { FALLBACK_LOCALE, resolveLocale, SUPPORTED_LOCALES } from "./i18n";

/// 把嵌套词条摊平成 `a.b.c` 的路径集合,用来比较两份词条的形状。
function keyPaths(obj: unknown, prefix = ""): string[] {
  if (typeof obj !== "object" || obj === null) return [prefix];
  return Object.entries(obj).flatMap(([k, v]) =>
    keyPaths(v, prefix ? `${prefix}.${k}` : k),
  );
}

describe("词条完整性", () => {
  // 这条是整套 i18n 里最该守住的不变量。少一个 key 不会报错、不会崩,
  // 只会让那一处安静地掉回另一种语言 —— 混着两种语言的界面比全中文
  // 或全英文都糟,而且没人会去逐屏点。
  it("中英两份词条的 key 完全一致", () => {
    // 比较前抹掉复数后缀:中文只有 `_other`,英文有 `_one`/`_other`,
    // 这是语言本身的差异而不是漏翻。抹掉之后两边应当严格相等。
    const base = (k: string) => k.replace(/_(zero|one|two|few|many|other)$/, "");
    const zhKeys = [...new Set(keyPaths(zh).map(base))].sort();
    const enKeys = [...new Set(keyPaths(en).map(base))].sort();
    const onlyZh = zhKeys.filter((k) => !enKeys.includes(k));
    const onlyEn = enKeys.filter((k) => !zhKeys.includes(k));
    expect({ onlyZh, onlyEn }).toEqual({ onlyZh: [], onlyEn: [] });
  });

  // 英文必须给全 `_one` 和 `_other`。只写一个的话,i18next 在另一个
  // 数量下查不到词条 —— 界面上会直接冒出 `inbox.open_one` 这种 key。
  it("英文的复数词条 one/other 都在", () => {
    const plural = keyPaths(en).filter((k) => /_(one|other)$/.test(k));
    const missing: string[] = [];
    for (const k of plural) {
      const other = k.endsWith("_one")
        ? k.replace(/_one$/, "_other")
        : k.replace(/_other$/, "_one");
      if (!plural.includes(other)) missing.push(other);
    }
    expect(missing).toEqual([]);
  });

  // key 只许 ASCII。写词条时很容易手滑打进同形异码的字符 —— 西里尔的
  // `С` 和拉丁的 `C` 在编辑器里长得一模一样,两边同时打错还能通过上面
  // 那条一致性检查,却让调用点怎么写都查不到。
  it("key 全是 ASCII", () => {
    const bad = [...keyPaths(zh), ...keyPaths(en)].filter((k) =>
      // eslint-disable-next-line no-control-regex
      /[^\x00-\x7F]/.test(k),
    );
    expect(bad).toEqual([]);
  });

  it("没有空词条", () => {
    const blanks = [
      ...keyPaths(zh).filter((k) => resolve(zh, k) === ""),
      ...keyPaths(en).filter((k) => resolve(en, k) === ""),
    ];
    expect(blanks).toEqual([]);
  });

  // 插值占位符必须两边一致:中文写 {{count}} 而英文漏了,那句话在英文
  // 下就永远显示不出那个数字,且没有任何报错。
  it("同一条词条的插值占位符两边一致", () => {
    const ph = (s: string) =>
      [...s.matchAll(/\{\{(\w+)\}\}/g)].map((m) => m[1]).sort();
    const mismatched: string[] = [];
    for (const k of keyPaths(zh)) {
      const a = resolve(zh, k);
      if (typeof a !== "string") continue;
      // 复数分支两边名字不一定对得上(中文 `_other` ↔ 英文 `_one`),
      // 取英文侧任意一个存在的分支比即可 —— 同一条词条的不同复数形式
      // 本来就该用同一组占位符。
      const b =
        resolve(en, k) ??
        resolve(en, k.replace(/_other$/, "_one")) ??
        resolve(en, k.replace(/_one$/, "_other"));
      if (typeof b !== "string") continue;
      if (JSON.stringify(ph(a)) !== JSON.stringify(ph(b))) mismatched.push(k);
    }
    expect(mismatched).toEqual([]);
  });
});

/// 递归收集 `src/` 下所有源码(不含词条本身和测试)。
function sourceFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const p = join(dir, e.name);
    if (e.isDirectory()) return e.name === "locales" ? [] : sourceFiles(p);
    if (!/\.tsx?$/.test(e.name) || e.name.includes(".test.")) return [];
    return [p];
  });
}

describe("词条与代码的对应", () => {
  // 死词条会悄悄累积:改版删掉一处界面,它的词条留在文件里没人发现,
  // 下一个人还得跟着翻译一遍。这条把它变成会红的测试。
  //
  // key 的引用形式不止 `t("…")` —— 模块级常量表存 key(labelKey /
  // titleKey…),`<Trans i18nKey>` 走 JSX 属性,选项表是 `[值, key]` 的
  // 元组。少认一种就会误报,所以这里逐一列出。
  it("没有定义了却没人引用的词条", () => {
    const src = sourceFiles(join(import.meta.dirname, ".."))
      .map((f) => readFileSync(f, "utf8"))
      .join("\n");
    const patterns = [
      /\bt\(\s*"([a-zA-Z][\w.]*)"/g,
      /i18nKey="([\w.]+)"/g,
      /(?:labelKey|titleKey|nameKey|descKey|hintKey)\s*:\s*"([\w.]+)"/g,
      /\[\s*"[\w-]+"\s*,\s*"([\w.]+)"\s*\]/g,
      // `single: "toolbar.layoutSingle"` 这种「值就是 key」的映射表。
      // 它们经 `t(TABLE[x])` 动态索引,静态扫描看不见调用点,只能认
      // 定义处。所以这条特意宽松:任何形如 `xxx: "a.b"` 的都算引用。
      /^\s*"?[\w-]+"?:\s*"([a-z]\w*(?:\.\w+)+)",?$/gm,
    ];
    const used = new Set<string>();
    for (const p of patterns) {
      for (const m of src.matchAll(p)) if (m[1].includes(".")) used.add(m[1]);
    }
    const base = (k: string) => k.replace(/_(zero|one|two|few|many|other)$/, "");
    const orphans = [...new Set(keyPaths(zh).map(base))]
      .filter((k) => !used.has(k))
      .sort();
    expect(orphans).toEqual([]);
  });
});

describe("resolveLocale", () => {
  it("认得出受支持的语言", () => {
    for (const l of SUPPORTED_LOCALES) expect(resolveLocale(l)).toBe(l);
  });

  // 未知值(手改过的配置、更新版 ycode 写下的语言)落回跟随系统,而不是
  // 硬退英文 —— 测试环境没有中文 navigator,所以这里等于 FALLBACK。
  it("未知语言与 system 都走系统解析", () => {
    expect(SUPPORTED_LOCALES).toContain(resolveLocale("system"));
    expect(SUPPORTED_LOCALES).toContain(resolveLocale("kl"));
    expect(SUPPORTED_LOCALES).toContain(resolveLocale(undefined));
  });

  it("解析结果永远是一门真有词条的语言", () => {
    expect(SUPPORTED_LOCALES).toContain(FALLBACK_LOCALE);
  });
});

function resolve(obj: unknown, path: string): unknown {
  return path
    .split(".")
    .reduce<unknown>(
      (acc, k) =>
        typeof acc === "object" && acc !== null
          ? (acc as Record<string, unknown>)[k]
          : undefined,
      obj,
    );
}
