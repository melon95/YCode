#!/usr/bin/env python3

import json
import pathlib

NATIVE_DIR = pathlib.Path(__file__).resolve().parents[1]
SOURCE = NATIVE_DIR / "Resources" / "IconSources" / "agent-icons.json"
OUT = NATIVE_DIR / "TandockApp" / "Sources" / "TandockApp" / "TandockAgentIcons.swift"


def main() -> int:
    data = json.loads(SOURCE.read_text(encoding="utf-8"))
    brand = data["brand"]
    mono = data["mono"]

    lines = [
        "enum TandockAgentIconCatalog {",
        "    static let brand: [String: String] = [",
    ]
    for key, svg in brand.items():
        lines += [f'        "{key}": """', f"        {svg}", '        """,']
    lines += [
        "    ]",
        "",
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
    packed = "\\u{2}".join(f"{k}\\u{{1}}{v}" for k, v in mono.items())
    lines += ["        " + packed, '        """', "}", ""]

    OUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {OUT}: {len(brand)} brand + {len(mono)} mono")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
