#!/usr/bin/env python3

import json
import pathlib

NATIVE_DIR = pathlib.Path(__file__).resolve().parents[1]
SOURCE = NATIVE_DIR / "Resources" / "IconSources" / "file-icons.json"
OUT = NATIVE_DIR / "TandockApp" / "Sources" / "TandockApp" / "TandockFileIcons.swift"


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

    def table(name: str, mapping: dict[str, str]) -> list[str]:
        lines = [f"    static let {name}: [String: String] = ["]
        for key in sorted(mapping):
            if mapping[key] in svgs:
                lines.append(f'        "{key}": "{mapping[key]}",')
        lines.append("    ]")
        lines.append("")
        return lines

    out = [
        "enum TandockFileIconCatalog {",
        f'    static let defaultFile = "{defaults["file"]}"',
        f'    static let defaultFolder = "{defaults["folder"]}"',
        f'    static let defaultFolderExpanded = "{defaults["folderExpanded"]}"',
        "",
    ]
    out += table("byExtension", extension_map)
    out += table("byFileName", filename_map)
    out += table("byFolder", folder_map)
    out += table("byFolderExpanded", folder_open_map)
    out += ["    static let svg: [String: String] = ["]
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
