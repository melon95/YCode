#!/usr/bin/env python3
"""生成原生版的 agent 图标资源表。

两个来源：
1. `docs/ui-native-redesign.html` 里的 `ic-ycode` —— 应用自身的标志（彩色带渐变）；
2. `@lobehub/icons` —— agent 图标，与非原生版 `src/components/AgentIcon.tsx` 同源。
   认识的品牌取彩色的裸 glyph 变体（Codex 用 `Inner`：`Color` 那版自带渐变底板，
   跟 Claude 的裸 glyph 并排会一个有底色一个没有），其余取 `Mono` 单色兜底。

两类 path 都会先规范化：SVGO 压缩过的 arc 命令（形如 `a6.1 6.1 0 013.0-.4`）
把 large-arc/sweep 两个 flag 和后面的坐标挤在一起，CoreSVG 解析不了，
整条路径会糊成一团，所以这里把它展开成带空格的形式再落盘。

用法：python3 macos/scripts/generate_agent_icons.py
输出：macos/YCodeApp/Sources/YCodeApp/YCodeAgentIcons.swift
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
LOBEHUB = ROOT / "node_modules" / "@lobehub" / "icons" / "es"
DESIGN = ROOT / "docs" / "ui-native-redesign.html"
OUT = ROOT / "macos" / "YCodeApp" / "Sources" / "YCodeApp" / "YCodeAgentIcons.swift"

# 设计稿里的彩色图标 → 只取应用自身的标志。
# agent 图标一律走下面的单色 glyph：设计稿那三个 symbol 形态并不统一
# （claude 是裸 glyph，codex/gemini 带渐变底板），并排摆在一行里会一个有底色一个没有，
# 而且底板在侧栏 13px 的尺寸下会糊成一块色斑。
BRAND = {
    "ic-ycode": "ycode",
}

# 彩色裸 glyph：(模块, 变体)。带底板的变体不要，形态要跟其它图标一致。
COLOR_SOURCES = {
    "ClaudeCode": ("ClaudeCode", "Color"),
    "Claude": ("Claude", "Color"),
    "Anthropic": ("Claude", "Color"),
    "Codex": ("Codex", "Inner"),
    "GeminiCLI": ("Gemini", "Color"),
    "Gemini": ("Gemini", "Color"),
}

# 其余 agent：单色 glyph 兜底，跟随前景色
MONO = [
    "OpenAI", "Google",
    "Cline", "Copilot", "GithubCopilot", "KiloCode", "Trae", "Amp", "Phind", "Ollama",
    "Mistral", "DeepSeek", "Qwen", "Doubao", "Kimi", "Moonshot", "Grok", "XAI", "Meta",
    "MetaAI", "Cohere", "Perplexity", "Replit",
]

ARC_ARGS = {"m": 2, "l": 2, "t": 2, "h": 1, "v": 1, "c": 6, "s": 4, "q": 4, "a": 7, "z": 0}
NUMBER = re.compile(r"[+-]?(?:\d*\.\d+(?:[eE][+-]?\d+)?|\d+\.?(?:[eE][+-]?\d+)?)")
COMMANDS = re.compile(r"([MmLlHhVvCcSsQqTtAaZz])([^MmLlHhVvCcSsQqTtAaZz]*)")


def take(text: str, count: int, is_arc: bool):
    """按顺序取 count 个参数；arc 的第 4、5 个是单字符 flag，不能当普通数字解析。"""
    values, index = [], 0
    while len(values) < count:
        while index < len(text) and text[index] in ", \t\r\n":
            index += 1
        if index >= len(text):
            break
        if is_arc and len(values) in (3, 4):
            values.append(text[index])
            index += 1
            continue
        match = NUMBER.match(text, index)
        if not match:
            break
        values.append(match.group())
        index = match.end()
    return values, text[index:]


def normalize_path(data: str) -> str:
    parts = []
    for command, rest in COMMANDS.findall(data):
        count = ARC_ARGS[command.lower()]
        if count == 0:
            parts.append(command)
            continue
        is_arc = command.lower() == "a"
        first = True
        while True:
            values, rest = take(rest, count, is_arc)
            if len(values) < count:
                break
            # 重复参数组：m/M 的后续组按规范是 l/L
            head = command if first else {"m": "l", "M": "L"}.get(command, command)
            parts.append(head + " " + " ".join(values))
            first = False
            if not rest.strip(" ,\t\r\n"):
                break
    return " ".join(parts)


def normalize_svg(svg: str) -> str:
    return re.sub(r'(\sd=")([^"]+)(")', lambda m: m.group(1) + normalize_path(m.group(2)) + m.group(3), svg)


def brand_icons() -> dict[str, str]:
    html = DESIGN.read_text(encoding="utf-8")
    found = {}
    for symbol, key in BRAND.items():
        match = re.search(r'<symbol id="%s" viewBox="([^"]+)">(.*?)</symbol>' % symbol, html, re.S)
        if not match:
            print(f"skip {symbol}: not in design doc", file=sys.stderr)
            continue
        viewbox, body = match.group(1), re.sub(r"\s+", " ", match.group(2)).strip()
        # 渐变 id 在同一个文档里会串，加前缀隔离
        body = re.sub(r'id="([\w-]+)"', lambda m: 'id="%s-%s"' % (key, m.group(1)), body)
        body = re.sub(r'url\(#([\w-]+)\)', lambda m: "url(#%s-%s)" % (key, m.group(1)), body)
        found[key] = normalize_svg(
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{viewbox}">{body}</svg>'
        )
    return found


PATH_CHUNK = re.compile(r'_jsx\("path",\s*\{(.*?)\}\)', re.S)
GRADIENT_CHUNK = re.compile(r'_jsxs?\("(linear|radial)Gradient",\s*\{(.*?)(?=_jsxs?\("(?:linear|radial)Gradient"|\Z)', re.S)
STOP_CHUNK = re.compile(r'_jsx\("stop",\s*\{(.*?)\}\)', re.S)


def attr(chunk: str, name: str) -> str | None:
    match = re.search(r'\b%s:\s*"([^"]*)"' % name, chunk)
    return match.group(1) if match else None


def fill_reference(chunk: str, prefix: str) -> str | None:
    """`fill: a.fill` / `fill: fill` 指向 defs 里的渐变，换成稳定的 url(#...)。"""
    match = re.search(r'\bfill:\s*([A-Za-z_$][\w$]*)(?:\.fill)?\b', chunk)
    if not match:
        return None
    name = match.group(1)
    return "url(#%s-%s)" % (prefix, "g" if name == "fill" else name)


def gradients(text: str, prefix: str) -> str:
    """把 defs 里的渐变重建出来；id 用模块名做前缀，避免同一文档里串色。"""
    out = []
    for kind, chunk in [(m.group(1), m.group(2)) for m in GRADIENT_CHUNK.finditer(text)]:
        name = re.search(r'\bid:\s*([A-Za-z_$][\w$]*)(?:\.id)?', chunk)
        name = name.group(1) if name else "id"
        ident = "%s-%s" % (prefix, "g" if name == "id" else name)
        attrs = [f'id="{ident}"']
        for key in ("gradientUnits", "gradientTransform", "x1", "x2", "y1", "y2", "cx", "cy", "r", "fx", "fy"):
            value = attr(chunk, key)
            if value is not None:
                svg_key = re.sub(r"(?<!^)(?=[A-Z])", "-", key).lower()
                attrs.append(f'{svg_key}="{value}"')
        stops = []
        for stop in STOP_CHUNK.findall(chunk):
            pieces = []
            for key, svg_key in (("offset", "offset"), ("stopColor", "stop-color"), ("stopOpacity", "stop-opacity")):
                value = attr(stop, key)
                if value is not None:
                    pieces.append(f'{svg_key}="{value}"')
            stops.append("<stop %s/>" % " ".join(pieces))
        out.append("<%sGradient %s>%s</%sGradient>" % (kind, " ".join(attrs), "".join(stops), kind))
    return "<defs>%s</defs>" % "".join(out) if out else ""


def component_svg(module: str, variant: str, prefix: str, force_fill: str | None = None) -> str | None:
    source = LOBEHUB / module / "components" / f"{variant}.js"
    if not source.exists():
        return None
    text = source.read_text(encoding="utf-8")
    viewbox = attr(text, "viewBox") or "0 0 24 24"
    default_rule = attr(text, "fillRule") or "nonzero"
    paths = []
    for chunk in PATH_CHUNK.findall(text):
        d = attr(chunk, "d")
        if not d:
            continue
        fill = force_fill or attr(chunk, "fill") or fill_reference(chunk, prefix) or "black"
        rule = attr(chunk, "fillRule") or default_rule
        opacity = attr(chunk, "opacity")
        extra = f' opacity="{opacity}"' if opacity else ""
        # fill-rule 写在 <svg> 上 CoreSVG 不继承，逐个 path 标注
        paths.append(
            f'<path fill="{fill}" fill-rule="{rule}" clip-rule="{rule}"{extra} d="{d}"/>'
        )
    if not paths:
        return None
    body = gradients(text, prefix) + "".join(paths)
    return normalize_svg(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{viewbox}">{body}</svg>')


def color_icons() -> dict[str, str]:
    found = {}
    for key, (module, variant) in COLOR_SOURCES.items():
        svg = component_svg(module, variant, prefix=key)
        if svg is None:
            print(f"skip {key}: no {module}/{variant}", file=sys.stderr)
            continue
        found[key] = svg
    return found


def mono_icons() -> dict[str, str]:
    found = {}
    for name in MONO:
        svg = component_svg(name, "Mono", prefix=name, force_fill="black")
        if svg is None:
            print(f"skip {name}: no Mono component", file=sys.stderr)
            continue
        found[name] = svg
    return found


def main() -> int:
    if not DESIGN.exists():
        print(f"missing {DESIGN}", file=sys.stderr)
        return 1
    if not LOBEHUB.exists():
        print(f"missing {LOBEHUB}; run bun/npm install first", file=sys.stderr)
        return 1

    brand = brand_icons()
    brand.update(color_icons())
    mono = mono_icons()

    lines = [
        "// 由 macos/scripts/generate_agent_icons.py 生成，请勿手改。",
        "// 应用标志来自 docs/ui-native-redesign.html；agent 图标来自 @lobehub/icons（MIT），",
        "// 与 src/components/AgentIcon.tsx 同源：认识的品牌取彩色裸 glyph，其余取单色 Mono。",
        "",
        "enum YCodeAgentIconCatalog {",
        "    /// 彩色图标（应用标志 + 认识的品牌），按原色渲染，不着色。",
        "    static let brand: [String: String] = [",
    ]
    for key, svg in brand.items():
        lines += [f'        "{key}": """', f"        {svg}", '        """,']
    lines += [
        "    ]",
        "",
        "    /// 其余 agent 的单色兜底，渲染成 template image 后跟随前景色。",
        "    static let mono: [String: String] = [",
    ]
    for key, svg in mono.items():
        lines += [f'        "{key}": """', f"        {svg}", '        """,']
    lines += ["    ]", "}", ""]

    OUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {OUT}: {len(brand)} brand + {len(mono)} mono")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
