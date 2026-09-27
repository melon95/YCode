#!/usr/bin/env python3
"""从本地 SVG 数据生成 Agent 图标表，无需 Node 或前端依赖。"""

import json
import pathlib

NATIVE_DIR = pathlib.Path(__file__).resolve().parents[1]
SOURCE = NATIVE_DIR / "Resources" / "IconSources" / "agent-icons.json"
OUT = NATIVE_DIR / "YCodeApp" / "Sources" / "YCodeApp" / "YCodeAgentIcons.swift"


def main() -> int:
    data = json.loads(SOURCE.read_text(encoding="utf-8"))
    brand = data["brand"]
    mono = data["mono"]

    lines = [
        "// 由 macos/scripts/generate_agent_icons.py 生成，请勿手改。",
        "// 来源与许可证见 macos/Resources/IconSources/README.md。",
        "// 认识的品牌取彩色裸 glyph，其余取单色 Mono。",
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
        "    /// 单色图标表。**不是字典字面量**：320 条字典字面量会把 Swift 的类型检查",
        "    /// 拖到几分钟，而一条大字符串字面量是常数时间。这里存成",
        "    /// `名字\\u{1}svg\\u{2}名字\\u{1}svg…`，首次访问时解析一次并缓存。",
        "    static let mono: [String: String] = {",
        "        var table: [String: String] = [:]",
        "        table.reserveCapacity(%d)" % len(mono),
        "        for entry in monoPacked.split(separator: \"\\u{2}\", omittingEmptySubsequences: true) {",
        "            guard let sep = entry.firstIndex(of: \"\\u{1}\") else { continue }",
        "            table[String(entry[..<sep])] = String(entry[entry.index(after: sep)...])",
        "        }",
        "        return table",
        "    }()",
        "",
        "    private static let monoPacked = \"\"\"",
    ]
    # 分隔符写成 Swift 转义序列（六个可打印字符），不是裸控制字节 ——
    # 裸的 U+0001/U+0002 会被编译器拒绝：unprintable ASCII character found in source file。
    packed = "\\u{2}".join(f"{k}\\u{{1}}{v}" for k, v in mono.items())
    # 多行字面量的结束分隔符缩进多少，每一行内容就至少要缩进多少。
    lines += ["        " + packed, '        """', "}", ""]

    OUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {OUT}: {len(brand)} brand + {len(mono)} mono")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
