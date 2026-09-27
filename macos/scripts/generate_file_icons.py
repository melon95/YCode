#!/usr/bin/env python3
"""从本地 SVG 与文件映射生成图标表，无需 Node 或前端依赖。"""

import json
import pathlib

NATIVE_DIR = pathlib.Path(__file__).resolve().parents[1]
SOURCE = NATIVE_DIR / "Resources" / "IconSources" / "file-icons.json"
OUT = NATIVE_DIR / "YCodeApp" / "Sources" / "YCodeApp" / "YCodeFileIcons.swift"


def main() -> int:
    data = json.loads(SOURCE.read_text(encoding="utf-8"))
    extension_map = data["byExtension"]
    filename_map = data["byFileName"]
    folder_map = data["byFolder"]
    folder_open_map = data["byFolderExpanded"]
    defaults = {
        "file": data["defaults"]["defaultFile"],
        "folder": data["defaults"]["defaultFolder"],
        "folderExpanded": data["defaults"]["defaultFolderExpanded"],
    }
    svgs = data["svg"]

    def table(name: str, mapping: dict[str, str], comment: str) -> list[str]:
        lines = [f"    /// {comment}", f"    static let {name}: [String: String] = ["]
        for key in sorted(mapping):
            if mapping[key] in svgs:
                lines.append(f'        "{key}": "{mapping[key]}",')
        lines.append("    ]")
        lines.append("")
        return lines

    out = [
        "// 由 macos/scripts/generate_file_icons.py 生成，请勿手改。",
        "// 图标来自 material-icon-theme（MIT），来源与许可证见 Resources/IconSources/README.md。",
        "",
        "enum YCodeFileIconCatalog {",
        f'    static let defaultFile = "{defaults["file"]}"',
        f'    static let defaultFolder = "{defaults["folder"]}"',
        f'    static let defaultFolderExpanded = "{defaults["folderExpanded"]}"',
        "",
    ]
    out += table("byExtension", extension_map, "扩展名 → 图标名")
    out += table("byFileName", filename_map, "整个文件名 → 图标名（package.json 这类）")
    out += table("byFolder", folder_map, "文件夹名 → 图标名")
    out += table("byFolderExpanded", folder_open_map, "展开态的文件夹图标")
    out += ["    /// 图标名 → SVG", "    static let svg: [String: String] = ["]
    for name in sorted(svgs):
        out.append(f'        "{name}": """')
        out.append(f"        {svgs[name]}")
        out.append('        """,')
    out += ["    ]", "}", ""]

    OUT.write_text("\n".join(out), encoding="utf-8")
    size = OUT.stat().st_size // 1024
    print(f"wrote {OUT}: {len(svgs)} icons, {size} KB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
